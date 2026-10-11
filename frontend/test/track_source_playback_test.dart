import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/playlist_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/track_playback_helper.dart';

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

void main() {
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
        playlistService: _Playlists());
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
