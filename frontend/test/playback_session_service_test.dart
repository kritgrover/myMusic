import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/playback_session_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Audio extends Fake implements AudioPlayerService {
  @override
  void synchronizeTransitions() {}
  final volumes = StreamController<double>.broadcast();
  Duration elapsed = const Duration(seconds: 10);
  Duration length = const Duration(minutes: 3);
  double level = 0.4;
  bool playing = false;
  bool disposed = false;
  @override
  Duration get position {
    if (disposed) throw StateError('read after dispose');
    return elapsed;
  }

  @override
  Duration get duration {
    if (disposed) throw StateError('read after dispose');
    return length;
  }

  @override
  double get volume {
    if (disposed) throw StateError('read after dispose');
    return level;
  }

  @override
  bool get isPlaying => playing;
  @override
  Stream<double> get volumeStream => volumes.stream;
}

class _Player extends Fake implements PlayerStateService {
  final audio = _Audio();
  final List<VoidCallback> listeners = [];
  bool preparing = false;
  PlaylistTrack? track = PlaylistTrack(
      id: 'one', title: 'One', artist: 'Artist', filename: 'one.m4a');
  @override
  bool get isPreparing => preparing;
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  PlaylistTrack? get currentTrack => track;
  @override
  String? get currentTrackName => track?.title;
  @override
  String? get currentTrackArtist => track?.artist;
  @override
  String? get currentTrackUrl => track == null
      ? null
      : '${AppConfig.apiBaseUrl}/downloads/${track!.filename}';
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
  void notify() {
    for (final listener in listeners.toList()) {
      listener();
    }
  }
}

class _Preferences extends Fake implements SharedPreferences {
  final values = <String, String>{};
  final writes = <String>[];
  Completer<void>? gate;
  bool reject = false;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes.add(value);
    await gate?.future;
    if (reject) return false;
    values[key] = value;
    return true;
  }
}

