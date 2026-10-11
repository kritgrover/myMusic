import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  Duration elapsed = Duration.zero;
  final List<Duration> seeks = [];
  @override
  Duration get position => elapsed;
  @override
  Future<void> seek(Duration position) async {
    elapsed = position;
    seeks.add(position);
  }
}

class _Player extends Fake implements PlayerStateService {
  final _Audio audio = _Audio();
  final List<String> played = [];
  final List<String?> originals = [];
  final List<String> preloaded = [];
  bool failPlayback = false;
  bool failPreload = false;
  @override
  void cancelPendingPlayback() {}
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  Future<void> streamTrack(String streamingUrl,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    if (failPlayback) throw StateError('unavailable');
    played.add(streamingUrl);
    originals.add(url);
  }

  @override
  Future<void> playTrack(String filename,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    if (failPlayback) throw StateError('unavailable');
    played.add(filename);
  }

  @override
  Future<void> preloadTrackUrl(String url) async {
    if (failPreload) throw StateError('preload unavailable');
    preloaded.add(url);
  }

  @override
  Future<void> preloadTrack(String filename) => preloadTrackUrl(filename);
}

QueueItem _track(String id) =>
    QueueItem(id: id, title: id, url: 'audio/$id', originalUrl: 'original/$id');

void main() {
  late QueueService queue;
  late _Player player;
  setUp(() {
    queue = QueueService(random: Random(7));
    player = _Player();
  });
  tearDown(() => queue.dispose());

  test('Next starts an idle queue and transitions are immediately reusable',
      () async {
    queue.addAllToQueue([_track('a'), _track('b'), _track('c')]);
    await queue.playNext(player);
    await queue.playNext(player);
    await queue.playNext(player);
    expect(player.played, ['audio/a', 'audio/b', 'audio/c']);
    expect(queue.isTransitioning, isFalse);
    expect(queue.hasNext, isFalse);
    expect(player.originals.last, 'original/c');
  });

  test('manual next bypasses repeat one; automatic completion repeats',
      () async {
    queue.addAllToQueue([_track('a'), _track('b')]);
    await queue.playItem(0, player);
    queue.toggleLoopMode();
    queue.toggleLoopMode();
    expect(queue.loopMode, LoopMode.single);
    await queue.playNext(player, isAutomatic: true);
    expect(queue.currentIndex, 0);
    await queue.playNext(player);
    expect(queue.currentIndex, 1);
    expect(player.played, ['audio/a', 'audio/a', 'audio/b']);
  });

  test('repeat queue enables and wraps Next and Previous', () async {
    queue.addAllToQueue([_track('a'), _track('b')]);
    queue.toggleLoopMode();
    await queue.playItem(1, player);
    expect(queue.hasNext, isTrue);
    await queue.playNext(player);
    expect(queue.currentIndex, 0);
    expect(queue.hasPrevious, isTrue);
    await queue.playPrevious(player);
    expect(queue.currentIndex, 1);
    expect(player.preloaded, contains('audio/a'));
  });

  test('previous restarts after three seconds, otherwise selects previous',
      () async {
    queue.addAllToQueue([_track('a'), _track('b')]);
    await queue.playItem(1, player);
    player.audio.elapsed = const Duration(seconds: 4);
    await queue.playPrevious(player);
    expect(queue.currentIndex, 1);
    expect(player.audio.seeks, [Duration.zero]);
    await queue.playPrevious(player);
    expect(queue.currentIndex, 0);
    await queue.playPrevious(player);
    expect(player.audio.seeks, [Duration.zero, Duration.zero]);
  });

  test(
      'shuffle keeps now playing and restores upcoming order including duplicates',
      () async {
    queue.addAllToQueue(
        [_track('a'), _track('b'), _track('b'), _track('c'), _track('d')]);
    await queue.playItem(0, player);
    final originalKeys = List.generate(queue.queueLength, queue.entryKeyAt);
    queue.toggleShuffle();
    expect(queue.isShuffled, isTrue);
    expect(queue.currentIndex, 0);
    expect(queue.currentItem!.id, 'a');
    expect(List.generate(queue.queueLength, queue.entryKeyAt),
        unorderedEquals(originalKeys));
    queue.toggleShuffle();
    expect(List.generate(queue.queueLength, queue.entryKeyAt), originalKeys);
  });

  test('clear upcoming and removal keep current track aligned with audio',
      () async {
    queue.addAllToQueue([_track('a'), _track('b'), _track('c')]);
    await queue.playItem(1, player);
    queue.removeFromQueue(1);
    expect(queue.currentItem!.id, 'b');
    expect(queue.queueLength, 3);
    queue.removeFromQueue(0);
    expect(queue.currentIndex, 0);
    queue.clearUpcoming();
    expect(queue.queue.map((item) => item.id), ['b']);
    expect(queue.currentItem!.id, 'b');
  });

  test('reorder upcoming selects the actual next entry and preserves current',
      () async {
    queue.addAllToQueue([_track('a'), _track('b'), _track('c'), _track('d')]);
    await queue.playItem(0, player);
    queue.reorderQueue(3, 1);
    expect(queue.queue.map((item) => item.id), ['a', 'd', 'b', 'c']);
    expect(queue.currentIndex, 0);
    await queue.playNext(player);
    expect(player.played.last, 'audio/d');
  });

  test('failed playback restores selection and unlocks retry', () async {
    queue.addAllToQueue([_track('a'), _track('b')]);
    await queue.playItem(0, player);
    player.failPlayback = true;
    await expectLater(queue.playNext(player), throwsStateError);
    expect(queue.currentIndex, 0);
    expect(queue.isTransitioning, isFalse);
    player.failPlayback = false;
    await queue.playNext(player);
    expect(queue.currentIndex, 1);
  });

  test('resolving a cleared queue cannot replace a new selection', () async {
    final pending = Completer<String?>();
    queue.addAllToQueue([QueueItem(id: 'slow', originalUrl: 'source')],
        loadStreamingUrl: (_) => pending.future);
    final oldPlayback = queue.playItem(0, player);
    queue.clearQueue();
    await queue.addAndPlay(_track('new'), player);
    pending.complete('audio/slow');
    await oldPlayback;
    expect(player.played, ['audio/new']);
    expect(queue.currentItem!.id, 'new');
  });

  test('a later selection wins over an earlier slow resolution', () async {
    final pending = Completer<String?>();
    queue.addAllToQueue(
        [QueueItem(id: 'slow', originalUrl: 'source'), _track('fast')],
        loadStreamingUrl: (_) => pending.future);
    final slowPlayback = queue.playItem(0, player);
    await queue.playItem(1, player);
    pending.complete('audio/slow');
    await slowPlayback;
    expect(player.played, ['audio/fast']);
    expect(queue.currentIndex, 1);
  });

  test('each appended playlist keeps its own URL resolver', () async {
    queue.addAllToQueue([QueueItem(id: 'a', originalUrl: 'source/a')],
        loadStreamingUrl: (_) async => 'resolved/a');
    queue.addAllToQueue([QueueItem(id: 'b', originalUrl: 'source/b')],
        loadStreamingUrl: (_) async => 'resolved/b');
    await queue.playItem(0, player);
    await queue.playNext(player);
    expect(player.played, ['resolved/a', 'resolved/b']);
  });

  test(
      'failed quick selection restores the last played song, not a pending song',
      () async {
    final pending = Completer<String?>();
    queue.addAllToQueue([
      _track('a'),
      QueueItem(id: 'slow', originalUrl: 'source'),
      _track('bad'),
    ], loadStreamingUrl: (_) => pending.future);
    await queue.playItem(0, player);
    final slowPlayback = queue.playItem(1, player);
    player.failPlayback = true;
    await expectLater(queue.playItem(2, player), throwsStateError);
    expect(queue.currentItem!.id, 'a');
    pending.completeError(StateError('old resolution failed'));
    await slowPlayback;
    expect(queue.currentItem!.id, 'a');
    expect(queue.isTransitioning, isFalse);
  });

  test('preloading failures never break active playback', () async {
    player.failPreload = true;
    queue.addAllToQueue([_track('a'), _track('b')]);
    await queue.playItem(0, player);
    await Future<void>.delayed(Duration.zero);
    expect(queue.currentIndex, 0);
    expect(player.played, ['audio/a']);
  });
}
