import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/playback_session_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Prepared {
  final String url;
  final Object token;
  final Duration crossfade;
  _Prepared(this.url, this.token, this.crossfade);
}

class _HandoffAudio extends Fake implements AudioPlayerService {
  final handoffs = StreamController<Object>.broadcast(sync: true);
  final volumes = StreamController<double>.broadcast();
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final List<_Prepared> prepared = [];
  bool playing = false;
  String? loaded;
  int clears = 0;
  Object? committedHandoff;
  @override
  void synchronizeTransitions() {
    final token = committedHandoff;
    committedHandoff = null;
    if (token != null) handoffs.add(token);
  }

  @override
  Stream<Object> get handoffStream => handoffs.stream;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => const Duration(seconds: 10);
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  double get volume => 0.4;
  @override
  String? get currentUrl => loaded;
  @override
  Future<void> prepareNext(String url,
      {required Object token, Duration crossfade = Duration.zero}) async {
    prepared.add(_Prepared(url, token, crossfade));
  }

  @override
  Future<void> clearPreload() async => clears++;
  @override
  Future<void> seek(Duration position) async {}

  Future<void> close() async {
    await handoffs.close();
    await volumes.close();
    await states.close();
  }
}

class _HandoffPlayer extends Fake implements PlayerStateService {
  final audio = _HandoffAudio();
  final listeners = <VoidCallback>[];
  final List<QueueItem> adopted = [];
  PlaylistTrack? active;
  int manualPlays = 0;
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  bool get isPreparing => false;
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
  void notify() {
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  void select(QueueItem item, {required bool playing}) {
    active = PlaylistTrack(
        id: item.id,
        title: item.displayTitle,
        artist: item.artist,
        filename: item.filename ?? '',
        url: item.originalUrl);
    audio.loaded = item.filename != null
        ? '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(item.filename!)}'
        : item.url;
    audio.playing = playing;
    notify();
  }

  @override
  Future<void> playTrack(String filename,
      {String? trackName,
      String? trackArtist,
      String? url,
      bool skipRecentlyPlayed = false}) async {
    manualPlays++;
    select(
        QueueItem(
            id: filename,
            title: trackName,
            artist: trackArtist,
            filename: filename,
            originalUrl: url),
        playing: true);
  }

  @override
  Future<void> streamTrack(String streamingUrl,
      {String? trackName,
      String? trackArtist,
      String? url,
      bool skipRecentlyPlayed = false}) async {
    manualPlays++;
    select(
        QueueItem(
            id: url ?? streamingUrl,
            title: trackName,
            artist: trackArtist,
            url: streamingUrl,
            originalUrl: url),
        playing: true);
  }

  @override
  void adoptScheduledTrack(QueueItem item, {bool skipRecentlyPlayed = false}) {
    adopted.add(item);
    select(item, playing: true);
  }

  @override
  void cancelPendingPlayback() {}
  @override
  Future<void> preloadTrack(String filename) async {}
  @override
  Future<void> preloadTrackUrl(String url) async {}
}

QueueItem _file(String name) => QueueItem.fromDownloadedFile(
    filename: '$name.mp3', title: name, artist: 'Fixture artist');

Future<void> _settle() async {
  for (var index = 0; index < 4; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QueueService queue;
  late _HandoffPlayer player;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    queue = QueueService();
    player = _HandoffPlayer();
  });
  tearDown(() async {
    queue.dispose();
    await player.audio.close();
  });

