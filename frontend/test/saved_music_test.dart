import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/saved_music_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/screens/saved_music_screen.dart';
import 'package:music_downloader/widgets/save_music_button.dart';
import 'package:music_downloader/widgets/save_track_button.dart';

class _ScreenPlayer extends Fake implements PlayerStateService {}

PlaylistTrack _track(
        {String id = 'youtube-id',
        String title = 'My Song',
        String? artist = 'The Artist',
        String filename = '',
        String? url}) =>
    PlaylistTrack(
        id: id, title: title, artist: artist, filename: filename, url: url);
Map<String, dynamic> _library(
        {List<Map<String, dynamic>> tracks = const [],
        List<Map<String, dynamic>> albums = const [],
        List<Map<String, dynamic>> artists = const []}) =>
    {'tracks': tracks, 'albums': albums, 'artists': artists};
http.Response _json(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code,
        headers: {'Content-Type': 'application/json'});
SavedMusicService _service(
    Future<http.Response> Function(http.Request) handler) {
  final client = AuthHttpClient(client: MockClient(handler));
  client.configure(
      tokenProvider: () => 'account-a', onUnauthorized: () async {});
  return SavedMusicService(client: client);
}

void main() {
  for (final kind in SavedMusicKind.values) {
    testWidgets(
        'saved ${kind.name} screen fits 320px and filters one saved item',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final track =
          _track(title: 'A song title that extends beyond a single row');
      final service = _service((request) async => request.method == 'GET'
          ? _json(_library(
              tracks: [
                {...track.toJson(), 'id': SavedMusicService.trackKey(track)}
              ],
              albums: [
                {
                  'id': 'album',
                  'title': 'An album with a long descriptive title',
                  'artist': 'Artist'
                }
              ],
              artists: [
                {
                  'id': 'artist',
                  'name': 'An artist with a long descriptive name'
                }
              ],
            ))
          : _json({'success': true}));
      final queue = QueueService();
      addTearDown(service.dispose);
      addTearDown(queue.dispose);
      await service.load();
      await tester.pumpWidget(MaterialApp(
          home: SavedMusicScreen(
              kind: kind,
              playerStateService: _ScreenPlayer(),
              queueService: queue,
              service: service)));
      await tester.pumpAndSettle();
      final noun = switch (kind) {
        SavedMusicKind.tracks => 'song',
        SavedMusicKind.albums => 'album',
        SavedMusicKind.artists => 'artist',
      };
      expect(find.text('1 $noun'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(ListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'does not exist');
      await tester.pumpAndSettle();
      expect(find.text('No saved music matches your search'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
    });
  }

  testWidgets(
      'saved screen exposes loading failure and retry returns the empty state',
      (tester) async {
    var fails = true;
    final service =
        _service((_) async => fails ? _json({}, 503) : _json(_library()));
    final queue = QueueService();
    addTearDown(service.dispose);
    addTearDown(queue.dispose);
    await tester.pumpWidget(MaterialApp(
        home: SavedMusicScreen(
            kind: SavedMusicKind.tracks,
            playerStateService: _ScreenPlayer(),
            queueService: queue,
            service: service)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Could not load your library. Please retry.'),
        findsOneWidget);
    fails = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Your favorites belong here'), findsOneWidget);
    expect(find.text('0 songs'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  test(
      'track keys ignore source IDs, case and extra whitespace, but retain version titles',
      () {
    final a =
        _track(id: 'spotify_a', title: '  My   Song ', artist: 'THE ARTIST');
    final b = _track(id: 'file_download', filename: 'own.m4a');
    expect(SavedMusicService.trackKey(a), SavedMusicService.trackKey(b));
    expect(SavedMusicService.trackKey(a),
        isNot(SavedMusicService.trackKey(_track(title: 'My Song (Live)'))));
    expect(
        SavedMusicService.trackKey(_track(
                title: List.filled(300, '音').join(),
                artist: List.filled(300, '乐').join()))
            .length,
        lessThan(512));
  });

  test('loads are deduplicated and cached until explicitly refreshed',
      () async {
    var requests = 0;
    final gate = Completer<http.Response>();
    final service = _service((_) {
      requests++;
      return gate.future;
    });
    addTearDown(service.dispose);
    final one = service.load();
    final two = service.load();
    expect(identical(one, two), isTrue);
    gate.complete(_json(_library()));
    await Future.wait([one, two]);
    await service.load();
    expect(requests, 1);
    expect(service.isLoaded, isTrue);
    expect(service.isLoading, isFalse);
  });

  test(
      'save retains source ID, drops Spotify media URL, and survives a fresh service load',
      () async {
    final track = _track(
        id: 'spotify-original', url: 'https://open.spotify.com/track/example');
    final records = <Map<String, dynamic>>[];
    final payloads = <Map<String, dynamic>>[];
    Future<http.Response> server(http.Request request) async {
      if (request.method == 'GET') return _json(_library(tracks: records));
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      payloads.add(payload);
      records.add(payload);
      return _json(payload);
    }

    final service = _service(server);
    final restored = _service(server);
    addTearDown(service.dispose);
    addTearDown(restored.dispose);
    await service.toggleTrack(track);
    expect(payloads.single['source_id'], 'spotify-original');
    expect(payloads.single['url'], '');
    expect(payloads.single.containsKey('file_path'), isFalse);
    await restored.load();
    expect(restored.isTrackSaved(_track(id: 'different-source')), isTrue);
    expect(restored.tracks.single.id, SavedMusicService.trackKey(track));
  });

  test('private relative artwork resolves to backend origin for every kind',
      () async {
    final track = _track();
    final service = _service((_) async => _json(_library(
          tracks: [
            {
              ...track.toJson(),
              'id': SavedMusicService.trackKey(track),
              'source_id': '',
              'thumbnail': '/downloads/mine.m4a/artwork'
            }
          ],
          albums: [
            {
              'id': 'album',
              'title': 'Album',
              'thumbnail': '/playlists/mine/cover'
            }
          ],
          artists: [
            {
              'id': 'artist',
              'name': 'Artist',
              'thumbnail': 'https://cdn.example/artist.jpg'
            }
          ],
        )));
    addTearDown(service.dispose);
    await service.load();
    expect(service.tracks.single.thumbnail,
        '${AppConfig.apiBaseUrl}/downloads/mine.m4a/artwork');
    expect(service.tracks.single.id, SavedMusicService.trackKey(track));
    expect(service.albums.single.thumbnail,
        '${AppConfig.apiBaseUrl}/playlists/mine/cover');
    expect(service.artists.single.thumbnail, 'https://cdn.example/artist.jpg');
  });

  test('failed save rolls back optimism and reports a retryable error',
      () async {
    final putGate = Completer<http.Response>();
    final started = Completer<void>();
    final track = _track();
    final service = _service((request) async {
      if (request.method == 'GET') return _json(_library());
      started.complete();
      return putGate.future;
    });
    addTearDown(service.dispose);
    final saving = service.toggleTrack(track);
    final failure = expectLater(saving, throwsA(isA<SavedMusicException>()));
    await started.future;
    expect(service.isTrackSaved(track), isTrue);
    expect(
        service.isBusy(
            SavedMusicKind.tracks, SavedMusicService.trackKey(track)),
        isTrue);
    putGate.complete(_json({'detail': 'unavailable'}, 503));
    await failure;
    expect(service.isTrackSaved(track), isFalse);
    expect(
        service.isBusy(
            SavedMusicKind.tracks, SavedMusicService.trackKey(track)),
        isFalse);
    expect(service.error, contains('Please try again'));
  });

  test('failed removal restores the saved item', () async {
    final track = _track();
    final service = _service((request) async => request.method == 'GET'
        ? _json(_library(tracks: [
            {...track.toJson(), 'id': SavedMusicService.trackKey(track)}
          ]))
        : _json({}, 503));
    addTearDown(service.dispose);
    await service.load();
    await expectLater(
        service.toggleTrack(track), throwsA(isA<SavedMusicException>()));
    expect(service.isTrackSaved(track), isTrue);
    expect(service.tracks.length, 1);
  });

  test('duplicate taps while saving issue one mutation only', () async {
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    var puts = 0;
    final track = _track();
    final service = _service((request) async {
      if (request.method == 'GET') return _json(_library());
      puts++;
      started.complete();
      return gate.future;
    });
    addTearDown(service.dispose);
    final saving = service.toggleTrack(track);
    await started.future;
    await service.toggleTrack(track);
    gate.complete(
        _json({...track.toJson(), 'id': SavedMusicService.trackKey(track)}));
    await saving;
    expect(puts, 1);
    expect(service.isTrackSaved(track), isTrue);
  });

  for (final removing in [false, true]) {
    for (final refreshFinishesLast in [false, true]) {
      test(
          'refresh cannot overwrite ${removing ? 'removal' : 'save'} when refresh finishes ${refreshFinishesLast ? 'last' : 'first'}',
          () async {
        final track = _track();
        final row = {
          ...track.toJson(),
          'id': SavedMusicService.trackKey(track)
        };
        final initial = _library(tracks: removing ? [row] : []);
        var reads = 0;
        final mutation = Completer<http.Response>();
        final refresh = Completer<http.Response>();
        final mutationStarted = Completer<void>();
        final refreshStarted = Completer<void>();
        final service = _service((request) async {
          if (request.method == 'GET') {
            if (++reads == 1) return _json(initial);
            refreshStarted.complete();
            return refresh.future;
          }
          mutationStarted.complete();
          return mutation.future;
        });
        addTearDown(service.dispose);
        await service.load();
        final writing = service.toggleTrack(track);
        await mutationStarted.future;
        final reading = service.load(force: true);
        await refreshStarted.future;
        if (refreshFinishesLast) {
          mutation.complete(_json(removing ? {'success': true} : row));
          await writing;
          refresh.complete(_json(initial));
          await reading;
        } else {
          refresh.complete(_json(initial));
          await reading;
          expect(service.isTrackSaved(track), !removing);
          mutation.complete(_json(removing ? {'success': true} : row));
          await writing;
        }
        expect(service.isTrackSaved(track), !removing);
      });
    }
  }

  test(
      'an account change clears cached library and discards old loading results',
      () async {
    var token = 'account-a';
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final client = AuthHttpClient(client: MockClient((request) {
      if (request.headers['Authorization'] == 'Bearer account-a') {
        started.complete();
        return gate.future;
      }
      return Future.value(_json(_library()));
    }));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service = SavedMusicService(client: client);
    addTearDown(service.dispose);
    final loading = service.load();
    await started.future;
    token = 'account-b';
    await service.load();
    gate.complete(_json(_library(tracks: [_track().toJson()])));
    await loading;
    expect(service.tracks, isEmpty);
    expect(service.isLoaded, isTrue);
  });

  test(
      'an old account mutation cannot populate or roll back a new account library',
      () async {
    var token = 'account-a';
    final gate = Completer<http.Response>();
    final started = Completer<void>();
    final track = _track();
    final client = AuthHttpClient(client: MockClient((request) async {
      if (request.method == 'GET') return _json(_library());
      started.complete();
      return gate.future;
    }));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service = SavedMusicService(client: client);
    addTearDown(service.dispose);
    final saving = service.toggleTrack(track);
    await started.future;
    token = 'account-b';
    expect(service.tracks, isEmpty);
    await service.load();
    gate.complete(
        _json({...track.toJson(), 'id': SavedMusicService.trackKey(track)}));
    await saving;
    expect(service.tracks, isEmpty);
    expect(service.error, isNull);
  });

  test(
      'failed initial loading can be retried without retaining a failed future',
      () async {
    var fail = true;
    final service =
        _service((_) async => fail ? _json({}, 503) : _json(_library()));
    addTearDown(service.dispose);
    await expectLater(service.load(), throwsA(isA<SavedMusicException>()));
    expect(service.isLoading, isFalse);
    expect(service.isLoaded, isFalse);
    fail = false;
    await service.load();
    expect(service.error, isNull);
    expect(service.isLoaded, isTrue);
  });

  testWidgets(
      'like buttons synchronize across source IDs and a second tap removes the song',
      (tester) async {
    final service = _service((request) async {
      if (request.method == 'GET') return _json(_library());
      return request.method == 'PUT'
          ? _json(jsonDecode(request.body))
          : _json({'success': true});
    });
    addTearDown(service.dispose);
    await service.load();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Row(children: [
      SaveTrackButton(track: _track(id: 'search'), service: service),
      SaveTrackButton(
          track: _track(id: 'queue'), service: service, compact: true),
    ]))));
    await tester.tap(find.byTooltip('Save to Liked Songs').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from Liked Songs'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Remove from Liked Songs').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save to Liked Songs'), findsNWidgets(2));
  });

  testWidgets('failed save shows error feedback and rolls button back',
      (tester) async {
    final service = _service((request) async =>
        request.method == 'GET' ? _json(_library()) : _json({}, 503));
    addTearDown(service.dispose);
    await service.load();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SaveTrackButton(track: _track(), service: service))));
    await tester.tap(find.byTooltip('Save to Liked Songs'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save this item. Please try again.'),
        findsOneWidget);
    expect(find.byTooltip('Save to Liked Songs'), findsOneWidget);
  });

  testWidgets(
      'album save and artist follow controls update labels and remove independently',
      (tester) async {
    final service = _service((request) async {
      if (request.method == 'GET') return _json(_library());
      return request.method == 'PUT'
          ? _json(jsonDecode(request.body))
          : _json({'success': true});
    });
    addTearDown(service.dispose);
    await service.load();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      SaveAlbumButton(
          album: const SavedAlbum(id: 'album', title: 'Album'),
          service: service),
      FollowArtistButton(
          artist: const SavedArtist(id: 'artist', name: 'Artist'),
          service: service),
    ]))));
    await tester.tap(find.byTooltip('Save album'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Follow artist'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Following'), findsOneWidget);
    await tester.tap(find.byTooltip('Unfollow artist'));
    await tester.pumpAndSettle();
    expect(service.artists, isEmpty);
    expect(service.albums.length, 1);
  });
}
