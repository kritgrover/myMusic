import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/song_radio_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  @override
  Duration get position => const Duration(seconds: 40);
  @override
  Future<void> seek(Duration position) async {}
}

class _Player extends Fake implements PlayerStateService {
  int revision = 0;
  bool failPlayback = false;
  Completer<void>? prepareGate;
  Completer<void>? prepareStarted;
  int cancellations = 0;
  String? current;
  final played = <String>[];
  final audio = _Audio();
  @override
  int get playbackRevision => revision;
  @override
  String? get currentTrackUrl => current;
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  void cancelPendingPlayback() {
    cancellations++;
    revision++;
  }

  @override
  Future<void> streamTrack(String value,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    final request = ++revision;
    final gate = prepareGate;
    if (gate != null) {
      if (!(prepareStarted?.isCompleted ?? true)) prepareStarted!.complete();
      await gate.future;
    }
    if (request != revision) return;
    if (failPlayback) throw StateError('Audio unavailable');
    current = value;
    played.add(trackName ?? value);
  }

  @override
  Future<void> preloadTrackUrl(String value) async {}
}

QueueItem track(String name, {String artist = 'Artist', String? catalogId}) =>
    QueueItem(
        id: name,
        title: name,
        artist: artist,
        spotifyId: catalogId,
        url: 'https://audio.example/$name.m4a');

