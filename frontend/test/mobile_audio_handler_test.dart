import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/mobile_audio_handler.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  bool playing = false;
  bool buffering = false;
  bool ducked = false;
  Duration elapsed = Duration.zero;
  Duration length = const Duration(minutes: 3);
  String? source;
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  bool get isPlaying => playing;
  @override
  bool get isBuffering => buffering;
  @override
  Duration get position => elapsed;
  @override
  Duration get duration => length;
  @override
  String? get currentUrl => source;
  @override
  Future<void> seek(Duration value) async {
    elapsed = value;
    positions.add(value);
  }

  @override
  Future<void> setInterruptionDucking(bool value) async => ducked = value;

  Future<void> close() async {
    await positions.close();
    await durations.close();
  }
}

class _Player extends ChangeNotifier implements PlayerStateService {
  final _Audio audio = _Audio();
  PlaylistTrack? track;
  int revision = 0;
  int resumes = 0;
  int pauses = 0;
  int stops = 0;
  bool preparing = false;
  bool failResume = false;
  Completer<void>? stopGate;
  final played = <String>[];
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  PlaylistTrack? get currentTrack => track;
  @override
  String? get currentTrackUrl => audio.source;
  @override
  int get playbackRevision => revision;
  @override
  bool get isPreparing => preparing;
  @override
  String? get playbackError => null;

  void restore(String name, {String? thumbnail}) {
    track = PlaylistTrack(
        id: name,
        title: name,
        artist: 'Artist',
        album: 'Album',
        thumbnail: thumbnail,
        filename: '');
    audio.source = 'https://audio.example/$name';
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    revision++;
    pauses++;
    audio.playing = false;
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    revision++;
    if (failResume) throw StateError('secret-capability-must-not-be-published');
    resumes++;
    audio.playing = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    revision++;
    stops++;
    await stopGate?.future;
    audio.playing = false;
    track = null;
    notifyListeners();
  }

