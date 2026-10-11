import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/recommendation_service.dart';

void main() {
  const base = 'http://localhost:8002';
  final event = <String, dynamic>{
    'event_id': 'event-123',
    'sequence': 2,
    'song_title': 'Local song',
    'artist': 'Fixture artist',
    'source_url': 'https://www.youtube.com/watch?v=demo0000001',
    'duration_seconds': 120.0,
    'listened_seconds': 34.5,
    'end_reason': 'paused',
  };
  final track = <String, dynamic>{
    'id': 'local:1',
    'title': 'Local song',
    'artist': 'Fixture artist',
    'album': 'Local album',
    'filename': 'fixture/local song.mp3',
    'duration': 123.5,
    'url': '',
    'thumbnail': '/downloads/fixture/local%20song.mp3/artwork',
  };
  RecommendationService serviceFor(
      Future<http.Response> Function(http.Request) handler,
      {String? Function()? tokenProvider}) {
    final client = AuthHttpClient(baseUrl: base, client: MockClient(handler));
    client.configure(
        tokenProvider: tokenProvider ?? () => 'account-a',
        onUnauthorized: () async {});
    return RecommendationService(baseUrl: base, client: client);
  }

  test(
      'listening events send one authenticated JSON request with measured progress',
      () async {
    final requests = <http.Request>[];
    final service = serviceFor((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    await service.recordListeningEvent(event);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(), '$base/history/listening');
    expect(requests.single.headers['Authorization'], 'Bearer account-a');
    expect(
        requests.single.headers['Content-Type'], contains('application/json'));
    expect(jsonDecode(requests.single.body), event);
  });

  for (final status in [400, 401, 429, 500]) {
    test('HTTP $status is not reported as a successful listening write',
        () async {
      var requests = 0;
      final service = serviceFor((_) async {
        requests++;
        return http.Response('private diagnostic body', status);
      });
      await expectLater(
          service.recordListeningEvent(event), throwsA(isA<StateError>()));
      expect(requests, 1);
    });
  }

  test(
      'network failures propagate for the recorder to retry without hidden retries',
      () async {
    var requests = 0;
    final service = serviceFor((_) async {
      requests++;
      throw http.ClientException('offline');
    });
    await expectLater(service.recordListeningEvent(event),
        throwsA(isA<http.ClientException>()));
    expect(requests, 1);
  });

  test(
      'an old account response is rejected and never retried with the next account',
      () async {
    String token = 'account-a';
    final response = Completer<http.Response>();
    final authorizations = <String?>[];
    final service = serviceFor((request) {
      authorizations.add(request.headers['Authorization']);
      return authorizations.length == 1
          ? response.future
          : Future.value(http.Response('{}', 200));
    }, tokenProvider: () => token);
    final firstScope = service.sessionScope;
    final pending = service.recordListeningEvent(event);
    final check = expectLater(pending, throwsA(isA<StateError>()));
    token = 'account-b';
    expect(service.sessionScope, isNot(firstScope));
    expect(service.sessionScope, isNot(contains(token)));
    response.complete(http.Response('{}', 200));
    await check;
    expect(authorizations, ['Bearer account-a']);
    await service
        .recordListeningEvent({...event, 'event_id': 'event-new-account'});
    expect(authorizations, ['Bearer account-a', 'Bearer account-b']);
  });

  test('a stalled listening request times out without a hidden retry',
      () async {
    final response = Completer<http.Response>();
    var calls = 0;
    final client = AuthHttpClient(
        baseUrl: base,
        client: MockClient((_) {
          calls++;
          return response.future;
        }));
    final service = RecommendationService(
        baseUrl: base,
        client: client,
        listeningReportTimeout: const Duration(milliseconds: 10));
    await expectLater(
        service.recordListeningEvent(event), throwsA(isA<TimeoutException>()));
    expect(calls, 1);
    // Completing the uncancelled HTTP request later must not send another report.
    response.complete(http.Response('{}', 200));
    await pumpEventQueue();
    expect(calls, 1);
  });

  test('late unauthorized response after timeout cannot clear a newer account',
      () async {
    final response = Completer<http.Response>();
    String token = 'account-a';
    var unauthorized = 0;
    final authorizations = <String?>[];
    final client = AuthHttpClient(
        baseUrl: base,
        client: MockClient((request) {
          authorizations.add(request.headers['Authorization']);
          return authorizations.length == 1
              ? response.future
              : Future.value(http.Response('{}', 200));
        }));
    client.configure(
        tokenProvider: () => token,
        onUnauthorized: () async {
          unauthorized++;
        });
    final service = RecommendationService(
        baseUrl: base,
        client: client,
        listeningReportTimeout: const Duration(milliseconds: 10));
    await expectLater(
        service.recordListeningEvent(event), throwsA(isA<TimeoutException>()));
    token = 'account-b';
    response.complete(http.Response('{}', 401));
    await pumpEventQueue();
    expect(unauthorized, 0);
    expect(authorizations, ['Bearer account-a']);
    await service
        .recordListeningEvent({...event, 'event_id': 'event-account-b'});
    expect(authorizations, ['Bearer account-a', 'Bearer account-b']);
  });

  final getters =
      <String, Future<List<PlaylistTrack>> Function(RecommendationService)>{
    'daily': (service) => service.getDailyMix(),
    'for you': (service) => service.getForYou(),
    'genre': (service) => service.getGenreTracks('R&B / Soul'),
    'album': (service) => service.getAlbumTracks('album'),
    'artist': (service) => service.getArtistTopTracks('artist'),
    'playlist': (service) => service.getSpotifyPlaylistTracks('playlist'),
  };
  for (final getter in getters.entries) {
    test(
        '${getter.key} preserves local playback, album, duration, and private artwork',
        () async {
      final service =
          serviceFor((_) async => http.Response(jsonEncode([track]), 200));
      final saved = (await getter.value(service)).single;
      expect(saved.filename, track['filename']);
      expect(saved.duration, 123.5);
      expect(saved.album, 'Local album');
      expect(saved.url, '');
      expect(saved.thumbnail, '$base${track['thumbnail']}');
      final video = VideoInfo.fromPlaylistTrack(saved);
      final liked = PlaylistTrack.fromVideoInfo(video);
      expect(video.id, 'local:1');
      expect(video.formattedDuration, '2:03');
      expect(liked.toJson(), saved.toJson());
    });
  }

  test('nested personalized rows preserve owned filenames and real durations',
      () async {
    final service = serviceFor((_) async => http.Response(
        jsonEncode([
          {
            'id': 'mix',
            'title': 'From your library',
            'tracks': [track]
          }
        ]),
        200));
    final mix = (await service.getMixes()).single.tracks.single;
    final because =
        (await service.getBecauseYouListened()).single.tracks.single;
    expect(mix.filename, track['filename']);
    expect(because.toJson(), mix.toJson());
    expect(mix.thumbnail, '$base${track['thumbnail']}');
    expect(mix.duration, 123.5);
  });

  test('late recommendation tracks from the previous account are discarded',
      () async {
    String token = 'account-a';
    final response = Completer<http.Response>();
    final service =
        serviceFor((_) => response.future, tokenProvider: () => token);
    final pending = service.getDailyMix();
    token = 'account-b';
    response.complete(http.Response(jsonEncode([track]), 200));
    expect(await pending, isEmpty);
  });

  test('legacy search VideoInfo remains compatible without a local filename',
      () {
    final video = VideoInfo.fromJson({
      'id': 'youtube-id',
      'title': 'Search song',
      'uploader': 'Artist',
      'url': 'https://www.youtube.com/watch?v=demo0000001',
      'thumbnail': '',
      'duration': 9
    });
    final saved = PlaylistTrack.fromVideoInfo(video);
    expect(video.filename, isNull);
    expect(saved.filename, '');
    expect(saved.duration, 9);
    expect(saved.url, video.url);
  });

  for (final artists in [false, true]) {
    test('${artists ? 'artist' : 'album'} fallback resolves owned artwork',
        () async {
      final service = serviceFor((_) async => http.Response(
          jsonEncode([
            {
              'id': 'saved',
              'name': 'Private saved item',
              'thumbnail': track['thumbnail']
            }
          ]),
          200));
      final thumbnail = artists
          ? (await service.getRecommendedArtists()).single.thumbnail
          : (await service.getNewReleases()).single['thumbnail'];
      expect(thumbnail, '$base${track['thumbnail']}');
    });

    test(
        '${artists ? 'artist' : 'album'} private fallback rejects an old account response',
        () async {
      String token = 'account-a';
      final response = Completer<http.Response>();
      final service =
          serviceFor((_) => response.future, tokenProvider: () => token);
      final pending =
          artists ? service.getRecommendedArtists() : service.getNewReleases();
      token = 'account-b';
      response.complete(http.Response(
          jsonEncode([
            {
              'id': 'saved',
              'name': 'Private saved item',
              'thumbnail': track['thumbnail']
            }
          ]),
          200));
      expect(await pending, isEmpty);
    });
  }
}
