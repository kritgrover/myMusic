import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/discovery.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/screens/artist_screen.dart';
import 'package:music_downloader/screens/album_detail_screen.dart';
import 'package:music_downloader/screens/spotify_playlist_screen.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/recommendation_service.dart';

class _Player extends Fake implements PlayerStateService {}

class _Catalog extends RecommendationService {
  int albumCalls = 0;
  bool failFirst = false;
  final related = Completer<List<ArtistInfo>>();
  final releases = [
    AlbumInfo(
        id: 'old', name: 'Older album', type: 'album', releaseDate: '2001'),
    AlbumInfo(
        id: 'new', name: 'Newest album', type: 'album', releaseDate: '2025'),
    AlbumInfo(
        id: 'single', name: 'Early EP', type: 'single', releaseDate: '2000-03'),
    AlbumInfo(
        id: 'comp',
        name: 'Collected songs',
        type: 'compilation',
        releaseDate: '2020'),
    AlbumInfo(
        id: 'guest',
        name: 'Guest release',
        type: 'album',
        group: 'appears_on',
        releaseDate: '2024'),
  ];

  @override
  Future<ArtistInfo?> getArtist(String artistId) async =>
      ArtistInfo(id: artistId, name: 'Test Artist');
  @override
  Future<List<PlaylistTrack>> getArtistTopTracks(String artistId) async => [];
  @override
  Future<List<ArtistInfo>> getRelatedArtists(String artistId) => related.future;
  @override
  Future<List<AlbumInfo>> getArtistAlbums(String artistId) async {
    albumCalls++;
    if (failFirst && albumCalls == 1) throw StateError('provider offline');
    return releases;
  }

  @override
  Future<AlbumInfo?> getAlbum(String albumId) async => releases.first;
  @override
  Future<List<PlaylistTrack>> getAlbumTracks(String albumId) async {
    albumCalls++;
    if (failFirst && albumCalls == 1) throw StateError('provider offline');
    return [];
  }
}