  @override
  void cancelPendingPlayback() => revision++;
  @override
  Future<void> preloadTrackUrl(String url) async {}
  @override
  Future<void> streamTrack(String streamingUrl,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    revision++;
    played.add(streamingUrl);
    restore(trackName!);
    audio.playing = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

QueueItem _item(String name) => QueueItem(
    id: name,
    title: name,
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    thumbnail: 'https://images.example/$name.jpg',
    url: 'https://audio.example/$name');

void main() {
  late _Player player;
  late QueueService queue;
  late MobileAudioHandler handler;
  late StreamController<void> noisy;
  setUp(() {
    player = _Player();
    queue = QueueService();
    noisy = StreamController<void>.broadcast(sync: true);
    handler = MobileAudioHandler(becomingNoisy: noisy.stream);
    handler.attach(player, queue);
  });
  tearDown(() async {
    handler.dispose();
    queue.dispose();
    player.dispose();
    await player.audio.close();
    await noisy.close();
  });

  test('paused restoration publishes metadata and position without playing',
      () async {
    queue.addAllToQueue([_item('One'), _item('Two')]);
    queue.setCurrentIndex(0);
    player.audio.elapsed = const Duration(seconds: 42);
    player.restore('One');
    expect(handler.mediaItem.value!.title, 'One');
    expect(handler.mediaItem.value!.artist, 'Artist');
    expect(handler.mediaItem.value!.artUri.toString(),
        'https://images.example/One.jpg');
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 42));
    expect(handler.playbackState.value.playing, isFalse);
    expect(player.resumes, 0);
    await handler.play();
    expect(player.resumes, 1);
    expect(handler.playbackState.value.playing, isTrue);
    await handler.pause();
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('lock screen queue commands use the existing queue', () async {
    handler.attach(player, queue);
    queue.addAllToQueue([_item('One'), _item('Two'), _item('Three')]);
    await handler.play();
    expect(player.played, ['https://audio.example/One']);
    await handler.skipToNext();
    expect(queue.currentIndex, 1);
    expect(handler.mediaItem.value!.title, 'Two');
    await handler.seek(const Duration(seconds: 15));
    await handler.skipToPrevious();
    expect(queue.currentIndex, 1);
    expect(player.audio.elapsed, Duration.zero);
    await handler.skipToPrevious();
    expect(queue.currentIndex, 0);
    await handler.skipToQueueItem(2);
    expect(queue.currentIndex, 2);
    await handler.skipToQueueItem(999);
    expect(queue.currentIndex, 2);
  });

  test(
      'lock screen playback resolves catalog queue items with the shared loader',
      () async {
    final loads = <String>[];
    handler.attach(player, queue, loadStreamingUrl: (item) async {
      loads.add(item.id);
      return 'https://audio.example/resolved';
    });
    queue.addAllToQueue([
      QueueItem(
          id: 'catalog-track',
          title: 'One',
          originalUrl: 'https://open.spotify.com/track/catalog-track'),
    ]);
    await handler.play();
    expect(loads, ['catalog-track']);
    expect(player.played, ['https://audio.example/resolved']);
  });

  test('repeat and shuffle commands are idempotent and reflected to the OS',
      () async {
    queue.addAllToQueue([_item('One'), _item('Two')]);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    expect(queue.loopMode, LoopMode.single);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.one);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    expect(queue.loopMode, LoopMode.queue);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    expect(queue.isShuffled, isTrue);
    expect(
        handler.playbackState.value.shuffleMode, AudioServiceShuffleMode.all);
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(queue.isShuffled, isFalse);
  });

  test('seek clamps negative and out of range system scrub positions',
      () async {
    player.restore('One');
    await handler.seek(const Duration(seconds: -10));
    expect(player.audio.elapsed, Duration.zero);
    await handler.seek(const Duration(hours: 1));
    expect(player.audio.elapsed, const Duration(minutes: 3));
  });

  test('phone interruption resumes only playback that was running', () async {
    player.restore('One');
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.resumes, 0);
    await handler.play();
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    expect(player.audio.playing, isFalse);
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.audio.playing, isTrue);
    expect(player.resumes, 2);
  });

  test('manual app pause during a call cancels automatic resume', () async {
    player.restore('One');
    await handler.play();
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await player.pause();
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.resumes, 1);
    expect(player.audio.playing, isFalse);
  });

  test('unplugged headphones cancel pending interruption resume', () async {
    player.restore('One');
    await handler.play();
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause));
    noisy.add(null);
    await Future<void>.delayed(Duration.zero);
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause));
    expect(player.audio.playing, isFalse);
    expect(player.resumes, 1);
  });

  test('unknown interruptions never resume and ducking targets logical player',
      () async {
    player.restore('One');
    await handler.play();
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck));
    expect(player.audio.ducked, isTrue);
    expect(player.audio.playing, isTrue);
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck));
    expect(player.audio.ducked, isFalse);
    await handler.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await handler.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown));
    expect(player.audio.playing, isFalse);
    expect(player.resumes, 1);
  });

  test('detach clears private metadata and stops old account commands',
      () async {
    player.restore('One');
    handler.detach(player);
    expect(handler.mediaItem.value, isNull);
    expect(handler.queue.value, isEmpty);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
    await handler.play();
    expect(player.resumes, 0);
    final replacement = _Player()..restore('Replacement');
    handler.attach(replacement, queue);
    handler.detach(player);
    expect(handler.mediaItem.value!.title, 'Replacement');
    await handler.play();
    expect(replacement.resumes, 1);
    handler.detach(replacement);
    replacement.dispose();
    await replacement.audio.close();
  });

  test('OS stop clears media and failed commands report safe errors', () async {
    player.restore('One');
    player.failResume = true;
    await handler.play();
    expect(handler.playbackState.value.errorMessage,
        'This song could not play. Open the app to try again.');
    await handler.stop();
    expect(player.stops, 1);
    expect(handler.mediaItem.value, isNull);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
  });

  test('a delayed old account stop cannot deactivate a newly attached session',
      () async {
    handler.dispose();
    var deactivations = 0;
    handler = MobileAudioHandler(deactivateSession: () async {
      deactivations++;
    });
    handler.attach(player, queue);
    player.restore('One');
    player.stopGate = Completer<void>();
    final stopped = handler.stop();
    final replacement = _Player()..restore('Replacement');
    handler.attach(replacement, queue);
    await handler.play();
    final before = deactivations;
    player.stopGate!.complete();
    await stopped;
    expect(deactivations, before);
    expect(handler.mediaItem.value!.title, 'Replacement');
    expect(replacement.audio.playing, isTrue);
    handler.detach(replacement);
    replacement.dispose();
    await replacement.audio.close();
  });

  test('private artwork uses scoped URLs and sends auth only to our backend',
      () async {
    handler.dispose();
    var token = 'first-account';
    final auth = AuthHttpClient(baseUrl: 'http://catalog.test');
    auth.configure(tokenProvider: () => token, onUnauthorized: () async {});
    handler = MobileAudioHandler(authClient: auth);
    handler.attach(player, queue);
    const artwork =
        'http://catalog.test/downloads/cover/artwork?media_token=expired';
    player.restore('One', thumbnail: artwork);
    final first = handler.mediaItem.value!;
    expect(first.artHeaders, {'Authorization': 'Bearer first-account'});
    expect(first.artUri!.queryParameters, isNot(contains('media_token')));
    expect(first.artUri!.queryParameters['_session'], isNotEmpty);
    token = 'second-account';
    player.restore('One', thumbnail: artwork);
    expect(handler.mediaItem.value!.artUri, isNot(first.artUri));
    expect(handler.mediaItem.value!.artHeaders,
        {'Authorization': 'Bearer second-account'});
    player.restore('One', thumbnail: 'https://images.example/cover.jpg');
    expect(handler.mediaItem.value!.artHeaders, isNull);
  });
}
