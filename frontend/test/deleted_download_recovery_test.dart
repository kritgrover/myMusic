import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/listening_session_service.dart';
import 'package:music_downloader/services/media_exceptions.dart';
import 'package:music_downloader/services/playback_session_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/recently_played_service.dart';
import 'package:music_downloader/services/recommendation_service.dart';
import 'package:music_downloader/services/scheduled_audio_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Deck extends Fake implements native.AudioPlayer {
  @override
  double get volume => 1;
  @override
  bool get playing => false;
  @override
  native.ProcessingState get processingState => native.ProcessingState.idle;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => Duration.zero;
  @override
  Stream<native.PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<native.SequenceState?> get sequenceStateStream => const Stream.empty();
  @override
  native.SequenceState? get sequenceState => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> dispose() async {}
}

class _Engine extends Fake implements ScheduledAudioEngine {
  final states = StreamController<EngineState>.broadcast(sync: true);
  final handoffs = StreamController<Object>.broadcast(sync: true);
  final loaded = <String>[];
  final staged = <String>[];
  bool playing = false;
  Duration elapsed = Duration.zero;
  Object? next;
  void Function()? onSynchronize;
  @override
  Duration get position => elapsed;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  double get volume => 1;
  @override
  bool get isPlaying => playing;
  @override
  bool get isBuffering => false;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<double> get volumeStream => const Stream.empty();
  @override
  Stream<EngineState> get stateStream => states.stream;
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<void> get completionStream => const Stream.empty();
  @override
  Stream<Object> get handoffStream => handoffs.stream;
  @override
  void synchronize() {
    final callback = onSynchronize;
    onSynchronize = null;
    callback?.call();
  }

  @override
  Future<void> load(String url, {Duration position = Duration.zero}) async {
    loaded.add(url);
    elapsed = position;
    playing = false;
  }

  @override
  Future<void> play() async {
    playing = true;
    states.add(EngineState.playing);
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(EngineState.paused);
  }

  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> seek(Duration position) async => elapsed = position;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stageNext(String url,
      {required Object token, Duration crossfade = Duration.zero}) async {
    staged.add(url);
    next = token;
  }

  @override
  Future<void> clearNext() async => next = null;
  void handoff() {
    final token = next;
    next = null;
    elapsed = Duration.zero;
    if (token != null) handoffs.add(token);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await handoffs.close();
  }
}

class _Recommendations extends Fake implements RecommendationService {
  @override
  String get sessionScope => 'test';
}

class _Recent extends Fake implements RecentlyPlayedService {
  final filenames = <String?>[];
  @override
  Future<void> addSong({
    required String id,
    required String title,
    String? artist,
    String? thumbnail,
    String? filename,
    String? url,
  }) async {
    filenames.add(filename);
  }
}

