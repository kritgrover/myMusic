import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/screens/playlist_detail_screen.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/offline_download_service.dart';
import 'package:music_downloader/services/playlist_service.dart';

class _Offline extends ChangeNotifier implements OfflineDownloadService {
  @override
  bool isSupported = true;
  @override
  bool isInitialized = true;
  @override
  List<OfflineDownloadJob> jobs = [];
  @override
  List<OfflineTrack> tracks = [];
  final saved = <QueueItem>[];
  final playlists = <Playlist>[];
  String? playlistId;
  String? playlistName;
  String? failure;

  void finish(OfflineTrack track) {
    tracks.add(track);
    notifyListeners();
  }

  @override
  OfflineDownloadJob? jobFor(QueueItem item) {
    final matching = jobs.where((job) =>
        job.track.id == item.id &&
        job.track.originalUrl == item.originalUrl &&
        job.track.filename == item.filename);
    return matching.isEmpty ? null : matching.last;
  }

  @override
  Future<void> downloadTrack(QueueItem item,
      {String? playlistId, String? playlistName}) async {
    saved.add(item);
    this.playlistId = playlistId;
    this.playlistName = playlistName;
    jobs.add(OfflineDownloadJob(
        id: 'job',
        track: item,
        status: failure == null
            ? OfflineDownloadStatus.complete
            : OfflineDownloadStatus.failed,
        error: failure));
  }

