import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/offline_media_resolver.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  @override
  Duration get position => Duration.zero;
}

class _Player extends Fake implements PlayerStateService {
  final played = <String>[];
  final preloaded = <String>[];
  @override
  AudioPlayerService get audioPlayer => _Audio();
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
    played.add(filename);
  }

  @override
  Future<void> preloadTrack(String filename) async => preloaded.add(filename);
}

void main() {
  test('device playback never asks the backend for media authorization',
      () async {
    final resolver = OfflineMediaResolver(
      localUrl: (canonical) async => 'file:///music/song.m4a',
      remoteUrl: (_) async => throw StateError('Network must not be used'),
    );
    expect(await resolver.resolve('https://music.test/downloads/song.m4a'),
        'file:///music/song.m4a');
  });

  test('missing device copy retains the normal authorized streaming fallback',
      () async {
    final remoteCalls = <String>[];
    final resolver = OfflineMediaResolver(
      localUrl: (_) async => null,
      remoteUrl: (canonical) async {
        remoteCalls.add(canonical);
        return '$canonical?media_token=temporary';
      },
    );
    const canonical = 'https://music.test/downloads/song.m4a';
    expect(
        await resolver.resolve(canonical), '$canonical?media_token=temporary');
    expect(remoteCalls, [canonical]);
  });

  test(
      'restored lazy playlist resolves local tracks before remote lookup and preloads locally',
      () async {
    final player = _Player();
    final queue = QueueService(
        localTrackResolver: (item) async => QueueItem(
              id: item.id,
              title: item.title,
              filename: '${item.id}.m4a',
              originalUrl: item.originalUrl,
            ));
    addTearDown(queue.dispose);
    queue.addAllToQueue([
      QueueItem(
          id: 'first',
          title: 'Studio',
          originalUrl: 'https://example.test/first'),
      QueueItem(
          id: 'second',
          title: 'Live',
          originalUrl: 'https://example.test/second'),
    ],
        loadStreamingUrl: (_) async =>
            throw StateError('Network must not be used'));
    final snapshot = queue.exportSnapshot();
    queue.restoreSnapshot(snapshot,
        loadStreamingUrl: (_) async =>
            throw StateError('Network must not be used'));
    await queue.playItem(0, player);
    await Future<void>.delayed(Duration.zero);
    expect(player.played, ['first.m4a']);
    expect(player.preloaded, ['second.m4a']);
    await queue.playNext(player);
    expect(player.played, ['first.m4a', 'second.m4a']);
    expect(
        queue.queue.every((track) => !(track.filename ?? '').contains('file:')),
        isTrue);
  });
}
