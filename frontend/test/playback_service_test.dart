import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/recently_played_service.dart';
import 'package:music_downloader/services/recommendation_service.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/queue_item.dart';

class _NativePlayer extends Fake implements just_audio.AudioPlayer {
  final states = StreamController<just_audio.PlayerState>.broadcast();
  final playLifetime = Completer<void>();
  just_audio.ProcessingState processing = just_audio.ProcessingState.ready;
  final List<Duration> seeks = [];
  bool failLoad = false;
  Completer<void>? loadGate;
  bool started = false;
  @override
  double get volume => 1;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<just_audio.SequenceState?> get sequenceStateStream =>
      const Stream.empty();
  @override
  just_audio.SequenceState? get sequenceState => null;
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<Duration?> setAudioSource(just_audio.AudioSource source,
          {bool preload = true,
          int? initialIndex,
          Duration? initialPosition}) =>
      setUrl(
          ((source as just_audio.ConcatenatingAudioSource).children.first
                  as just_audio.UriAudioSource)
              .uri
              .toString(),
          initialPosition: initialPosition);
  @override
  just_audio.ProcessingState get processingState => processing;
  @override
  bool get playing => started;
  @override
  Stream<just_audio.PlayerState> get playerStateStream => states.stream;
  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    if (failLoad) throw StateError('load failed');
    await loadGate?.future;
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() {
    started = true;
    return playLifetime.future;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) seeks.add(position);
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<void> dispose() async {
    if (!playLifetime.isCompleted) playLifetime.complete();
    await states.close();
  }
}

class _Audio extends Fake implements AudioPlayerService {
  final states = StreamController<PlayerState>.broadcast();
  final errors = StreamController<String>.broadcast();
  String? loaded;
  bool failLoad = false;
  @override
  bool get isPlaying => loaded != null;
  @override
  bool get isBuffering => false;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completionStream => const Stream.empty();
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  String? get currentUrl => loaded;
  @override
  Future<void> playFromUrl(String url) async {
    if (failLoad) throw StateError('unavailable');
    loaded = url;
  }

  @override
  Future<void> playFromBackend(String filename) => playFromUrl(filename);
  @override
  void dispose() {
    states.close();
    errors.close();
  }
}

class _History extends Fake implements RecentlyPlayedService {
  final List<String> ids = [];
  final List<String?> urls = [];
  final identities = <Map<String, dynamic>>[];
  bool fail = false;
  Completer<void>? persistence;
  @override
  Future<void> addSong(
      {required String id,
      required String title,
      String? artist,
      String? thumbnail,
      String? filename,
      String? url,
      String? album,
      double? duration,
      String? spotifyId}) async {
    if (fail) throw StateError('disk unavailable');
    ids.add(id);
    urls.add(url);
    identities
        .add({'album': album, 'duration': duration, 'spotifyId': spotifyId});
    await persistence?.future;
  }
}

class _Recommendations extends Fake implements RecommendationService {
  final List<String> titles = [];
  final events = <Map<String, dynamic>>[];
  @override
  String get sessionScope => 'test';
  @override
  Future<void> recordListeningEvent(Map<String, dynamic> body) async =>
      events.add(Map.of(body));
  @override
  Future<void> logHistory(
      {required String title,
      required String artist,
      required double durationPlayed,
      String? spotifyId}) async {
    titles.add(title);
  }
}

