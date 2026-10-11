import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/screens/downloads_screen.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/saved_music_service.dart';

class _Player extends ChangeNotifier implements PlayerStateService {
  @override
  String? get currentTrackUrl => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends ApiService {
  bool deleted = false;
  @override
  Future<List<DownloadedFile>> listDownloads() async => deleted
      ? []
      : [
          DownloadedFile(
              filename: 'fixture/tone.mp3',
              filePath: '',
              size: 1024,
              title: 'Private Tone',
              artist: 'Fixture Artist')
        ];
  @override
  Future<void> deleteDownload(String filename) async {
    deleted = true;
  }
}

final _track = PlaylistTrack(
    id: 'source-id',
    title: 'Private Tone',
    artist: 'Fixture Artist',
    filename: 'fixture/tone.mp3',
    url: 'https://www.youtube.com/watch?v=other000001',
    thumbnail: '/downloads/fixture/tone.mp3/artwork');
final _row = {..._track.toJson(), 'id': SavedMusicService.trackKey(_track)};
http.Response _library() => http.Response(
    jsonEncode({
      'tracks': [_row],
      'albums': [],
      'artists': []
    }),
    200);

SavedMusicService _saved(Future<http.Response> Function(http.Request) handler) {
  final client = AuthHttpClient(client: MockClient(handler));
  client.configure(tokenProvider: () => 'demo', onUnauthorized: () async {});
  return SavedMusicService(client: client);
}

void main() {
  testWidgets(
      'deleting a download preserves liked streaming when refresh fails',
      (tester) async {
    var reads = 0;
    final library = _saved((_) async =>
        ++reads == 1 ? _library() : http.Response('unavailable', 503));
    final downloads = _Downloads();
    final player = _Player();
    addTearDown(library.dispose);
    addTearDown(player.dispose);
    await library.load();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DownloadsScreen(
                playerStateService: player,
                apiService: downloads,
                savedMusicService: library))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(downloads.deleted, isTrue);
    expect(reads, 2);
    expect(library.isTrackSaved(_track), isTrue);
    expect(library.tracks.single.filename, isEmpty);
    expect(library.tracks.single.url, _track.url);
    expect(library.tracks.single.thumbnail, isEmpty);
    expect(find.textContaining('Failed to delete'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('a refresh started before deletion cannot restore the removed filename',
      () async {
    var reads = 0;
    final oldResponse = Completer<http.Response>();
    final started = Completer<void>();
    final library = _saved((_) {
      if (++reads == 1) return Future.value(_library());
      started.complete();
      return oldResponse.future;
    });
    addTearDown(library.dispose);
    await library.load();
    final refreshing = library.load(force: true);
    await started.future;
    final deleting = library.refreshAfterDownloadDeletion(r'fixture\tone.mp3');
    oldResponse.complete(_library());
    await Future.wait([refreshing, deleting]);
    expect(library.tracks.single.filename, isEmpty);
    expect(library.tracks.single.url, _track.url);
    expect(library.isTrackSaved(_track), isTrue);
  });

  test('an in-flight unlike rollback cannot restore a deleted file source',
      () async {
    final mutation = Completer<http.Response>();
    final started = Completer<void>();
    var reads = 0;
    final library = _saved((request) {
      if (request.method == 'GET') {
        reads++;
        return Future.value(reads == 1
            ? _library()
            : http.Response(
                jsonEncode({
                  'tracks': [
                    {..._row, 'filename': ''}
                  ],
                  'albums': [],
                  'artists': []
                }),
                200));
      }
      started.complete();
      return mutation.future;
    });
    addTearDown(library.dispose);
    await library.load();
    final removing = library.toggleTrack(_track);
    final failure = expectLater(removing, throwsA(isA<SavedMusicException>()));
    await started.future;
    await library.refreshAfterDownloadDeletion('fixture/tone.mp3');
    mutation.complete(http.Response('unavailable', 503));
    await failure;
    expect(library.isTrackSaved(_track), isTrue);
    expect(library.tracks.single.filename, isEmpty);
    expect(library.tracks.single.url, _track.url);
  });
}