void main() {
  late QueueService queue;
  late _Player player;
  late _Preferences preferences;
  late AuthHttpClient auth;
  late String token;
  setUp(() {
    queue = QueueService();
    player = _Player();
    preferences = _Preferences();
    token = 'account-a';
    auth = AuthHttpClient()
      ..configure(tokenProvider: () => token, onUnauthorized: () async {});
  });
  tearDown(() async {
    queue.dispose();
    await player.audio.volumes.close();
  });
  PlaybackSessionService create(
          {Duration interval = const Duration(seconds: 5),
          Future<SharedPreferences> Function()? provider}) =>
      PlaybackSessionService(
          userId: 1,
          queue: queue,
          player: player,
          authClient: auth,
          saveInterval: interval,
          preferencesProvider: provider ?? () async => preferences);
  Map<String, dynamic> stored() => jsonDecode(
          preferences.values[PlaybackSessionService.storageKeyFor(userId: 1)]!)
      as Map<String, dynamic>;

  test(
      'writes are serialized and disposal captures final position before player destruction',
      () async {
    final session = create();
    preferences.gate = Completer<void>();
    final first = session.flush();
    await Future<void>.delayed(Duration.zero);
    player.audio.elapsed = const Duration(seconds: 20);
    final second = session.flush();
    player.audio.elapsed = const Duration(seconds: 30);
    session.dispose();
    player.audio.disposed = true;
    expect(preferences.writes.length, 1);
    preferences.gate!.complete();
    await Future.wait([first, second]);
    await Future<void>.delayed(Duration.zero);
    expect(stored()['positionMs'], 30000);
    expect(preferences.writes.map((raw) => jsonDecode(raw)['positionMs']),
        [10000, 20000, 30000]);
  });

  test(
      'same-owner recorder writes compare against shared stored data instead of local dedup state',
      () async {
    final first = create();
    final second = create();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.flush();
    player.audio.elapsed = const Duration(seconds: 20);
    await second.flush();
    player.audio.elapsed = const Duration(seconds: 10);
    await first.flush();
    expect(stored()['positionMs'], 10000);
    expect(preferences.writes.length, 3);
  });

  test(
      'an old account cannot write after delayed preferences initialization completes',
      () async {
    final gate = Completer<SharedPreferences>();
    final session = create(provider: () => gate.future);
    addTearDown(session.dispose);
    final pending = session.flush();
    await Future<void>.delayed(Duration.zero);
    token = 'account-b';
    gate.complete(preferences);
    await pending;
    expect(preferences.writes, isEmpty);
    expect(await session.load(), isNull);
  });

  test(
      'empty recorder disposed during initial restore cannot overwrite prior playback',
      () async {
    player.track = null;
    final gate = Completer<SharedPreferences>();
    final key = PlaybackSessionService.storageKeyFor(userId: 1);
    preferences.values[key] = 'previous session';
    final session = create(provider: () => gate.future);
    final loading = session.load();
    await session.flush();
    session.dispose();
    gate.complete(preferences);
    expect(await loading, isNull);
    expect(preferences.values[key], 'previous session');
    expect(preferences.writes, isEmpty);
  });

  test(
      'new user playback is captured if closing during a delayed initial restore',
      () async {
    player.track = null;
    final gate = Completer<SharedPreferences>();
    final session = create(provider: () => gate.future);
    final loading = session.load();
    player.track =
        PlaylistTrack(id: 'new', title: 'New choice', filename: 'new.m4a');
    player.audio.elapsed = const Duration(seconds: 9);
    session.dispose();
    gate.complete(preferences);
    await loading;
    await Future<void>.delayed(Duration.zero);
    expect(stored()['activeTrack']['filename'], 'new.m4a');
    expect(stored()['positionMs'], 9000);
  });

  test('time and volume restoration clamp malformed out-of-range values',
      () async {
    final session = create();
    addTearDown(session.dispose);
    await session.flush();
    final raw = stored()
      ..['positionMs'] = 999999
      ..['durationMs'] = 120000
      ..['volume'] = 2;
    preferences.values[PlaybackSessionService.storageKeyFor(userId: 1)] =
        jsonEncode(raw);
    final restored = await session.load();
    expect(restored!.position, const Duration(minutes: 2));
    expect(restored.duration, const Duration(minutes: 2));
    expect(restored.volume, 1);
  });

  test('wrong owner, unsupported version and oversized JSON are ignored',
      () async {
    final session = create();
    addTearDown(session.dispose);
    await session.flush();
    final raw = stored();
    final key = PlaybackSessionService.storageKeyFor(userId: 1);
    preferences.values[key] = jsonEncode({...raw, 'userId': 2});
    expect(await session.load(), isNull);
    preferences.values[key] = jsonEncode({...raw, 'version': 999});
    expect(await session.load(), isNull);
    preferences.values[key] =
        List.filled(PlaybackSessionService.maxStoredCharacters + 1, 'x').join();
    expect(await session.load(), isNull);
  });

  test('storage errors are nonfatal and the next flush can retry', () async {
    final session = create();
    addTearDown(session.dispose);
    preferences.reject = true;
    await session.flush();
    expect(session.lastError, isNotNull);
    preferences.reject = false;
    await session.flush();
    expect(session.lastError, isNull);
    expect(stored()['positionMs'], 10000);
  });

  test('failed preference initialization can recover on a subsequent flush',
      () async {
    var calls = 0;
    final session = create(provider: () async {
      if (++calls == 1) throw StateError('temporary storage failure');
      return preferences;
    });
    addTearDown(session.dispose);
    await session.flush();
    expect(session.lastError, isNotNull);
    await session.flush();
    expect(session.lastError, isNull);
    expect(stored()['positionMs'], 10000);
  });

  testWidgets(
      'periodic recording, pause and volume updates persist without automatic playback',
      (tester) async {
    final session = create(interval: const Duration(seconds: 5));
    player.audio.playing = true;
    session.start();
    player.audio.elapsed = const Duration(seconds: 16);
    await tester.pump(const Duration(seconds: 5));
    expect(stored()['positionMs'], 16000);
    player.audio.elapsed = const Duration(seconds: 18);
    player.audio.playing = false;
    player.notify();
    await tester.pump();
    expect(stored()['positionMs'], 18000);
    player.audio.level = 0.8;
    player.audio.volumes.add(0.8);
    await tester.pump();
    expect(stored()['volume'], 0.8);
    session.dispose();
    await tester.pump();
  });

  test('a preparing native source cannot overwrite the last committed position',
      () async {
    final session = create();
    addTearDown(session.dispose);
    await session.flush();
    player.preparing = true;
    player.audio.elapsed = Duration.zero;
    player.audio.length = Duration.zero;
    await session.flush();
    expect(stored()['positionMs'], 10000);
    expect(stored()['durationMs'], 180000);
  });
}
