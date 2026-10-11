import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/playback_session_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SessionAudio extends Fake implements AudioPlayerService {
  @override
  void synchronizeTransitions() {}
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  final volumes = StreamController<double>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
  Duration elapsed = Duration.zero;
  Duration length = const Duration(minutes: 3);
  double level = 0.4;
  String? loaded;
  @override
  Duration get position => elapsed;
  @override
  Duration get duration => length;
  @override
  double get volume => level;
  @override
  String? get currentUrl => loaded;
  @override
  bool get isPlaying => false;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  Future<void> close() async {
    await positions.close();
    await durations.close();
    await volumes.close();
    await states.close();
  }
}

class _SessionPlayer extends Fake implements PlayerStateService {
  final audio = _SessionAudio();
  final listeners = <VoidCallback>[];
  PlaylistTrack? active;
  Completer<void>? playGate;
  bool preparing = false;
  int played = 0;
  @override
  bool get isPreparing => preparing;
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  PlaylistTrack? get currentTrack => active;
  @override
  String? get currentTrackName => active?.title;
  @override
  String? get currentTrackArtist => active?.artist;
  @override
  String? get currentTrackUrl => audio.loaded;
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  @override
  void cancelPendingPlayback() {}
  @override
  Future<void> playTrack(String filename,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    await playGate?.future;
    played++;
    active = PlaylistTrack(
        id: filename,
        title: trackName ?? filename,
        artist: trackArtist,
        filename: filename,
        url: url);
    audio.loaded =
        '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(filename)}';
    audio.elapsed = Duration.zero;
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  @override
  Future<void> preloadTrack(String filename) async {}
}

QueueItem _file(String name) => QueueItem.fromDownloadedFile(
    filename: '$name.mp3', title: name, artist: 'Fixture artist');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'direct playback snapshot preserves actual audio without attaching old queue selection',
      () async {
    final queue = QueueService();
    final player = _SessionPlayer();
    final session =
        PlaybackSessionService(userId: 1, queue: queue, player: player);
    addTearDown(() async {
      session.dispose();
      queue.dispose();
      await player.audio.close();
    });
    queue.addAllToQueue([_file('queued'), _file('upcoming')]);
    await queue.playItem(0, player);
    await player.playTrack('direct.mp3', trackName: 'Direct screen play');
    player.audio.elapsed = const Duration(seconds: 17);
    await session.flush();
    final saved = await session.load();
    expect(saved, isNotNull);
    expect(saved!.activeTrack?.filename, 'direct.mp3');
    expect(saved.position, const Duration(seconds: 17));
    final restored = QueueService();
    addTearDown(restored.dispose);
    expect(restored.restoreSnapshot(saved.queueSnapshot), isTrue);
    expect(restored.currentIndex, -1);
    expect(restored.queue.map((item) => item.filename),
        ['queued.mp3', 'upcoming.mp3']);
    expect(player.played, 2); // Loading storage must not start any new audio.
  });

  test(
      'snapshot during pending queue transition retains successfully playing occurrence and position',
      () async {
    final queue = QueueService();
    final player = _SessionPlayer();
    final session =
        PlaybackSessionService(userId: 1, queue: queue, player: player);
    addTearDown(() async {
      session.dispose();
      queue.dispose();
      await player.audio.close();
    });
    queue.addAllToQueue([_file('first'), _file('second')]);
    await queue.playItem(0, player);
    player.audio.elapsed = const Duration(seconds: 29);
    await session.flush();
    player.playGate = Completer<void>();
    final pending = queue.playItem(1, player);
    expect(queue.isTransitioning, isTrue);
    // Native source loading resets timing before the new metadata commits.
    player.audio.elapsed = Duration.zero;
    player.audio.length = const Duration(seconds: 5);
    await session.flush();
    final saved = await session.load();
    expect(saved!.activeTrack?.filename, 'first.mp3');
    expect(saved.position, const Duration(seconds: 29));
    expect(saved.duration, const Duration(minutes: 3));
    final restored = QueueService();
    addTearDown(restored.dispose);
    expect(restored.restoreSnapshot(saved.queueSnapshot), isTrue);
    expect(restored.currentItem?.filename, 'first.mp3');
    player.playGate!.complete();
    await pending;
  });

  test('account and backend namespaces never load another account playback',
      () async {
    final firstQueue = QueueService();
    final firstPlayer = _SessionPlayer();
    final first = PlaybackSessionService(
        userId: 1,
        queue: firstQueue,
        player: firstPlayer,
        baseUrl: 'http://localhost:8000');
    final secondQueue = QueueService();
    final secondPlayer = _SessionPlayer();
    final second = PlaybackSessionService(
        userId: 2,
        queue: secondQueue,
        player: secondPlayer,
        baseUrl: 'http://localhost:8000');
    final remote = PlaybackSessionService(
        userId: 1,
        queue: secondQueue,
        player: secondPlayer,
        baseUrl: 'http://localhost:9000');
    addTearDown(() async {
      first.dispose();
      second.dispose();
      remote.dispose();
      firstQueue.dispose();
      secondQueue.dispose();
      await firstPlayer.audio.close();
      await secondPlayer.audio.close();
    });
    firstQueue.addToQueue(_file('private-first'));
    await firstQueue.playItem(0, firstPlayer);
    await first.flush();
    expect((await first.load())!.activeTrack?.filename, 'private-first.mp3');
    expect(await second.load(), isNull);
    expect(await remote.load(), isNull);
    expect(secondPlayer.played, 0);
  });

  test(
      'corrupt saved JSON is ignored without replacing a live queue or starting playback',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        PlaybackSessionService.storageKeyFor(userId: 1), '{broken JSON');
    final queue = QueueService()..addToQueue(_file('live'));
    final player = _SessionPlayer();
    final session =
        PlaybackSessionService(userId: 1, queue: queue, player: player);
    addTearDown(() async {
      session.dispose();
      queue.dispose();
      await player.audio.close();
    });
    expect(await session.load(), isNull);
    expect(queue.queue.single.filename, 'live.mp3');
    expect(player.played, 0);
  });

  test('account switch while reading storage cancels the old session restore',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthHttpClient();
    var token = 'first-session';
    auth.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final queue = QueueService()..addToQueue(_file('private-first'));
    final player = _SessionPlayer();
    await queue.playItem(0, player);
    final writer = PlaybackSessionService(
        userId: 1, queue: queue, player: player, authClient: auth);
    await writer.flush();
    writer.dispose();
    final gate = Completer<SharedPreferences>();
    final reader = PlaybackSessionService(
        userId: 1,
        queue: queue,
        player: player,
        authClient: auth,
        preferencesProvider: () => gate.future);
    addTearDown(() async {
      reader.dispose();
      queue.dispose();
      await player.audio.close();
    });
    final restoring = reader.load();
    await Future<void>.delayed(Duration.zero);
    token = 'second-session';
    gate.complete(prefs);
    expect(await restoring, isNull);
    expect(player.played, 1);
  });

  test(
      'account switch before delayed storage write does not persist private playback',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthHttpClient();
    var token = 'first-session';
    auth.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final queue = QueueService()..addToQueue(_file('private-first'));
    final player = _SessionPlayer();
    await queue.playItem(0, player);
    final gate = Completer<SharedPreferences>();
    final session = PlaybackSessionService(
        userId: 1,
        queue: queue,
        player: player,
        authClient: auth,
        preferencesProvider: () => gate.future);
    addTearDown(() async {
      session.dispose();
      queue.dispose();
      await player.audio.close();
    });
    final saving = session.flush();
    await Future<void>.delayed(Duration.zero);
    token = 'second-session';
    gate.complete(prefs);
    await saving;
    expect(prefs.getString(PlaybackSessionService.storageKeyFor(userId: 1)),
        isNull);
    expect(prefs.getString(PlaybackSessionService.storageKeyFor(userId: 2)),
        isNull);
  });
}
