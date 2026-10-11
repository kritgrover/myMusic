import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/screens/spotify_playlist_screen.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/offline_download_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';

const _spotifyId = 'aaaaaaaaaaaaaaaaaaaaaa';
const _spotifyUrl = 'https://open.spotify.com/track/$_spotifyId';
const _source = 'https://www.youtube.com/watch?v=abcdefghijk';

class _Player extends Fake implements PlayerStateService {
  @override
  String? get currentTrackUrl => null;
}

class _Api extends ApiService {
  final resolutions = <Map<String, Object?>>[];
  final batches = <List<Map<String, dynamic>>>[];
  String? resolvedSource = _source;

  @override
  Future<String?> resolveToYouTubeUrl(String? url, String title, String? artist,
      {String? album, double? duration, String? spotifyId}) async {
    resolutions.add({
      'url': url,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'spotifyId': spotifyId,
    });
    return resolvedSource;
  }

  @override
  Future<Map<String, dynamic>> startBatchDownload(
      List<Map<String, dynamic>> downloads) async {
    batches.add(downloads);
    return {'download_id': 'batch'};
  }
}

class _Offline extends ChangeNotifier implements OfflineDownloadService {
  @override
  bool isSupported = true;
  @override
  bool isInitialized = true;
  @override
  List<OfflineTrack> tracks = [];
  @override
  List<OfflineDownloadJob> jobs = [];
  final songs = <QueueItem>[];
  final playlists = <Playlist>[];
  String? playlistId;
  String? playlistName;
  String? failure;
  final currentJobs = <String?, OfflineDownloadJob>{};

  @override
  OfflineDownloadJob? jobFor(QueueItem item) =>
      currentJobs[item.originalUrl ?? item.filename];

  @override
  Future<void> downloadTrack(QueueItem track,
      {String? playlistId, String? playlistName}) async {
    songs.add(track);
    this.playlistId = playlistId;
    this.playlistName = playlistName;
    final job = OfflineDownloadJob(
      id: 'job',
      track: track,
      status: failure == null
          ? OfflineDownloadStatus.complete
          : OfflineDownloadStatus.failed,
      error: failure,
    );
    jobs.add(job);
    currentJobs[track.originalUrl ?? track.filename] = job;
    notifyListeners();
  }