  test(
      'duplicate files advance by opaque occurrence without replay or double adoption',
      () async {
    queue
        .addAllToQueue([_file('duplicate'), _file('duplicate'), _file('last')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final firstToken = player.audio.prepared.last.token;
    player.audio.handoffs.add(firstToken);
    await _settle();
    expect(queue.currentIndex, 1);
    expect(player.adopted.map((item) => item.filename), ['duplicate.mp3']);
    expect(player.manualPlays, 1);
    expect(player.audio.prepared.last.token, isNot(same(firstToken)));
    player.audio.handoffs.add(firstToken);
    await _settle();
    expect(queue.currentIndex, 1);
    expect(player.adopted.length, 1);
  });

  test('repeat single stages the same occurrence with a fresh token each cycle',
      () async {
    queue.addAllToQueue([_file('first'), _file('second')]);
    queue.toggleLoopMode();
    queue.toggleLoopMode();
    expect(queue.loopMode, LoopMode.single);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final first = player.audio.prepared.last;
    expect(Uri.parse(first.url).pathSegments.last, 'first.mp3');
    player.audio.handoffs.add(first.token);
    await _settle();
    expect(queue.currentIndex, 0);
    expect(player.adopted.length, 1);
    final second = player.audio.prepared.last;
    expect(second.token, isNot(same(first.token)));
    player.audio.handoffs.add(first.token);
    player.audio.handoffs.add(second.token);
    await _settle();
    expect(queue.currentIndex, 0);
    expect(player.adopted.length, 2);
    expect(player.manualPlays, 1);
  });

  test('repeat queue hands the last occurrence back to the first', () async {
    queue.addAllToQueue([_file('first'), _file('last')]);
    queue.toggleLoopMode();
    queue.connectPlayback(player);
    await queue.playItem(1, player);
    await _settle();
    player.audio.handoffs.add(player.audio.prepared.last.token);
    await _settle();
    expect(queue.currentIndex, 0);
    expect(player.adopted.single.filename, 'first.mp3');
  });

  test('removing the staged next song rejects its later handoff', () async {
    queue.addAllToQueue([_file('first'), _file('removed'), _file('remaining')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final stale = player.audio.prepared.last.token;
    queue.removeFromQueue(1);
    await _settle();
    player.audio.handoffs.add(stale);
    await _settle();
    expect(queue.currentIndex, 0);
    expect(player.adopted, isEmpty);
    player.audio.handoffs.add(player.audio.prepared.last.token);
    await _settle();
    expect(queue.currentItem?.filename, 'remaining.mp3');
  });

  test(
      'queue edit first commits a handoff that already started on the audio clock',
      () async {
    queue.addAllToQueue(
        [_file('first'), _file('already-started'), _file('upcoming')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    // The audio clock has crossed the scheduled boundary while the UI tick is
    // pending. Removing upcoming audio must first observe the new now-playing.
    player.audio.committedHandoff = player.audio.prepared.last.token;
    queue.removeFromQueue(1);
    await _settle();
    expect(queue.currentItem?.filename, 'already-started.mp3');
    expect(player.adopted.single.filename, 'already-started.mp3');
    expect(queue.queue.map((item) => item.filename),
        ['first.mp3', 'already-started.mp3', 'upcoming.mp3']);
  });

  test('reordering upcoming tracks invalidates the prior staged occurrence',
      () async {
    queue.addAllToQueue([_file('first'), _file('second'), _file('third')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final stale = player.audio.prepared.last.token;
    queue.reorderQueue(2, 1);
    await _settle();
    player.audio.handoffs.add(stale);
    await _settle();
    expect(queue.currentItem?.filename, 'first.mp3');
    expect(player.adopted, isEmpty);
    player.audio.handoffs.add(player.audio.prepared.last.token);
    await _settle();
    expect(queue.currentItem?.filename, 'third.mp3');
  });

  test(
      'replacing media within the staged occurrence rejects the old audio token',
      () async {
    queue.addAllToQueue([_file('first'), _file('old-audio')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final stale = player.audio.prepared.last.token;
    queue.updateItemAt(1, _file('replacement-audio'));
    await _settle();
    player.audio.handoffs.add(stale);
    await _settle();
    expect(queue.currentIndex, 0);
    expect(player.adopted, isEmpty);
    expect(Uri.parse(player.audio.prepared.last.url).pathSegments.last,
        'replacement-audio.mp3');
    player.audio.handoffs.add(player.audio.prepared.last.token);
    await _settle();
    expect(player.adopted.single.filename, 'replacement-audio.mp3');
  });

  test('a stale asynchronous source resolver cannot stage a removed song',
      () async {
    final pending = Completer<String?>();
    final delayed = QueueItem(id: 'delayed', title: 'Delayed', originalUrl: '');
    queue.addAllToQueue([_file('first'), delayed, _file('remaining')]);
    queue.connectPlayback(player, loadStreamingUrl: (item) => pending.future);
    await queue.playItem(0, player);
    await _settle();
    queue.removeFromQueue(1);
    await _settle();
    pending.complete('${AppConfig.apiBaseUrl}/stream/stale');
    await _settle();
    expect(player.audio.prepared.every((item) => !item.url.contains('stale')),
        isTrue);
    expect(Uri.parse(player.audio.prepared.last.url).pathSegments.last,
        'remaining.mp3');
  });

  test(
      'direct playback cancels the old queue handoff without adopting its metadata',
      () async {
    queue.addAllToQueue([_file('first'), _file('next')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final stale = player.audio.prepared.last.token;
    await player.playTrack('standalone.mp3', trackName: 'Standalone');
    await _settle();
    player.audio.handoffs.add(stale);
    await _settle();
    expect(player.currentTrack?.filename, 'standalone.mp3');
    expect(player.adopted, isEmpty);
    expect(player.audio.clears, greaterThan(0));
  });

  test('standalone completion cannot advance an unrelated old queue', () async {
    queue.addAllToQueue([_file('first'), _file('next')]);
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    await player.playTrack('standalone.mp3', trackName: 'Standalone');
    player.audio.playing = false;
    await queue.playNext(player, isAutomatic: true);
    expect(player.currentTrack?.filename, 'standalone.mp3');
    expect(queue.currentIndex, 0);
    expect(player.manualPlays, 2);
    // A deliberate queue Next action is still allowed.
    await queue.playNext(player);
    expect(player.currentTrack?.filename, 'next.mp3');
  });

  test(
      'completion fallback retries a failed preparatory source lookup with the connected loader',
      () async {
    var lookups = 0;
    final metadata =
        QueueItem(id: 'metadata', title: 'Metadata', originalUrl: '');
    queue.addAllToQueue([_file('first'), metadata]);
    queue.connectPlayback(player, loadStreamingUrl: (item) async {
      lookups++;
      if (lookups == 1) throw StateError('Transient search failure');
      return '${AppConfig.apiBaseUrl}/stream/retry-source';
    });
    await queue.playItem(0, player);
    await _settle();
    expect(lookups, 1);
    expect(player.audio.prepared, isEmpty);
    player.audio.playing = false;
    await queue.playNext(player, isAutomatic: true);
    expect(lookups, 2);
    expect(queue.currentIndex, 1);
    expect(player.currentTrack?.title, 'Metadata');
    expect(player.audio.loaded, endsWith('/stream/retry-source'));
  });

  test(
      'changing crossfade invalidates the old schedule and stages the new duration',
      () async {
    queue.addAllToQueue([_file('first'), _file('next')]);
    queue.setCrossfadeDuration(const Duration(seconds: 3));
    queue.connectPlayback(player);
    await queue.playItem(0, player);
    await _settle();
    final stale = player.audio.prepared.last.token;
    expect(player.audio.prepared.last.crossfade, const Duration(seconds: 3));
    queue.setCrossfadeDuration(const Duration(seconds: 7));
    await _settle();
    expect(player.audio.prepared.last.crossfade, const Duration(seconds: 7));
    player.audio.handoffs.add(stale);
    await _settle();
    expect(player.adopted, isEmpty);
    expect(queue.currentIndex, 0);
  });

  test('restored paused selection only stages the next song after resume',
      () async {
    final previous = QueueService()
      ..addAllToQueue([_file('first'), _file('next')])
      ..setCurrentIndex(0);
    final snapshot = previous.exportSnapshot();
    previous.dispose();
    queue.restoreSnapshot(snapshot);
    player.select(queue.currentItem!, playing: false);
    queue.connectPlayback(player);
    await _settle();
    expect(player.audio.prepared, isEmpty);
    expect(player.adopted, isEmpty);
    player.audio.playing = true;
    player.notify();
    await _settle();
    expect(Uri.parse(player.audio.prepared.last.url).pathSegments.last,
        'next.mp3');
    expect(player.manualPlays, 0);
  });

  test(
      'crossfade preference persists with playback and clamps to supported range',
      () async {
    queue.setCrossfadeDuration(const Duration(seconds: 30));
    expect(queue.crossfadeDuration, const Duration(seconds: 12));
    queue.setCrossfadeDuration(const Duration(seconds: 4));
    queue.addToQueue(_file('first'));
    await queue.playItem(0, player);
    final session =
        PlaybackSessionService(userId: 1, queue: queue, player: player);
    await session.flush();
    final restored = await session.load();
    expect(restored!.crossfadeDuration, const Duration(seconds: 4));
    session.dispose();
  });
}
