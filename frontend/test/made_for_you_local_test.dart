import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/screens/made_for_you_screen.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/playlist_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/widgets/playlist_selection_dialog.dart';

class _Api extends Fake implements ApiService {
  int searches = 0;
  @override
  Future<List<VideoInfo>> searchYoutube(String query,
      {int maxResults = 10}) async {
    searches++;
    throw StateError(
        'External search should not be used for an owned download.');
  }

  @override
  Future<String?> resolveToYouTubeUrl(String? url, String title, String? artist,
      {String? album, double? duration, String? spotifyId}) async {
    searches++;
    throw StateError(
        'Source resolution should not be used for an owned download.');
  }
}

class _Queue extends Fake implements QueueService {
  final played = <QueueItem>[];
  final queued = <QueueItem>[];
  @override
  void clearQueue() {}
  @override
  Future<void> addAndPlay(
          QueueItem item, PlayerStateService playerService) async =>
      played.add(item);
  @override
  void addToQueue(QueueItem item) => queued.add(item);
}

class _Player extends Fake implements PlayerStateService {}

class _Playlists extends Fake implements PlaylistService {
  @override
  Future<List<Playlist>> getAllPlaylists() async => [];
}

void main() {
  final song = VideoInfo(
      id: 'owned-1',
      title: 'Owned recording',
      uploader: 'Local artist',
      duration: 92,
      url: '',
      thumbnail: '',
      filename: 'fixture/owned.mp3',
      album: 'Local album');
  Future<void> mount(WidgetTester tester, _Api api, _Queue queue) =>
      tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MadeForYouScreen(
                  songs: [song],
                  playerStateService: _Player(),
                  queueService: queue,
                  apiService: api,
                  playlistService: _Playlists()))));

  testWidgets(
      'owned recommendations play and enter the queue without external search',
      (tester) async {
    final api = _Api();
    final queue = _Queue();
    await mount(tester, api, queue);
    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(queue.played.single.filename, song.filename);
    expect(queue.played.single.album, song.album);
    expect(queue.played.single.originalUrl, isNull);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(queue.queued.single.filename, song.filename);
    expect(api.searches, 0);
  });

  testWidgets(
      'owned recommendations keep filename in playlist dialog and show downloaded state',
      (tester) async {
    final api = _Api();
    final queue = _Queue();
    await mount(tester, api, queue);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Downloaded'), findsOneWidget);
    final downloaded = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Downloaded'));
    expect(downloaded.enabled, isFalse);
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();
    final dialog = tester
        .widget<PlaylistSelectionDialog>(find.byType(PlaylistSelectionDialog));
    expect(dialog.track.filename, song.filename);
    expect(dialog.track.album, song.album);
    expect(dialog.track.duration, 92);
    expect(api.searches, 0);
  });
}