void main() {
  test('audio startup returns while play future remains pending', () async {
    final native = _NativePlayer();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    addTearDown(audio.dispose);
    await audio.playFromUrl('audio/a').timeout(const Duration(seconds: 1));
    expect(native.started, isTrue);
    expect(native.playLifetime.isCompleted, isFalse);
    expect(audio.currentUrl, 'audio/a');
  });

  test('failed audio loading preserves the last successfully loaded URL',
      () async {
    final native = _NativePlayer();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    addTearDown(audio.dispose);
    await audio.playFromUrl('audio/a');
    native.failLoad = true;
    await expectLater(audio.playFromUrl('audio/b'), throwsException);
    expect(audio.currentUrl, 'audio/a');
  });

  test('cancelled source load cannot start playback later', () async {
    final native = _NativePlayer();
    native.loadGate = Completer<void>();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    addTearDown(audio.dispose);
    final loading = audio.playFromUrl('audio/stale');
    audio.cancelPendingPlayback();
    native.loadGate!.complete();
    await loading;
    expect(native.started, isFalse);
    expect(audio.currentUrl, isNull);
  });

  test(
      'completion is emitted once per completed state even when playing changes',
      () async {
    final native = _NativePlayer();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    var completions = 0;
    final subscription = audio.completionStream.listen((_) => completions++);
    addTearDown(() async {
      await subscription.cancel();
      audio.dispose();
    });
    native.states.add(
        just_audio.PlayerState(true, just_audio.ProcessingState.completed));
    native.states.add(
        just_audio.PlayerState(false, just_audio.ProcessingState.completed));
    native.states
        .add(just_audio.PlayerState(true, just_audio.ProcessingState.ready));
    native.states.add(
        just_audio.PlayerState(true, just_audio.ProcessingState.completed));
    await Future<void>.delayed(Duration.zero);
    expect(completions, 2);
  });

  test('completed audio displays stopped and resume restarts at zero',
      () async {
    final native = _NativePlayer();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    addTearDown(audio.dispose);
    native.processing = just_audio.ProcessingState.completed;
    native.started = true;
    expect(audio.isPlaying, isFalse);
    await audio.resume();
    expect(native.seeks, [Duration.zero]);
  });

  test('async play errors are exposed rather than unhandled', () async {
    final native = _NativePlayer();
    final audio =
        AudioPlayerService(player: native, preloadPlayer: _NativePlayer());
    addTearDown(audio.dispose);
    final error = audio.errorStream.first;
    await audio.playFromUrl('audio/a');
    native.playLifetime.completeError(StateError('device unavailable'));
    expect(await error, contains('device unavailable'));
  });

  group('player metadata and history', () {
    late _Audio audio;
    late _History history;
    late _Recommendations recommendations;
    late PlayerStateService player;
    setUp(() {
      audio = _Audio();
      history = _History();
      recommendations = _Recommendations();
      player = PlayerStateService(
          audioPlayerService: audio,
          recentlyPlayedService: history,
          recommendationService: recommendations);
    });
    tearDown(() => player.dispose());

    test(
        'successful playback and scheduled handoff retain recent recording identity',
        () async {
      const spotifyId = '0123456789abcdefghijkl';
      await player.streamTrack('audio/a',
          trackName: 'Song',
          trackArtist: 'Artist',
          url: 'source/a',
          album: 'Album',
          duration: 181.5,
          spotifyId: spotifyId);
      player.adoptScheduledTrack(QueueItem(
          id: 'track_$spotifyId',
          title: 'Song',
          artist: 'Artist',
          album: 'Album',
          duration: 181.5,
          spotifyId: spotifyId,
          originalUrl: 'source/a'));
      expect(
          history.identities,
          List.filled(2, {
            'album': 'Album',
            'duration': 181.5,
            'spotifyId': spotifyId,
          }));
    });

    test('failed track does not replace metadata or enter history', () async {
      await player.streamTrack('audio/a', trackName: 'A', url: 'source/a');
      audio.failLoad = true;
      await expectLater(
          player.streamTrack('audio/b', trackName: 'B'), throwsStateError);
      expect(player.currentTrackName, 'A');
      expect(history.ids, ['source/a']);
      expect(history.urls, ['source/a']);
      expect(player.playbackError, contains('unavailable'));
    });

    test('slow history storage cannot delay successful startup', () async {
      history.persistence = Completer<void>();
      await player
          .streamTrack('audio/a', trackName: 'A')
          .timeout(const Duration(seconds: 1));
      expect(player.currentTrackName, 'A');
      history.persistence!.complete();
      await Future<void>.delayed(Duration.zero);
    });

    test('queued media keeps its exact source when liked from the player',
        () async {
      const source = 'https://www.youtube.com/watch?v=abcdefghijk';
      final streaming =
          '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(source)}';
      final queued = QueueItem.fromVideoInfo(
          videoId: 'abcdefghijk',
          title: 'Song',
          artist: 'Artist',
          streamingUrl: streaming);
      expect(queued.originalUrl, source);
      await player.streamTrack(streaming,
          trackName: 'Song', trackArtist: 'Artist');
      expect(player.currentTrack?.url, source);
      expect(history.urls, [source]);
    });

    test('local history failure does not fail playback or listening reports',
        () async {
      history.fail = true;
      await player.streamTrack('audio/a', trackName: 'A');
      await Future<void>.delayed(Duration.zero);
      expect(player.currentTrackName, 'A');
      expect(player.playbackError, isNull);
      expect(recommendations.titles, isEmpty);
      await player.flushListeningHistory();
      expect(recommendations.events.single['song_title'], 'A');
    });

    test('playlist tracks still contribute to recommendations', () async {
      await player.streamTrack('audio/a',
          trackName: 'A', skipRecentlyPlayed: true);
      await Future<void>.delayed(Duration.zero);
      expect(history.ids, isEmpty);
      expect(recommendations.titles, isEmpty);
      await player.flushListeningHistory();
      expect(recommendations.events.single['song_title'], 'A');
    });

    test('legacy media capabilities never persist into history IDs or URLs',
        () async {
      const canonical = '${AppConfig.apiBaseUrl}/downloads/song.m4a';
      await player.streamTrack('$canonical?media_token=expired',
          trackName: 'A', url: '$canonical?media_token=expired');
      await Future<void>.delayed(Duration.zero);
      expect(history.ids, [canonical]);
      expect(history.urls, [canonical]);
    });
  });
}
