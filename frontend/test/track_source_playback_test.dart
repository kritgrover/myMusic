import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/playlist_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/track_playback_helper.dart';
import 'package:music_downloader/services/offline_download_service.dart';

const chosenUrl = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
const spotifyId = '0123456789abcdefghijkl';

class _Api extends Fake implements ApiService {
  final identities = <Map<String, dynamic>>[];
  final streamedUrls = <String>[];
  String? downloadedUrl;
  @override
  Future<String?> resolveToYouTubeUrl(String? url, String title, String? artist,
      {String? album, double? duration, String? spotifyId}) async {
    identities.add({
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'spotifyId': spotifyId
    });
    return chosenUrl;
  }

  @override
  Future<StreamResult> getStreamingUrl(
      {required String url, required String title, String artist = ''}) async {
    streamedUrls.add(url);
    return StreamResult(
        success: true,
        streamingUrl: 'http://localhost/stream/$url',
        title: title,
        artist: artist);
  }

  @override
  Future<DownloadResult> downloadAudio(
      {required String url,
      required String title,
      String artist = '',
      String album = '',
      String outputFormat = 'm4a',
      bool embedThumbnail = false,
      String? spotifyId}) async {
    downloadedUrl = url;
    return DownloadResult(
        success: true,
        filePath: 'song.m4a',
        filename: 'song.m4a',
        title: title,
        artist: artist,
        album: album);
  }
}

class _Queue extends Fake implements QueueService {
  final played = <QueueItem>[];
  final queued = <QueueItem>[];
  @override
  void clearQueue() {}
  @override
  Future<void> addAndPlay(QueueItem item, PlayerStateService player,
          {bool skipRecentlyPlayed = false}) async =>
      played.add(item);
  @override
  void addToQueue(QueueItem item) => queued.add(item);
}

class _Player extends Fake implements PlayerStateService {}

class _Playlists extends Fake implements PlaylistService {}

class _BrowserDownloads extends Fake implements OfflineDownloadService {
  @override
  bool get isSupported => false;
  @override
  Future<QueueItem?> localQueueItemFor(QueueItem item) async => null;
}

class _DeviceDownloads extends _BrowserDownloads {
  bool ready = true;
  final requested = <QueueItem>[];
  @override
  bool get isSupported => true;
  @override
  bool get isInitialized => ready;
  @override
  Future<void> downloadTrack(QueueItem track,
      {String? playlistId, String? playlistName}) async {
    requested.add(track);
  }
}

void main() {
  testWidgets(
      'native download preserves identity for the device manager and never falls back during startup',
      (tester) async {
    late BuildContext context;
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    }))));
    final api = _Api();
    final device = _DeviceDownloads()..ready = false;
    final helper = TrackPlaybackHelper(
      apiService: api,
      queueService: _Queue(),
      playerStateService: _Player(),
      playlistService: _Playlists(),
      offlineService: device,
    );
    final track = PlaylistTrack(
      id: spotifyId,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      filename: '',
      url: chosenUrl,
      duration: 181,
    );
    await helper.download(context, track);
    expect(device.requested, isEmpty);
    expect(api.downloadedUrl, isNull);
    device.ready = true;
    await helper.download(context, track);
    expect(device.requested.single.spotifyId, spotifyId);
    expect(device.requested.single.originalUrl, chosenUrl);
    expect(device.requested.single.duration, 181);
    expect(api.identities, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'play, queue, lazy resume and download use the same selected recording',
      (tester) async {
    late BuildContext context;
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (value) {
      context = value;
      return const SizedBox();
    }))));
    final api = _Api();
    final queue = _Queue();
    final helper = TrackPlaybackHelper(
        apiService: api,
        queueService: queue,
        playerStateService: _Player(),
        playlistService: _Playlists(),
        offlineService: _BrowserDownloads());
    final track = PlaylistTrack(
        id: spotifyId,
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: 181,
        filename: '',
        url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa');

    await helper.playTrack(context, track);
    await helper.addToQueue(context, track);
    await helper.loadStreamingUrl(QueueItem.fromPlaylistTrackLazy(
      trackId: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      originalUrl: track.url!,
    ));
    await helper.download(context, track);
    await tester.pumpAndSettle();

    expect(queue.played.single.originalUrl, chosenUrl);
    expect(queue.queued.single.originalUrl, chosenUrl);
    expect(queue.played.single.spotifyId, spotifyId);
    expect(api.streamedUrls, [chosenUrl, chosenUrl, chosenUrl]);
    expect(api.downloadedUrl, chosenUrl);
    expect(
        api.identities,
        List.filled(4, {
          'title': 'Song',
          'artist': 'Artist',
          'album': 'Album',
          'duration': 181.0,
          'spotifyId': spotifyId,
        }));
  });
}