void main() {
  late QueueService queue;
  late _Player player;
  late SongRadioService radio;
  late List<QueueItem> response;
  late List<QueueItem> requestedSeeds;
  late List<List<QueueItem>> exclusions;
  late bool sessionCurrent;
  Completer<List<QueueItem>>? gate;
  bool fail = false;

  setUp(() async {
    queue = QueueService();
    player = _Player();
    response = [track('One'), track('Two')];
    requestedSeeds = [];
    exclusions = [];
    sessionCurrent = true;
    gate = null;
    fail = false;
    radio = SongRadioService(
        queue: queue,
        player: player,
        isSessionCurrent: () => sessionCurrent,
        fetchRadio: (seed, exclude) async {
          requestedSeeds.add(seed);
          exclusions.add(exclude);
          if (fail) throw StateError('Provider unavailable');
          if (gate != null) return gate!.future;
          return response;
        });
    queue.addToQueue(track('Old'));
    await queue.playItem(0, player);
    player.played.clear();
  });

  tearDown(() {
    radio.dispose();
    queue.dispose();
  });

  test('explicit radio starts its seed followed by unique related recordings',
      () async {
    response = [
      track('Seed'),
      track('One'),
      track('One', artist: ' artist '),
      track('One (Live)'),
      track('Two')
    ];
    expect(await radio.startRadio(track('Seed')), isTrue);
    expect(queue.queue.map((row) => row.title),
        ['Seed', 'One', 'One (Live)', 'Two']);
    expect(player.played, ['Seed']);
    expect(requestedSeeds.single.title, 'Seed');
    expect(exclusions.single.map((row) => row.title),
        containsAll(['Seed', 'Old']));
  });

  test('shuffle keeps the explicitly selected seed first', () async {
    queue.toggleShuffle();
    await radio.startRadio(track('Seed'));
    expect(queue.queue.first.title, 'Seed');
    expect(queue.queue.skip(1).map((row) => row.title),
        unorderedEquals(['One', 'Two']));
    expect(player.played, ['Seed']);
  });

  test('catalog and source identities collapse metadata aliases', () {
    const id = '1234567890123456789012';
    expect(
        SongRadioService.sameRecording(
            track('One', catalogId: id), track('Renamed', catalogId: id)),
        isTrue);
    final source = QueueItem(
        id: 'source',
        title: 'Alias',
        artist: 'Other',
        originalUrl: 'https://www.youtube.com/watch?v=abcdefghijk');
    final other = QueueItem(
        id: 'other',
        title: 'Other',
        artist: 'Other',
        originalUrl: 'https://youtu.be/abcdefghijk');
    expect(SongRadioService.sameRecording(source, other), isTrue);
    expect(SongRadioService.sameRecording(track('One'), track('One (Live)')),
        isFalse);
    expect(
        SongRadioService.sameRecording(
            track('One', catalogId: id),
            QueueItem(
                id: 'live',
                title: 'One',
                artist: 'Artist',
                album: 'Live at Wembley',
                spotifyId: '2234567890123456789012')),
        isFalse);
  });

  for (final empty in [false, true]) {
    test(
        '${empty ? 'empty' : 'failed'} radio leaves current queue and playback intact',
        () async {
      fail = !empty;
      if (empty) response = [];
      expect(await radio.startRadio(track('Seed')), isFalse);
      expect(queue.queue.single.title, 'Old');
      expect(player.played, isEmpty);
      expect(radio.message, isNotNull);
      expect(radio.busy, isFalse);
    });
  }

  test('queue edits and selection changes invalidate late radio', () async {
    gate = Completer();
    final pending = radio.startRadio(track('Seed'));
    queue.addToQueue(track('Manual addition'));
    gate!.complete(response);
    expect(await pending, isFalse);
    expect(queue.queue.map((row) => row.title), ['Old', 'Manual addition']);
    expect(player.played, isEmpty);
  });

  test('manual next at the queue end invalidates pending recommendations',
      () async {
    radio.setAutoplayEnabled(true);
    gate = Completer();
    final pending = radio.onQueueCompleted();
    await queue.playNext(player);
    gate!.complete(response);
    expect(await pending, isFalse);
    expect(queue.queue.single.title, 'Old');
    expect(player.played, isEmpty);
  });

  test('manual previous seek and pause invalidate pending radio', () async {
    gate = Completer();
    final pending = radio.startRadio(track('Seed'));
    await queue.playPrevious(player);
    gate!.complete(response);
    expect(await pending, isFalse);
    gate = Completer();
    final next = radio.startRadio(track('Seed'));
    player.revision++; // A pause or a direct playback intent.
    gate!.complete(response);
    expect(await next, isFalse);
    expect(player.played, isEmpty);
  });

  test('newer explicit radio wins over an earlier pending request', () async {
    gate = Completer();
    final first = radio.startRadio(track('First seed'));
    final oldGate = gate!;
    gate = null;
    expect(await radio.startRadio(track('Second seed')), isTrue);
    oldGate.complete([track('Stale result')]);
    expect(await first, isFalse);
    expect(queue.queue.first.title, 'Second seed');
    expect(queue.queue.any((row) => row.title == 'Stale result'), isFalse);
  });

  test('autoplay is opt-in and only extends natural completion once', () async {
    expect(await radio.onQueueCompleted(), isFalse);
    expect(requestedSeeds, isEmpty);
    radio.setAutoplayEnabled(true);
    gate = Completer();
    final pending = radio.onQueueCompleted();
    expect(await radio.onQueueCompleted(), isFalse);
    gate!.complete(response);
    expect(await pending, isTrue);
    expect(queue.queue.map((row) => row.title), ['Old', 'One', 'Two']);
    expect(queue.currentIndex, 1);
    expect(player.played, ['One']);
    expect(requestedSeeds, hasLength(1));
  });

  test('autoplay respects repeat and nonempty upcoming queue', () async {
    radio.setAutoplayEnabled(true);
    queue.toggleLoopMode();
    expect(await radio.onQueueCompleted(), isFalse);
    queue.toggleLoopMode();
    expect(await radio.onQueueCompleted(), isFalse);
    queue.toggleLoopMode();
    queue.addToQueue(track('Next'));
    expect(await radio.onQueueCompleted(), isFalse);
    expect(requestedSeeds, isEmpty);
  });

  test('direct playback cannot extend an unrelated stale queue', () async {
    radio.setAutoplayEnabled(true);
    player.current = 'https://audio.example/Direct.m4a';
    expect(await radio.onQueueCompleted(), isFalse);
    expect(requestedSeeds, isEmpty);
  });

  test('turning autoplay off and back on still cancels the prior request',
      () async {
    radio.setAutoplayEnabled(true);
    gate = Completer();
    final pending = radio.onQueueCompleted();
    radio.setAutoplayEnabled(false);
    radio.setAutoplayEnabled(true);
    gate!.complete(response);
    expect(await pending, isFalse);
    expect(queue.queue.single.title, 'Old');
    expect(player.played, isEmpty);
  });

  test('account change and disposal cannot mutate the old queue', () async {
    gate = Completer();
    final pending = radio.startRadio(track('Seed'));
    sessionCurrent = false;
    gate!.complete(response);
    expect(await pending, isFalse);
    expect(queue.queue.single.title, 'Old');
    sessionCurrent = true;
    gate = Completer();
    final next = radio.startRadio(track('Seed'));
    radio.dispose();
    gate!.complete(response);
    expect(await next, isFalse);
    expect(queue.queue.single.title, 'Old');
    // Avoid a second ChangeNotifier disposal in teardown.
    radio = SongRadioService(
        queue: queue, player: player, fetchRadio: (_, __) async => []);
  });

  test('exclusions and recommendation additions stay bounded', () async {
    queue
        .addAllToQueue(List.generate(130, (index) => track('Previous $index')));
    response = List.generate(50, (index) => track('New $index'));
    await radio.startRadio(track('Seed'));
    expect(exclusions.single, hasLength(100));
    expect(queue.queueLength, 21);
  });

  test('repeated completion does not repeat a previous no-match message',
      () async {
    radio.setAutoplayEnabled(true);
    response = [];
    expect(await radio.onQueueCompleted(), isFalse);
    expect(radio.message, isNotNull);
    expect(await radio.onQueueCompleted(), isFalse);
    expect(radio.message, isNull);
    expect(requestedSeeds, hasLength(1));
  });

  test('recently played recordings remain excluded after queue replacement',
      () async {
    await radio.startRadio(track('Seed'));
    await queue.playItem(1, player);
    response = [track('Third'), track('Fourth')];
    await radio.startRadio(track('Another seed'));
    response = [track('One'), track('New discovery')];
    await radio.startRadio(track('Final seed'));
    expect(
        queue.queue.map((row) => row.title), ['Final seed', 'New discovery']);
    expect(exclusions.last.map((row) => row.title), contains('One'));
  });

  test('manual clear discards late results and errors quietly', () async {
    gate = Completer();
    final pending = radio.startRadio(track('Seed'));
    queue.clearQueue();
    gate!.completeError(StateError('Provider unavailable'));
    expect(await pending, isFalse);
    expect(queue.queue, isEmpty);
    expect(radio.message, isNull);
  });

  test('timed out provider stops cleanly and cannot apply a late result',
      () async {
    final lateResult = Completer<List<QueueItem>>();
    radio.dispose();
    radio = SongRadioService(
        queue: queue,
        player: player,
        fetchRadio: (_, __) => lateResult.future,
        requestTimeout: const Duration(milliseconds: 1));
    expect(await radio.startRadio(track('Seed')), isFalse);
    lateResult.complete(response);
    await Future<void>.value();
    expect(queue.queue.single.title, 'Old');
    expect(radio.busy, isFalse);
    expect(radio.message, isNotNull);
  });

  for (final automatic in [false, true]) {
    test(
        '${automatic ? 'autoplay' : 'radio'} exposes actual audio load failures',
        () async {
      player.failPlayback = true;
      radio.setAutoplayEnabled(automatic);
      final started = automatic
          ? await radio.onQueueCompleted()
          : await radio.startRadio(track('Seed'));
      expect(started, isFalse);
      expect(
          radio.message,
          contains(automatic
              ? 'Could not load more songs'
              : 'Could not start song radio'));
      expect(radio.busy, isFalse);
      expect(queue.currentItem?.title, automatic ? 'Old' : null);
    });
  }

  for (final action in ['autoplay off', 'cancel', 'dispose']) {
    test('$action cancels radio while the audio engine is preparing', () async {
      radio.setAutoplayEnabled(true);
      final engine = Completer<void>();
      player.prepareGate = engine;
      player.prepareStarted = Completer<void>();
      final pending = radio.onQueueCompleted();
      await player.prepareStarted!.future;
      final before = player.cancellations;
      switch (action) {
        case 'autoplay off':
          radio.setAutoplayEnabled(false);
          break;
        case 'cancel':
          radio.cancelPending();
          break;
        case 'dispose':
          radio.dispose();
          break;
      }
      expect(player.cancellations, before + 1);
      engine.complete();
      expect(await pending, isFalse);
      expect(player.played, isEmpty);
      expect(player.current, 'https://audio.example/Old.m4a');
      expect(queue.currentItem?.title, 'Old');
      expect(queue.isTransitioning, isFalse);
      if (action == 'dispose') {
        radio = SongRadioService(
            queue: queue, player: player, fetchRadio: (_, __) async => []);
      }
    });
  }

  for (final throughQueue in [false, true]) {
    test(
        'cancelling radio preserves newer ${throughQueue ? 'queue' : 'direct'} audio preparation',
        () async {
      radio.setAutoplayEnabled(true);
      final radioEngine = Completer<void>();
      player.prepareGate = radioEngine;
      player.prepareStarted = Completer<void>();
      final pending = radio.onQueueCompleted();
      await player.prepareStarted!.future;
      final manualEngine = Completer<void>();
      player.prepareGate = manualEngine;
      player.prepareStarted = Completer<void>();
      final manualTrack = track('Manual');
      late Future<void> manual;
      if (throughQueue) {
        queue.addToQueue(manualTrack);
        manual = queue.playItem(queue.queueLength - 1, player);
      } else {
        manual =
            player.streamTrack(manualTrack.url!, trackName: manualTrack.title);
      }
      await player.prepareStarted!.future;
      final before = player.cancellations;
      radio.setAutoplayEnabled(false);
      expect(player.cancellations, before);
      manualEngine.complete();
      await manual;
      radioEngine.complete();
      expect(await pending, isFalse);
      expect(player.played, ['Manual']);
      expect(player.current, manualTrack.url);
    });
  }

  for (final change in [
    'pause',
    'queue edit',
    'autoplay off',
    'account',
    'dispose'
  ]) {
    test('$change during audio resolution prevents late autoplay', () async {
      final resolving = Completer<void>();
      final audioUrl = Completer<String?>();
      radio.dispose();
      radio = SongRadioService(
          queue: queue,
          player: player,
          isSessionCurrent: () => sessionCurrent,
          fetchRadio: (_, __) async => [
                QueueItem(
                    id: 'lazy',
                    title: 'Lazy',
                    artist: 'Artist',
                    originalUrl: '')
              ],
          loadStreamingUrl: (_) {
            resolving.complete();
            return audioUrl.future;
          });
      radio.setAutoplayEnabled(true);
      final pending = radio.onQueueCompleted();
      await resolving.future;
      switch (change) {
        case 'pause':
          player.revision++;
          break;
        case 'queue edit':
          queue.addToQueue(track('Manual'));
          break;
        case 'autoplay off':
          radio.setAutoplayEnabled(false);
          break;
        case 'account':
          sessionCurrent = false;
          break;
        case 'dispose':
          radio.dispose();
          break;
      }
      audioUrl.complete('https://audio.example/lazy.m4a');
      expect(await pending, isFalse);
      expect(player.played, isEmpty);
      expect(queue.currentItem?.title, 'Old');
      if (change == 'dispose') {
        radio = SongRadioService(
            queue: queue, player: player, fetchRadio: (_, __) async => []);
      }
    });
  }
}