void main() {
  for (final width in [320.0, 1100.0]) {
    testWidgets(
        'discography filters and sorting work independently of related artists at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = _Catalog();
      final queue = QueueService();
      addTearDown(queue.dispose);
      await tester.pumpWidget(MaterialApp(
          home: ArtistScreen(
        artistId: 'artist',
        playerStateService: _Player(),
        queueService: queue,
        recommendationService: catalog,
      )));
      await tester.pumpAndSettle();
      expect(catalog.related.isCompleted, isFalse);
      expect(find.text('Discography'), findsOneWidget);
      expect(find.text('5 releases'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Albums'));
      await tester.pumpAndSettle();
      expect(find.text('2 releases'), findsOneWidget);
      expect(find.text('Newest album'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Newest album')).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.text('Older album')).dy));
      await tester.tap(find.text('Newest first'));
      await tester.pumpAndSettle();
      expect(find.text('Oldest first'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Older album')).dx,
          lessThan(tester.getTopLeft(find.text('Newest album')).dx));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Singles & EPs'));
      await tester.pumpAndSettle();
      expect(find.text('Early EP'), findsOneWidget);
      expect(find.text('2000 • Single / EP'), findsOneWidget);
      expect(find.text('Newest album'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Appears on'));
      await tester.pumpAndSettle();
      expect(find.text('Guest release'), findsOneWidget);
      expect(find.text('1 release'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'failed discography has retry and does not become a false empty catalog',
      (tester) async {
    final catalog = _Catalog()..failFirst = true;
    final queue = QueueService();
    addTearDown(queue.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ArtistScreen(
      artistId: 'artist',
      playerStateService: _Player(),
      queueService: queue,
      recommendationService: catalog,
    )));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry discography'));
    await tester.tap(find.text('Retry discography'));
    await tester.pumpAndSettle();
    expect(catalog.albumCalls, 2);
    expect(find.text('5 releases'), findsOneWidget);
    expect(find.text('Retry discography'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album track failure can be retried', (tester) async {
    final catalog = _Catalog()..failFirst = true;
    final queue = QueueService();
    addTearDown(queue.dispose);
    await tester.pumpWidget(MaterialApp(
        home: AlbumDetailScreen(
      albumId: 'album',
      albumName: 'Album',
      playerStateService: _Player(),
      queueService: queue,
      recommendationService: catalog,
    )));
    await tester.pumpAndSettle();
    expect(find.text('No tracks found for this album'), findsNothing);
    await tester.tap(find.text('Retry album'));
    await tester.pumpAndSettle();
    expect(catalog.albumCalls, 2);
    expect(find.text('No tracks found for this album'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  RecommendationService serviceFor(
      Future<http.Response> Function(http.Request) handler,
      {String? Function()? tokenProvider}) {
    final client = AuthHttpClient(
        baseUrl: 'http://localhost:8002', client: MockClient(handler));
    client.configure(
        tokenProvider: tokenProvider ?? () => 'account-a',
        onUnauthorized: () async {});
    return RecommendationService(
        baseUrl: 'http://localhost:8002', client: client);
  }

  test(
      'provider failures and malformed discography are surfaced, while empty results remain valid',
      () async {
    for (final response in [
      http.Response('unavailable', 503),
      http.Response('{}', 200),
      http.Response('[null]', 200)
    ]) {
      final service = serviceFor((_) async => response);
      await expectLater(service.getArtistAlbums('artist'), throwsA(anything));
    }
    final service = serviceFor((_) async => http.Response('[]', 200));
    expect(await service.getArtistAlbums('artist'), isEmpty);
  });

  test(
      'discography preserves release groups, editions, dates and relative artwork',
      () async {
    final service = serviceFor((request) async {
      expect(request.headers['Authorization'], 'Bearer account-a');
      return http.Response(
          jsonEncode([
            {
              'id': 'album-one',
              'name': 'Album',
              'type': 'album',
              'group': 'appears_on',
              'artist_id': 'artist',
              'release_date': '1999-01-02',
              'thumbnail': '/covers/album.jpg'
            },
            {'id': 'album-two', 'name': 'Album', 'type': 'compilation'},
          ]),
          200);
    });
    final albums = await service.getArtistAlbums('artist');
    expect(albums, hasLength(2));
    expect(albums.first.releaseGroup, 'appears_on');
    expect(albums.first.releaseYear, '1999');
    expect(albums.first.artistId, 'artist');
    expect(albums.first.thumbnail, 'http://localhost:8002/covers/album.jpg');
    expect(albums.last.releaseTypeLabel, 'Compilation');
  });

  test('discard old account discography responses', () async {
    var token = 'account-a';
    final pending = Completer<http.Response>();
    final service =
        serviceFor((_) => pending.future, tokenProvider: () => token);
    final request = service.getArtistAlbums('artist');
    final check = expectLater(request, throwsA(isA<StateError>()));
    token = 'account-b';
    pending.complete(http.Response('[]', 200));
    await check;
  });

  test('album tracks HTTP failure is not silently converted to an empty album',
      () async {
    final service = serviceFor((_) async => http.Response('unavailable', 503));
    await expectLater(
        service.getAlbumTracks('album'), throwsA(isA<StateError>()));
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets('catalog playlist failure is explicit and retryable at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final service = serviceFor((_) async {
        calls++;
        return http.Response('private provider diagnostic', 503);
      });
      final queue = QueueService();
      addTearDown(queue.dispose);
      await tester.pumpWidget(MaterialApp(
          home: SpotifyPlaylistScreen(
        playlistId: 'playlist',
        playlistName: 'Catalog playlist',
        playerStateService: _Player(),
        queueService: queue,
        recommendationService: service,
      )));
      await tester.pumpAndSettle();
      expect(find.text('Playlist tracks are unavailable'), findsOneWidget);
      expect(find.text('No tracks in this playlist'), findsNothing);
      expect(find.textContaining('private provider diagnostic'), findsNothing);
      await tester.tap(find.text('Retry playlist'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Playlist tracks are unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
      'valid empty catalog playlist differs from unavailable playlist contents',
      () async {
    final empty = serviceFor((_) async => http.Response('[]', 200));
    expect(await empty.getSpotifyPlaylistTracks('playlist'), isEmpty);
    final invalid = serviceFor((_) async => http.Response('{}', 200));
    await expectLater(invalid.getSpotifyPlaylistTracks('playlist'),
        throwsA(isA<FormatException>()));
  });
}
