import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/discovery_service.dart';
import 'package:music_downloader/widgets/discovery_actions.dart';

Map<String, dynamic> _prefs(
        {String mode = 'balanced', bool autoplay = false}) =>
    {
      'mode': mode,
      'autoplay': autoplay,
      'onboarding_completed': false,
      'seed_artists': [],
    };
http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late String token;
  late DiscoveryService service;
  DiscoveryService create(
      Future<http.Response> Function(http.Request) handler) {
    final client = AuthHttpClient(
        client: MockClient(handler), baseUrl: 'https://music.test');
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    return service = DiscoveryService(client: client);
  }

  setUp(() => token = 'first-account');
  tearDown(() => service.dispose());

  test('loads account preferences with autoplay off and persisted hidden songs',
      () async {
    create((request) async {
      expect(request.headers['authorization'], 'Bearer first-account');
      if (request.url.path.endsWith('feedback')) {
        return _json({
          'feedback': [
            {
              'feedback_id': 'f1',
              'track': {'title': 'One', 'artist': 'Artist'}
            }
          ]
        });
      }
      return _json(_prefs());
    });
    expect(service.preferences.autoplay, isFalse);
    await service.load();
    await _settle();
    expect(service.isLoaded, isTrue);
    expect(service.preferences.mode, 'balanced');
    expect(service.isHidden(QueueItem(id: 'x', title: 'One', artist: 'Artist')),
        isTrue);
  });

  test('serializes partial writes without losing a queued setting', () async {
    final first = Completer<http.Response>();
    final bodies = <Map<String, dynamic>>[];
    final state = _prefs();
    create((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      state.addAll(body);
      if (bodies.length == 1) return first.future;
      return _json(state);
    });
    final mode = service.save(mode: 'discover');
    final autoplay = service.save(autoplay: true);
    await _settle();
    expect(bodies, [
      {'mode': 'discover'}
    ]);
    expect(service.preferences.mode, 'balanced');
    expect(service.isSaving, isTrue);
    first.complete(_json(Map.of(state)));
    await Future.wait([mode, autoplay]);
    expect(bodies.last, {'autoplay': true});
    expect(service.preferences.mode, 'discover');
    expect(service.preferences.autoplay, isTrue);
    expect(service.isSaving, isFalse);
  });

  test('failed writes retain confirmed preference and allow retry', () async {
    var calls = 0;
    create((request) async {
      calls++;
      if (calls == 1) return _json({'detail': 'secret provider error'}, 500);
      return _json(_prefs(mode: 'familiar'));
    });
    await expectLater(
        service.save(mode: 'familiar'), throwsA(isA<DiscoveryException>()));
    expect(service.preferences.mode, 'balanced');
    expect(service.error, isNot(contains('secret')));
    expect(service.isSaving, isFalse);
    await service.save(mode: 'familiar');
    expect(service.preferences.mode, 'familiar');
    expect(service.error, isNull);
  });

  test('slow preferences read cannot overwrite a newer successful write',
      () async {
    final read = Completer<http.Response>();
    create((request) async => request.method == 'GET'
        ? await read.future
        : _json(_prefs(mode: 'discover')));
    final loading = service.load();
    await _settle();
    await service.save(mode: 'discover');
    read.complete(_json(_prefs(mode: 'familiar')));
    await loading;
    expect(service.preferences.mode, 'discover');
  });

  test('account switch discards old reads and does not send queued old writes',
      () async {
    final first = Completer<http.Response>();
    var requests = 0;
    create((request) async {
      requests++;
      return first.future;
    });
    final write = service.save(mode: 'discover');
    final queued = service.save(autoplay: true);
    final errors = Future.wait([
      expectLater(write, throwsA(isA<DiscoveryException>())),
      expectLater(queued, throwsA(isA<DiscoveryException>())),
    ]);
    await _settle();
    token = 'second-account';
    first.complete(_json(_prefs(mode: 'discover')));
    await errors;
    expect(requests, 1);
    expect(service.preferences.mode, 'balanced');
    expect(service.preferences.autoplay, isFalse);
    expect(service.isLoaded, isFalse);
    expect(service.error, isNull);
  });

  test('late account read cannot load settings into another account', () async {
    final pending = Completer<http.Response>();
    create((request) => pending.future);
    final loading = service.load();
    await _settle();
    token = 'second-account';
    pending.complete(_json(_prefs(autoplay: true)));
    await loading;
    expect(service.isLoaded, isFalse);
    expect(service.preferences.autoplay, isFalse);
  });

  test('artist API encodes query and validates selection and search limits',
      () async {
    var requests = 0;
    create((request) async {
      requests++;
      expect(request.url.queryParameters['q'], 'AC/DC & friends');
      return _json({
        'artists': [
          {'id': 'a', 'name': 'AC/DC'}
        ]
      });
    });
    final artists = await service.searchArtists(' AC/DC & friends ');
    expect(artists.single.name, 'AC/DC');
    expect(await service.searchArtists(' '), isEmpty);
    await expectLater(
        service.searchArtists('a' * 101), throwsA(isA<DiscoveryException>()));
    expect(() => service.save(seedArtists: List.filled(6, artists.single)),
        throwsArgumentError);
    expect(() => service.save(seedArtists: [artists.single, artists.single]),
        throwsArgumentError);
    expect(requests, 1);
  });

  test(
      'radio sanitizes inputs, bounds requests and parses safe playback source',
      () async {
    final seed = QueueItem(
        id: r'C:\private\song.mp3',
        title: 'Song',
        artist: 'Artist',
        filename: r'C:\private\song.mp3',
        url: 'https://music.test/private?token=secret',
        originalUrl: 'https://www.youtube.com/watch?v=abcdefghijk&token=secret',
        thumbnail: 'https://music.test/art?token=secret');
    create((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final track = body['seed'] as Map<String, dynamic>;
      expect(track.containsKey('filename'), isFalse);
      expect(track.containsKey('id'), isFalse);
      expect(track['url'], 'https://www.youtube.com/watch?v=abcdefghijk');
      expect(request.body, isNot(contains('secret')));
      expect((body['exclude'] as List).length, 100);
      expect(body['limit'], 30);
      return _json({
        'tracks': [
          {
            'id': 'r1',
            'title': 'Related',
            'artist': 'Artist',
            'url': 'https://www.youtube.com/watch?v=abcdefghijl',
            'filename': 'owned/related.mp3',
            'thumbnail': '/artwork/related.jpg',
            'duration': 120,
          }
        ],
        'message': 'Picked for this song.'
      });
    });
    final result =
        await service.radio(seed, exclude: List.filled(120, seed), limit: 100);
    expect(result.tracks.single.filename, 'owned/related.mp3');
    expect(result.tracks.single.originalUrl,
        'https://www.youtube.com/watch?v=abcdefghijl');
    expect(result.tracks.single.thumbnail,
        'https://music.test/artwork/related.jpg');
    expect(result.tracks.single.duration, 120);
    expect(result.message, 'Picked for this song.');
  });

  test('late feedback refresh cannot erase new feedback or resurrect undo',
      () async {
    final reads = <Completer<http.Response>>[];
    create((request) async {
      if (request.method == 'GET') {
        final completer = Completer<http.Response>();
        reads.add(completer);
        return completer.future;
      }
      if (request.method == 'POST') return _json({'feedback_id': 'f1'});
      return http.Response('', 204);
    });
    final track = QueueItem(id: '1', title: 'Song', artist: 'Artist');
    final firstRead = service.getFeedback();
    await _settle();
    await service.lessLikeThis(track);
    reads[0].complete(_json({'feedback': []}));
    await firstRead;
    expect(service.isHidden(track), isTrue);
    final secondRead = service.getFeedback();
    await _settle();
    await service.undoFeedback('f1');
    reads[1].complete(_json({
      'feedback': [
        {
          'feedback_id': 'f1',
          'track': {'title': 'Song', 'artist': 'Artist'}
        }
      ]
    }));
    await secondRead;
    expect(service.isHidden(track), isFalse);
  });

  test('local recommendation catalog identity survives every card conversion',
      () async {
    const spotifyId = '1234567890123456789012';
    final payload = {
      'id': 'local-song',
      'title': 'Song',
      'artist': 'Artist',
      'uploader': 'Artist',
      'filename': 'owned/song.mp3',
      'url': 'https://www.youtube.com/watch?v=abcdefghijk',
      'spotify_id': spotifyId,
    };
    final playlist = PlaylistTrack.fromJson(payload);
    final video = VideoInfo.fromPlaylistTrack(playlist);
    final card = PlaylistTrack.fromVideoInfo(video);
    final restored = PlaylistTrack.fromJson(card.toJson());
    expect(VideoInfo.fromJson(payload).spotifyId, spotifyId);
    expect(restored.spotifyId, spotifyId);
    expect(PlaylistTrack(id: 'x', title: 'Song', filename: '').toJson(),
        isNot(contains('spotify_id')));
    final item = discoveryTrack(restored);
    create((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final track = body['track'] ?? body['seed'];
      expect(track['spotify_id'], spotifyId);
      expect(track['url'], 'https://www.youtube.com/watch?v=abcdefghijk');
      return request.url.path.endsWith('radio')
          ? _json({
              'tracks': [
                {'title': 'Metadata song', 'artist': 'Artist'}
              ]
            })
          : _json({'feedback_id': 'f1'});
    });
    await service.lessLikeThis(item);
    final result = await service.radio(item);
    // Empty source signals the queue's metadata resolver; null skips it.
    expect(result.tracks.single.originalUrl, '');
    expect(
        service.isHidden(QueueItem(
            id: 'other',
            title: 'Different credit',
            artist: 'Alternate artist',
            spotifyId: spotifyId)),
        isTrue);
  });

  test('radio has a separate positive timeout for its longer provider work',
      () async {
    create((request) async => _json({'tracks': []}));
    expect(service.radioRequestTimeout, const Duration(seconds: 35));
    expect(() => DiscoveryService(radioRequestTimeout: Duration.zero),
        throwsArgumentError);
    service.dispose();
    final client = AuthHttpClient(
        baseUrl: 'https://music.test',
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _json({'tracks': []});
        }));
    service = DiscoveryService(
        client: client,
        requestTimeout: const Duration(milliseconds: 1),
        radioRequestTimeout: const Duration(seconds: 1));
    expect((await service.radio(QueueItem(id: '1', title: 'Song'))).tracks,
        isEmpty);
  });

  test(
      'feedback preserves different recording variants and clears on account switch',
      () async {
    create((request) async => _json({'feedback_id': 'f1'}));
    final original = QueueItem(id: '1', title: 'Song', artist: 'Artist');
    await service.lessLikeThis(original);
    expect(
        service.isHidden(QueueItem(id: '2', title: ' Song ', artist: 'ARTIST')),
        isTrue);
    expect(
        service.isHidden(
            QueueItem(id: '3', title: 'Song (Live)', artist: 'Artist')),
        isFalse);
    token = 'second-account';
    expect(service.isHidden(original), isFalse);
  });
}