  @override
  Future<void> downloadPlaylist(Playlist playlist) async {
    playlists.add(playlist);
    if (failure != null) {
      jobs.addAll(playlist.tracks.map((track) => OfflineDownloadJob(
            id: 'job-${track.id}',
            track: QueueItem(
                id: 'track_${track.id}',
                originalUrl: track.url,
                filename: track.filename),
            status: OfflineDownloadStatus.failed,
            error: failure,
          )));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playlists extends PlaylistService {
  @override
  Future<Playlist?> getPlaylist(String id) async => null;
}

class _Api extends ApiService {
  final resolved = <Map<String, dynamic>>[];
  final batches = <List<Map<String, dynamic>>>[];
  String? source = 'https://www.youtube.com/watch?v=abcdefghijk';
  String? failure;

  @override
  Future<String?> resolveToYouTubeUrl(String? url, String title, String? artist,
      {String? album, double? duration, String? spotifyId}) async {
    resolved.add({
      'url': url,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'spotify_id': spotifyId
    });
    return source;
  }

  @override
  Future<Map<String, dynamic>> startBatchDownload(
      List<Map<String, dynamic>> downloads) async {
    batches.add(downloads);
    return {'download_id': 'batch'};
  }

  @override
  Future<DownloadProgress> getDownloadProgress(String id) async =>
      DownloadProgress(
          current: 1,
          total: 1,
          status: 'completed',
          processed: failure == null ? 1 : 0,
          failed: failure == null ? 0 : 1,
          downloads: [
            failure == null
                ? {'success': true, 'filename': 'song.m4a'}
                : {'success': false, 'error': failure}
          ]);

  @override
  Future<List<DownloadedFile>> listDownloads() async => [];
}

const _spotifyId = '1234567890123456789012';
Playlist _playlist({String filename = '', String? url}) => Playlist(
        id: 'mix',
        name: 'Evening mix',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          PlaylistTrack(
            id: _spotifyId,
            title: 'Moonlight',
            artist: 'Luna',
            album: 'After hours',
            duration: 183,
            thumbnail: 'https://example.com/art.jpg',
            filename: filename,
            url: url ?? 'https://open.spotify.com/track/$_spotifyId',
          )
        ]);

void main() {
  late _Offline offline;
  late _Api api;
  late _Playlists playlists;
  setUp(() {
    offline = _Offline();
    api = _Api();
    playlists = _Playlists();
  });
  tearDown(() {
    offline.dispose();
  });

  Future<void> show(WidgetTester tester,
      {String filename = '', String? url}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlaylistDetailScreen(
      playlist: _playlist(filename: filename, url: url),
      playlistService: playlists,
      offlineService: offline,
      apiService: api,
    ))));
    await tester.pumpAndSettle();
  }

  testWidgets('native song download stores device copy with playlist identity',
      (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Save on this device'));
    await tester.pumpAndSettle();
    final item = offline.saved.single;
    expect(item.title, 'Moonlight');
    expect(item.artist, 'Luna');
    expect(item.album, 'After hours');
    expect(item.duration, 183);
    expect(item.thumbnail, 'https://example.com/art.jpg');
    expect(item.originalUrl, 'https://open.spotify.com/track/$_spotifyId');
    expect(item.spotifyId, _spotifyId);
    expect(offline.playlistId, 'mix');
    expect(offline.playlistName, 'Evening mix');
    expect(api.batches, isEmpty);
  });

  testWidgets('server file is still offered as a native device download',
      (tester) async {
    await show(tester, filename: 'server-song.m4a');
    await tester.tap(find.byTooltip('Save on this device'));
    await tester.pumpAndSettle();
    expect(offline.saved.single.filename, 'server-song.m4a');
    expect(api.batches, isEmpty);
  });

  testWidgets('native header download includes server files for offline saving',
      (tester) async {
    await show(tester, filename: 'server-song.m4a');
    await tester.tap(find.byTooltip('Download playlist for offline'));
    await tester.pumpAndSettle();
    expect(offline.playlists.single.tracks.single.filename, 'server-song.m4a');
    expect(api.batches, isEmpty);
  });

  testWidgets('compact native song menu offers device download',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, filename: 'server-song.m4a');
    await tester.tap(find.byTooltip('More song actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save on this device'));
    await tester.pumpAndSettle();
    expect(offline.saved.single.filename, 'server-song.m4a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('web resolves catalog source before starting server download',
      (tester) async {
    offline.isSupported = false;
    await show(tester);
    await tester.tap(find.byTooltip('Download to server'));
    await tester.pumpAndSettle();
    expect(api.resolved.single, {
      'url': 'https://open.spotify.com/track/$_spotifyId',
      'title': 'Moonlight',
      'artist': 'Luna',
      'album': 'After hours',
      'duration': 183.0,
      'spotify_id': _spotifyId,
    });
    expect(api.batches.single.single['url'], api.source);
    expect(api.batches.single.single['spotify_id'], _spotifyId);
    expect(offline.saved, isEmpty);
  });

  testWidgets('web batch resolves catalog tracks before submission',
      (tester) async {
    offline.isSupported = false;
    await show(tester);
    await tester.tap(find.byTooltip('Prepare missing tracks on server'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Download'));
    await tester.pumpAndSettle();
    expect(api.batches.single.single['url'], api.source);
    expect(api.batches.single.single['spotify_id'], _spotifyId);
  });

  testWidgets('failed web job gives reason without exposing backend paths',
      (tester) async {
    offline.isSupported = false;
    api.failure = r'ERROR: ffmpeg missing at C:\private\ffmpeg.exe';
    await show(tester);
    await tester.tap(find.byTooltip('Download to server'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            '0 downloaded, 1 failed. The server could not convert the audio. Please retry.'),
        findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets('native failed job shows actionable feedback on playlist',
      (tester) async {
    offline.failure = 'ERROR: Sign in to confirm you are not a bot';
    await show(tester);
    await tester.tap(find.byTooltip('Save on this device'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The audio provider could not supply this recording. Try another source.'),
        findsOneWidget);
  });

  testWidgets('native bulk failure is shown on playlist after downloads finish',
      (tester) async {
    offline.failure = 'ERROR: Sign in to confirm you are not a bot';
    await show(tester);
    await tester.tap(find.byTooltip('Download playlist for offline'));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'The audio provider could not supply this recording. Try another source.'),
        findsOneWidget);
    expect(api.batches, isEmpty);
  });

  testWidgets('native header reports device storage not ready', (tester) async {
    offline.isInitialized = false;
    await show(tester);
    await tester.tap(find.byTooltip('Download playlist for offline'));
    await tester.pumpAndSettle();
    expect(find.text('Device downloads are not ready. Please retry.'),
        findsOneWidget);
    expect(offline.playlists, isEmpty);
    expect(api.batches, isEmpty);
  });

  testWidgets('native row updates when device download completes',
      (tester) async {
    await show(tester);
    expect(find.byTooltip('Save on this device'), findsOneWidget);
    offline.finish(OfflineTrack(
      id: 'local',
      filename: 'song.m4a',
      title: 'Moonlight',
      bytes: 123,
      downloadedAt: DateTime(2026),
      sourceKeys: ['spotify:$_spotifyId'],
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Saved on this device'), findsOneWidget);
    expect(find.byTooltip('Save on this device'), findsNothing);
  });

  testWidgets(
      'successful corrected source does not show an older source failure',
      (tester) async {
    offline.jobs.add(OfflineDownloadJob(
      id: 'old-source',
      track: QueueItem(
          id: 'track_$_spotifyId',
          filename: '',
          originalUrl: 'https://www.youtube.com/watch?v=oldsource01'),
      status: OfflineDownloadStatus.failed,
      error: 'Sign in to confirm you are not a bot',
    ));
    await show(tester, url: 'https://www.youtube.com/watch?v=newsource01');
    await tester.tap(find.byTooltip('Save on this device'));
    await tester.pumpAndSettle();
    expect(offline.jobs, hasLength(2));
    expect(offline.jobs.last.status, OfflineDownloadStatus.complete);
    expect(
        find.textContaining('could not supply this recording'), findsNothing);
  });
}