  @override
  Future<void> downloadPlaylist(Playlist playlist) async {
    playlists.add(playlist);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PlaylistTrack _song({String filename = '', String? url = _spotifyUrl}) =>
    PlaylistTrack(
      id: 'playlist-entry',
      title: 'Test recording',
      artist: 'Test artist',
      album: 'Test album',
      filename: filename,
      url: url,
      duration: 201,
    );

void main() {
  late _Offline offline;
  late _Api api;
  late QueueService queue;
  final started = <String>[];

  setUp(() {
    offline = _Offline();
    api = _Api();
    queue = QueueService();
    started.clear();
  });
  tearDown(() {
    offline.dispose();
    queue.dispose();
  });

  Future<void> show(WidgetTester tester, {List<PlaylistTrack>? tracks}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: SpotifyPlaylistScreen(
        playlistId: 'catalog-playlist',
        playlistName: 'Road songs',
        playerStateService: _Player(),
        queueService: queue,
        apiService: api,
        offlineService: offline,
        trackLoader: () async => tracks ?? [_song()],
        onDownloadStart: started.add,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('native song downloads preserve source identity and membership',
      (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    final item = offline.songs.single;
    expect(item.originalUrl, _spotifyUrl);
    expect(item.spotifyId, _spotifyId);
    expect(item.title, 'Test recording');
    expect(item.artist, 'Test artist');
    expect(item.album, 'Test album');
    expect(item.duration, 201);
    expect(offline.playlistId, 'catalog-playlist');
    expect(offline.playlistName, 'Road songs');
    expect(api.batches, isEmpty);
    expect(api.resolutions, isEmpty);
    expect(started, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server file remains downloadable onto this device',
      (tester) async {
    await show(tester, tracks: [_song(filename: 'existing.m4a', url: null)]);
    expect(find.byTooltip('Download'), findsOneWidget);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(offline.songs.single.filename, 'existing.m4a');
    expect(api.batches, isEmpty);
  });

  for (final filename in ['', 'corrected.m4a']) {
    testWidgets('saved catalog alias does not hide changed recording $filename',
        (tester) async {
      offline.tracks = [
        OfflineTrack(
          id: 'old-recording',
          filename: 'old.m4a',
          title: 'Old recording',
          bytes: 100,
          downloadedAt: DateTime(2026),
          sourceKeys: const [
            'spotify:$_spotifyId',
            'file:old.m4a',
            'source:https://www.youtube.com/watch?v=oldrecord01',
          ],
        ),
      ];
      await show(tester, tracks: [
        PlaylistTrack(
          id: _spotifyId,
          title: 'Corrected recording',
          filename: filename,
          url: _source,
        ),
      ]);
      expect(find.byTooltip('Download'), findsOneWidget);
      expect(find.byTooltip('Saved on this device'), findsNothing);
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(offline.songs.single.originalUrl, _source);
      expect(offline.songs.single.filename, filename);
    });
  }

  testWidgets('native header saves the complete playlist with its order',
      (tester) async {
    final tracks = [_song(), _song(filename: 'existing.m4a', url: null)];
    await show(tester, tracks: tracks);
    await tester.tap(find.byTooltip('Download for offline'));
    await tester.pumpAndSettle();
    final playlist = offline.playlists.single;
    expect(playlist.id, 'catalog-playlist');
    expect(playlist.name, 'Road songs');
    expect(playlist.tracks, tracks);
    expect(api.batches, isEmpty);
    expect(started, isEmpty);
  });

  testWidgets('native download failure explains the problem without raw logs',
      (tester) async {
    offline.failure = 'ffmpeg failed at C:/private/server/path?token=secret';
    await show(tester);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(find.text('The server could not convert the audio. Please retry.'),
        findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('0 downloaded'), findsNothing);
  });

  testWidgets('corrected recording success does not report old source failure',
      (tester) async {
    offline.jobs = [
      OfflineDownloadJob(
        id: 'previous-source-job',
        track: QueueItem(
          id: 'track_playlist-entry',
          title: 'Test recording',
          originalUrl: 'https://www.youtube.com/watch?v=oldrecord01',
        ),
        status: OfflineDownloadStatus.failed,
        error: 'ffmpeg failed for the old source',
      ),
    ];
    await show(tester, tracks: [_song(url: _source)]);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(offline.jobs.first.status, OfflineDownloadStatus.failed);
    expect(offline.jobs.last.status, OfflineDownloadStatus.complete);
    expect(offline.songs.single.originalUrl, _source);
    expect(find.textContaining('could not convert'), findsNothing);
    expect(find.textContaining('could not be downloaded'), findsNothing);
  });

  testWidgets('web song resolves the recording before starting server download',
      (tester) async {
    offline.isSupported = false;
    await show(tester);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(api.resolutions.single, {
      'url': _spotifyUrl,
      'title': 'Test recording',
      'artist': 'Test artist',
      'album': 'Test album',
      'duration': 201.0,
      'spotifyId': _spotifyId,
    });
    expect(api.batches.single.single['url'], _source);
    expect(api.batches.single.single['spotify_id'], _spotifyId);
    expect(started, ['batch']);
    expect(offline.songs, isEmpty);
  });

  testWidgets('web playlist batch resolves every selected recording',
      (tester) async {
    offline.isSupported = false;
    await show(tester, tracks: [_song(), _song()]);
    await tester.tap(find.byTooltip('Download undownloaded tracks'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Download'));
    await tester.pumpAndSettle();
    expect(api.resolutions, hasLength(2));
    expect(api.batches.single, hasLength(2));
    for (final request in api.batches.single) {
      expect(request['url'], _source);
      expect(request['spotify_id'], _spotifyId);
    }
    expect(offline.playlists, isEmpty);
  });

  testWidgets('unresolved recording never starts a doomed server batch',
      (tester) async {
    offline.isSupported = false;
    api.resolvedSource = null;
    await show(tester);
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(api.batches, isEmpty);
    expect(started, isEmpty);
    expect(
        find.text(
            'No matching recording was found. Choose a source and retry.'),
        findsOneWidget);
  });
}