Future<void> _settle() async => await Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const original = 'https://youtu.be/abcdefghijk?si=tracking';
  const canonicalSource = 'https://www.youtube.com/watch?v=abcdefghijk';
  final stream =
      '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(canonicalSource)}';
  const download = '${AppConfig.apiBaseUrl}/downloads/gone.mp3';
  late _Engine engine;
  late AudioPlayerService audio;
  late PlayerStateService player;
  late ListeningSessionService listening;
  late QueueService queue;
  late _Recent recent;
  late Set<String> missing;
  late List<String> authorized;
  Object? downloadError;
  Object? streamError;
  Completer<void>? missingGate;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    missing = {download};
    authorized = [];
    downloadError = null;
    streamError = null;
    missingGate = null;
    engine = _Engine();
    audio = AudioPlayerService(
        player: _Deck(),
        preloadPlayer: _Deck(),
        scheduledEngine: engine,
        mediaUrlResolver: (url) async {
          authorized.add(url);
          if (missing.contains(url)) {
            await missingGate?.future;
            throw downloadError ?? const DownloadUnavailableException();
          }
          if (url == stream && streamError != null) throw streamError!;
          return '$url?media_token=temporary';
        });
    listening = ListeningSessionService(audio: audio, sendEvent: (_) async {});
    recent = _Recent();
    player = PlayerStateService(
        audioPlayerService: audio,
        recommendationService: _Recommendations(),
        recentlyPlayedService: recent,
        listeningSessionService: listening);
    queue = QueueService()..connectPlayback(player);
  });
  tearDown(() async {
    queue.dispose();
    player.dispose();
    await listening.dispose();
  });
  QueueItem deleted({bool asUrl = false}) => QueueItem(
      id: 'gone',
      title: 'Gone',
      artist: 'Artist',
      filename: asUrl ? null : 'gone.mp3',
      url: asUrl ? download : null,
      originalUrl: original);

  test(
      'saved queue filename recovers exact original source and removes stale file reference',
      () async {
    queue.addToQueue(deleted());
    await queue.playItem(0, player);
    expect(audio.currentUrl, stream);
    expect(player.currentTrack!.filename, '');
    expect(queue.currentItem!.filename, isNull);
    expect(queue.currentItem!.url, stream);
    expect(player.playbackError, isNull);
    expect(authorized, [download, stream]);
  });

  test('old saved canonical download URL also recovers', () async {
    queue.addToQueue(deleted(asUrl: true));
    await queue.playItem(0, player);
    expect(audio.currentUrl, stream);
    expect(queue.currentItem!.url, stream);
    expect(queue.exportSnapshot().toString(), isNot(contains('media_token')));
  });

  test('relative saved download URL recovers and clears the stale queue URL',
      () async {
    queue.addToQueue(QueueItem(
        id: 'gone',
        title: 'Gone',
        url: '/downloads/gone.mp3',
        originalUrl: original));
    await queue.playItem(0, player);
    expect(audio.currentUrl, stream);
    expect(queue.currentItem!.url, stream);
  });

  test(
      'restored missing download stays paused until resume and preserves position on recovery',
      () async {
    queue.addToQueue(deleted());
    queue.setCurrentIndex(0);
    await player.preparePaused(deleted(),
        position: const Duration(seconds: 17),
        duration: const Duration(seconds: 60));
    expect(authorized, isEmpty);
    expect(audio.isPlaying, false);
    await player.resume();
    expect(audio.currentUrl, stream);
    expect(audio.position, const Duration(seconds: 17));
    expect(player.currentTrack!.filename, '');
    expect(queue.currentItem!.filename, isNull);
  });

  test(
      'current download deleted while paused recovers without restarting position',
      () async {
    missing.clear();
    await player.playTrack('gone.mp3', trackName: 'Gone', url: original);
    engine.elapsed = const Duration(seconds: 23);
    await player.pause();
    missing.add(download);
    await player.resume();
    expect(audio.currentUrl, stream);
    expect(audio.position, const Duration(seconds: 23));
    expect(player.currentTrack!.filename, '');
  });

  test('failed restored stream retry keeps corrected source and saved position',
      () async {
    await player.preparePaused(deleted(),
        position: const Duration(seconds: 17),
        duration: const Duration(seconds: 60));
    streamError = StateError('Temporary connection failure');
    await expectLater(player.resume(), throwsException);
    expect(audio.currentUrl, stream);
    expect(audio.position, const Duration(seconds: 17));
    expect(player.currentTrack!.filename, '');
    expect(recent.filenames, isEmpty);
    streamError = null;
    await player.resume();
    expect(audio.isPlaying, isTrue);
    expect(audio.position, const Duration(seconds: 17));
    expect(player.currentTrack!.filename, '');
    expect(recent.filenames, [null]);
    expect(authorized, [download, stream, stream]);
  });

  test('scheduled successor recovers missing download before handoff',
      () async {
    queue.addAllToQueue([
      QueueItem(id: 'first', title: 'First', filename: 'first.mp3'),
      deleted()
    ]);
    await queue.playItem(0, player);
    await _settle();
    expect(engine.staged.single, startsWith(stream));
    engine.handoff();
    expect(queue.currentIndex, 1);
    expect(player.currentTrackName, 'Gone');
    expect(player.currentTrack!.filename, '');
    expect(queue.currentItem!.filename, isNull);
    expect(audio.currentUrl, stream);
  });

  test(
      'permission and generic authorization failures never use recovery source',
      () async {
    downloadError = StateError('Forbidden 403');
    await expectLater(
        player.playTrack('gone.mp3', url: original), throwsException);
    expect(authorized, [download]);
    expect(engine.loaded, isEmpty);
  });

  test(
      'a missing download without an original source remains a recoverable error',
      () async {
    await expectLater(player.playTrack('gone.mp3'),
        throwsA(isA<DownloadUnavailableException>()));
    expect(authorized, [download]);
    expect(player.currentTrack, isNull);
  });

  test(
      'superseded missing-file response cannot start fallback over a newer selection',
      () async {
    missingGate = Completer();
    final old = player.playTrack('gone.mp3', url: original);
    await _settle();
    await player.playTrack('new.mp3', trackName: 'New');
    missingGate!.complete();
    await old;
    expect(player.currentTrackName, 'New');
    expect(authorized, isNot(contains(stream)));
  });

  test(
      'session flush synchronizes scheduled boundary before saving metadata and position',
      () async {
    missing.clear();
    queue.addAllToQueue([
      QueueItem(id: 'first', title: 'First', filename: 'first.mp3'),
      deleted()
    ]);
    await queue.playItem(0, player);
    await _settle();
    engine.elapsed = const Duration(seconds: 60);
    engine.onSynchronize = engine.handoff;
    final session =
        PlaybackSessionService(userId: 1, queue: queue, player: player);
    await session.flush();
    final snapshot = await session.load();
    expect(snapshot!.activeTrack!.title, 'Gone');
    expect(snapshot.queueSnapshot['currentIndex'], 1);
    expect(snapshot.position, Duration.zero);
    session.dispose();
  });
}
