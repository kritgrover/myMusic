import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/screens/offline_library_screen.dart';
import 'package:music_downloader/screens/playlist_detail_screen.dart';
import 'package:music_downloader/services/offline_download_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/playlist_service.dart';
import 'package:music_downloader/services/queue_service.dart';

class _Offline extends ChangeNotifier implements OfflineDownloadService {
  @override
  bool isSupported = true;
  @override
  bool isInitialized = true;
  @override
  String? lastError;
  @override
  List<OfflineTrack> tracks = [];
  @override
  List<OfflineDownloadJob> jobs = [];
  @override
  int get totalBytes => tracks.fold(0, (total, track) => total + track.bytes);

  final removed = <String>[];
  final cancelled = <String>[];
  final retried = <String>[];
  final downloadedPlaylists = <Playlist>[];
  bool missingFile = false;

  @override
  Future<QueueItem?> localQueueItemFor(QueueItem item) async =>
      missingFile ? null : item;

  @override
  OfflineDownloadJob? jobFor(QueueItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #remove) {
      final id = invocation.positionalArguments.single as String;
      removed.add(id);
      tracks.removeWhere((track) => track.id == id);
      notifyListeners();
      return Future<void>.value();
    }
    if (invocation.memberName == #cancel) {
      cancelled.add(invocation.positionalArguments.single as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #retry) {
      retried.add(invocation.positionalArguments.single as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #downloadPlaylist) {
      downloadedPlaylists
          .add(invocation.positionalArguments.single as Playlist);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Playlists extends PlaylistService {
  @override
  Future<Playlist?> getPlaylist(String id) async => null;
}

class _Player extends ChangeNotifier implements PlayerStateService {
  @override
  String? get currentTrackUrl => null;
  final played = <String>[];

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Queue extends ChangeNotifier implements QueueService {
  List<QueueItem> items = [];
  int? playedIndex;

  @override
  void clearQueue() => items.clear();
  @override
  void addAllToQueue(List<QueueItem> items,
      {bool isPlaylistQueue = false,
      Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    this.items.addAll(items);
  }

  @override
  Future<void> playItem(int index, PlayerStateService playerService,
      {Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    playedIndex = index;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OfflineTrack _track(String id, String title,
        {String? artist, String? album, int? position}) =>
    OfflineTrack(
      id: id,
      filename: '$id.m4a',
      title: title,
      artist: artist,
      album: album,
      bytes: 1024 * 1024,
      downloadedAt: DateTime(2026, 1, 1),
      playlists: position == null ? {} : {'evening': 'Evening mix'},
      playlistPositions: position == null ? {} : {'evening': position},
    );

void main() {
  late _Offline offline;
  late _Player player;
  late _Queue queue;

  setUp(() {
    offline = _Offline();
    player = _Player();
    queue = _Queue();
  });
  tearDown(() {
    offline.dispose();
    player.dispose();
    queue.dispose();
  });

  Future<void> show(WidgetTester tester, {bool withQueue = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OfflineLibraryScreen(
          playerStateService: player,
          queueService: withQueue ? queue : null,
          offlineService: offline,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('device library searches metadata and plays only search results',
      (tester) async {
    offline.tracks = [
      _track('a', 'Moonlight', artist: 'Luna', album: 'After Hours'),
      _track('b', 'Daylight', artist: 'Sol', album: 'Morning'),
    ];
    await show(tester);
    expect(find.text('2 songs saved on this device · 2.0 MB'), findsOneWidget);

    for (final query in ['moonlight', ' LUNA ', 'after hours']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text('Moonlight'), findsOneWidget);
      expect(find.text('Daylight'), findsNothing);
    }
    await tester.tap(find.text('Play results'));
    await tester.pumpAndSettle();
    expect(queue.items.map((item) => item.filename), ['a.m4a']);
    expect(queue.playedIndex, 0);
    expect(queue.items.single.url, isNull);

    await tester.tap(find.byTooltip('Clear offline search'));
    await tester.pump();
    expect(find.text('Daylight'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist filter preserves offline membership and track order',
      (tester) async {
    offline.tracks = [
      _track('second', 'Second song', position: 1),
      _track('unrelated', 'Other song'),
      _track('first', 'First song', position: 0),
    ];
    await show(tester);
    await tester.tap(find.text('Evening mix'));
    await tester.pumpAndSettle();
    expect(find.text('Other song'), findsNothing);
    expect(tester.getTopLeft(find.text('First song')).dy,
        lessThan(tester.getTopLeft(find.text('Second song')).dy));
    await tester.tap(find.byTooltip('Play Second song'));
    await tester.pumpAndSettle();
    expect(
        queue.items.map((item) => item.filename), ['first.m4a', 'second.m4a']);
    expect(queue.playedIndex, 1);
  });

  testWidgets('removing a device copy calls only local removal',
      (tester) async {
    offline.tracks = [_track('a', 'Moonlight')];
    await show(tester);
    await tester.tap(find.byTooltip('Options for Moonlight'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from this device'));
    await tester.pumpAndSettle();
    expect(offline.removed, ['a']);
    expect(find.text('Take your music with you'), findsOneWidget);
    expect(
        find.text(
            'Removed from this device. Your server library is unchanged.'),
        findsOneWidget);
  });

  testWidgets('jobs show progress and support cancel and retry',
      (tester) async {
    offline.jobs = [
      OfflineDownloadJob(
        id: 'active',
        track: QueueItem(id: 'a', title: 'Active song'),
        status: OfflineDownloadStatus.downloading,
        progress: .5,
      ),
      OfflineDownloadJob(
        id: 'failed',
        track: QueueItem(id: 'b', title: 'Failed song'),
        status: OfflineDownloadStatus.failed,
        error: 'Connection interrupted',
      ),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: OfflineLibraryScreen(
      playerStateService: player,
      offlineService: offline,
    ))));
    await tester.pump();
    expect(find.text('Saving on this device · 50%'), findsOneWidget);
    expect(
        find.text(
            'The connection was interrupted. Check your connection and retry.'),
        findsOneWidget);
    await tester.tap(find.byTooltip('Cancel download'));
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(offline.cancelled, ['active']);
    expect(offline.retried, ['failed']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed downloads show a readable reason without provider logs',
      (tester) async {
    const rawError =
        r'ERROR: ffmpeg failed at C:\private\audio.part?token=private-token';
    offline.lastError = rawError;
    offline.jobs = [
      OfflineDownloadJob(
        id: 'failed',
        track: QueueItem(id: 'a', title: 'Failed song'),
        status: OfflineDownloadStatus.failed,
        error: rawError,
      ),
    ];
    await show(tester);
    expect(find.text('The server could not convert the audio. Please retry.'),
        findsWidgets);
    expect(find.textContaining('private'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('missing local file never starts playback', (tester) async {
    offline.tracks = [_track('a', 'Moonlight')];
    offline.missingFile = true;
    await show(tester);
    await tester.tap(find.byTooltip('Play Moonlight'));
    await tester.pumpAndSettle();
    expect(queue.items, isEmpty);
    expect(queue.playedIndex, isNull);
    expect(find.textContaining('A saved file is unavailable'), findsOneWidget);
  });

  testWidgets('single song playback uses canonical file identity',
      (tester) async {
    offline.tracks = [_track('a', 'Moonlight')];
    await show(tester, withQueue: false);
    await tester.tap(find.byTooltip('Play Moonlight'));
    await tester.pumpAndSettle();
    expect(player.played, ['a.m4a']);
  });

  testWidgets('unsupported browsers explain how to save offline music',
      (tester) async {
    offline.isSupported = false;
    await show(tester);
    expect(
        find.text('Offline listening is available in the app'), findsOneWidget);
    expect(find.textContaining('Use the native app'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('initialization error offers retry instead of an endless spinner',
      (tester) async {
    offline.isInitialized = false;
    offline.lastError = 'Device storage is unavailable';
    var retried = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: OfflineLibraryScreen(
      playerStateService: player,
      offlineService: offline,
      onRetryInitialization: () async {
        retried = true;
      },
    ))));
    expect(find.text('Could not open offline library'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('playlist offline action saves the playlist on a compact screen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playlists = _Playlists();
    final playlist = Playlist(
      id: 'evening',
      name: 'Evening mix',
      tracks: [PlaylistTrack(id: 'a', title: 'Moonlight', filename: 'a.m4a')],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlaylistDetailScreen(
      playlist: playlist,
      playlistService: playlists,
      offlineService: offline,
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download for offline'));
    await tester.pumpAndSettle();
    expect(offline.downloadedPlaylists.single.id, 'evening');
    expect(offline.downloadedPlaylists.single.tracks.single.filename, 'a.m4a');
    expect(find.byTooltip('Download playlist for offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout remains usable with long metadata',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    offline.tracks = [
      _track('a', 'A song with a very long descriptive title',
          artist: 'An artist with a very long name',
          album: 'A very long album title')
    ];
    await show(tester);
    expect(tester.takeException(), isNull);
  });
}
