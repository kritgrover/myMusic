import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/queue_service.dart';

void main() {
  const oldSource = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
  const chosenSource = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
  const spotifyId = '0123456789abcdefghijkl';

  test('an existing video consults the remembered match with complete identity',
      () async {
    final client = AuthHttpClient(client: MockClient((request) async {
      expect(request.url.path, '/search/resolve');
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer account-a');
      expect(jsonDecode(request.body), {
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
        'duration': 181.5,
        'spotify_id': spotifyId,
        'url': oldSource,
      });
      return http.Response(
          jsonEncode({'url': chosenSource, 'remembered': true}), 200);
    }));
    client.configure(
        tokenProvider: () => 'account-a', onUnauthorized: () async {});

    expect(
        await ApiService(client: client).resolveToYouTubeUrl(
            oldSource, ' Song ', 'Artist',
            album: 'Album', duration: 181.5, spotifyId: spotifyId),
        chosenSource);
  });

  test('failed or invalid resolution never silently takes a search result',
      () async {
    for (final response in [
      http.Response('{"detail":"Search unavailable"}', 503),
      http.Response(
          '{"url":"https://youtube.com.evil.test/watch?v=bbbbbbbbbbb"}', 200),
      http.Response('{"url":"https://open.spotify.com/track/$spotifyId"}', 200),
    ]) {
      var calls = 0;
      final api =
          ApiService(client: AuthHttpClient(client: MockClient((request) async {
        calls++;
        expect(request.url.path, '/search/resolve');
        return response;
      })));
      expect(
          await api.resolveToYouTubeUrl(oldSource, 'Song', 'Artist'), isNull);
      expect(calls, 1);
    }
  });

  test('saved choices are requested independently after an account switch',
      () async {
    var token = 'account-a';
    final client = AuthHttpClient(client: MockClient((request) async {
      return http.Response(
          jsonEncode({
            'url': request.headers['Authorization'] == 'Bearer account-a'
                ? chosenSource
                : oldSource,
          }),
          200);
    }));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final api = ApiService(client: client);
    expect(await api.resolveToYouTubeUrl(oldSource, 'Song', 'Artist'),
        chosenSource);
    token = 'account-b';
    expect(
        await api.resolveToYouTubeUrl(oldSource, 'Song', 'Artist'), oldSource);
  });

  test('late source responses from an earlier login are discarded', () async {
    final response = Completer<http.Response>();
    var token = 'account-a';
    final client = AuthHttpClient(client: MockClient((_) => response.future));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final api = ApiService(client: client);
    final pending = api.resolveToYouTubeUrl(oldSource, 'Song', 'Artist');
    token = 'account-b';
    response.complete(http.Response(jsonEncode({'url': chosenSource}), 200));
    expect(await pending, isNull);
  });

  test('candidate responses and saving reject a changed login', () async {
    for (final action in ['candidates', 'remember', 'reset']) {
      final response = Completer<http.Response>();
      var token = 'account-a';
      final client = AuthHttpClient(client: MockClient((_) => response.future));
      client.configure(tokenProvider: () => token, onUnauthorized: () async {});
      final api = ApiService(client: client);
      final Future<dynamic> pending = action == 'candidates'
          ? api.sourceCandidates(title: 'Song', artist: 'Artist')
          : action == 'remember'
              ? api.rememberSource(
                  title: 'Song', artist: 'Artist', url: chosenSource)
              : api.resetSource(title: 'Song', artist: 'Artist');
      final expectation =
          expectLater(pending, throwsA(isA<SourceMatchException>()));
      token = 'account-b';
      response.complete(http.Response('{}', 200));
      await expectation;
    }
  });

  test(
      'remember and reset use the same catalog identity and authenticated account',
      () async {
    final requests = <http.Request>[];
    final client = AuthHttpClient(client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }));
    client.configure(
        tokenProvider: () => 'account-a', onUnauthorized: () async {});
    final api = ApiService(client: client);
    await api.rememberSource(
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: 181,
        spotifyId: spotifyId,
        url: 'https://youtu.be/bbbbbbbbbbb?si=tracking');
    await api.resetSource(
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: 181,
        spotifyId: spotifyId);
    expect(requests.map((request) => request.method), ['PUT', 'DELETE']);
    final saved = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(saved.remove('url'), chosenSource);
    expect(jsonDecode(requests.last.body), saved);
    expect(
        requests.every((request) =>
            request.headers['Authorization'] == 'Bearer account-a'),
        isTrue);
  });

  test(
      'recording labels retain explicit live/remix distinctions without guessing studio',
      () {
    expect(VideoInfo.inferRecordingType('Song (Live at Wembley)'), 'live');
    expect(VideoInfo.inferRecordingType('Song - Remix'), 'remix');
    expect(VideoInfo.inferRecordingType('Song Official Audio'), 'unspecified');
    expect(VideoInfo.inferRecordingType('Live Forever'), 'unspecified');
    final candidates = SourceCandidates.fromJson({
      'candidates': [
        {'title': 'Song (Live)', 'url': chosenSource, 'recording_type': 'live'},
        {'title': 'Song', 'url': 'https://example.test/audio'},
      ],
      'selected_url': 'https://youtu.be/bbbbbbbbbbb',
      'remembered': true,
    });
    expect(candidates.candidates, hasLength(1));
    expect(candidates.candidates.single.recordingDescription, 'Live');
    expect(candidates.selectedUrl, chosenSource);
  });

  test('lazy queue identity survives snapshots and streaming URL updates', () {
    final item = QueueItem.fromPlaylistTrackLazy(
      trackId: spotifyId,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      originalUrl: 'https://open.spotify.com/track/$spotifyId',
      duration: 181.5,
    ).copyWithStreamingUrl('http://localhost/stream/example');
    final restored =
        QueueService.itemFromSnapshot(QueueService.itemToSnapshot(item));
    expect(restored!.spotifyId, spotifyId);
    expect(restored.duration, 181.5);
    expect(restored.album, 'Album');
    expect(restored.copyWithThumbnail('https://example.test/art').spotifyId,
        spotifyId);
  });
}
