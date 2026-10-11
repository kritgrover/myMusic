import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:music_downloader/config.dart';
import 'package:music_downloader/services/album_cover_service.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';

class _Player extends Fake implements audio.AudioPlayer {
  final List<String> urls = [];
  final List<Duration?> starts = [];
  bool started = false;
  @override
  double get volume => 1;
  @override
  bool get playing => started;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<audio.PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<audio.SequenceState?> get sequenceStateStream => const Stream.empty();
  @override
  audio.SequenceState? get sequenceState => null;
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<Duration?> setAudioSource(audio.AudioSource source,
          {bool preload = true,
          int? initialIndex,
          Duration? initialPosition}) =>
      setUrl(
          ((source as audio.ConcatenatingAudioSource).children.first
                  as audio.UriAudioSource)
              .uri
              .toString(),
          initialPosition: initialPosition);
  @override
  audio.ProcessingState get processingState => audio.ProcessingState.ready;
  @override
  Duration get position => const Duration(seconds: 22);
  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    urls.add(url);
    starts.add(initialPosition);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> play() async {
    started = true;
  }

  @override
  Future<void> pause() async {
    started = false;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  const base = AppConfig.apiBaseUrl;
  const canonical = '$base/downloads/my%20song.m4a';

  test('media capability uses bearer POST and preserves encoded canonical path',
      () async {
    final requests = <http.Request>[];
    final client = AuthHttpClient(client: MockClient((request) async {
      requests.add(request);
      return http.Response(
          jsonEncode({
            'url': '/downloads/my%20song.m4a?media_token=short-lived',
            'expires_at': 123456,
          }),
          200);
    }));
    client.configure(
        tokenProvider: () => 'access-secret', onUnauthorized: () async {});
    final api = ApiService(client: client);
    final result =
        await api.authorizeMediaUrl('$canonical?media_token=expired');
    expect(result, '$canonical?media_token=short-lived');
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(), '$base/media/authorize');
    expect(requests.single.headers['Authorization'], 'Bearer access-secret');
    expect(
        jsonDecode(requests.single.body), {'path': '/downloads/my%20song.m4a'});
    expect(result, isNot(contains('access-secret')));
  });

  test('stream media authorization preserves nested source URL encoding',
      () async {
    final source =
        Uri.encodeComponent('https://www.youtube.com/watch?v=abc123');
    final client = AuthHttpClient(client: MockClient((request) async {
      expect(jsonDecode(request.body)['path'], '/stream/$source');
      return http.Response(
          jsonEncode({'url': '/stream/$source?media_token=valid'}), 200);
    }));
    expect(
        await ApiService(client: client)
            .authorizeMediaUrl('$base/stream/$source'),
        '$base/stream/$source?media_token=valid');
  });

  test('foreign and lookalike URLs never request a media capability', () async {
    final client = AuthHttpClient(client: MockClient((_) async {
      fail('An external URL must not request backend authorization');
    }));
    final api = ApiService(client: client);
    for (final url in [
      'https://external.example/downloads/track.m4a',
      '$base.example/downloads/track.m4a',
      'audio/test',
    ]) {
      expect(await api.authorizeMediaUrl(url), url);
    }
  });

  test(
      'authorization accepts canonicalized folder separators and YouTube aliases',
      () async {
    final cases = {
      '$base/downloads/user%2F1%2Fmy%20song.m4a':
          '/downloads/user/1/my%20song.m4a',
      '$base/stream/${Uri.encodeComponent('https://youtu.be/abcdefghijk?si=tracking')}':
          '/stream/${Uri.encodeComponent('https://www.youtube.com/watch?v=abcdefghijk')}',
    };
    for (final entry in cases.entries) {
      final client = AuthHttpClient(
          client: MockClient((_) async => http.Response(
              jsonEncode({'url': '${entry.value}?media_token=valid'}), 200)));
      expect(await ApiService(client: client).authorizeMediaUrl(entry.key),
          '$base${entry.value}?media_token=valid');
    }
  });

  test('authorizer rejects foreign capabilities and changed media paths',
      () async {
    for (final returned in [
      'https://external.example/downloads/my%20song.m4a?media_token=x',
      '/downloads/other.m4a?media_token=x',
      '/downloads/my%20song.m4a',
    ]) {
      final client = AuthHttpClient(
          client: MockClient(
              (_) async => http.Response(jsonEncode({'url': returned}), 200)));
      await expectLater(ApiService(client: client).authorizeMediaUrl(canonical),
          throwsStateError);
    }
  });

  test('canonical URLs strip expired capabilities and resolve relative media',
      () {
    expect(ApiService.canonicalMediaUrl('$canonical?media_token=expired#x'),
        canonical);
    expect(
        ApiService.canonicalMediaUrl(
            '/downloads/my%20song.m4a?media_token=expired'),
        canonical);
  });

  test('HTTP client does not send automatic bearer token to foreign hosts',
      () async {
    var unauthorized = 0;
    final client = AuthHttpClient(client: MockClient((request) async {
      expect(request.headers['Authorization'], isNull);
      return http.Response('', 401);
    }));
    client.configure(
        tokenProvider: () => 'private',
        onUnauthorized: () async {
          unauthorized++;
        });
    await client.get(Uri.parse('https://images.example/artwork'));
    await client.post(Uri.parse('https://images.example/post'));
    expect(unauthorized, 0);
  });

  test(
      'private artwork cache keys change across sessions without exposing tokens',
      () {
    String? token = 'first-secret';
    final client = AuthHttpClient();
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final first = client.cacheScopedUrl('$base/downloads/art.m4a/artwork');
    expect(client.cacheScopedUrl('$base/downloads/art.m4a/artwork'), first);
    token = 'second-secret';
    final second = client.cacheScopedUrl('$base/downloads/art.m4a/artwork');
    expect(second, isNot(first));
    expect(second, isNot(contains('secret')));
    expect(client.cacheScopedUrl('https://external.example/art.jpg'),
        'https://external.example/art.jpg');
  });

  for (final method in ['GET', 'POST', 'PUT', 'DELETE', 'MULTIPART']) {
    test('delayed $method unauthorized response cannot log out a new account',
        () async {
      String? token = 'account-a';
      var unauthorized = 0;
      final gate = Completer<http.Response>();
      final dispatched = Completer<void>();
      final client = AuthHttpClient(client: MockClient((request) {
        expect(request.headers['Authorization'], 'Bearer account-a');
        dispatched.complete();
        return gate.future;
      }));
      client.configure(
          tokenProvider: () => token,
          onUnauthorized: () async {
            unauthorized++;
          });
      final url = Uri.parse('$base/test-private');
      final Future<http.Response> response;
      switch (method) {
        case 'GET':
          response = client.get(url);
          break;
        case 'POST':
          response = client.post(url);
          break;
        case 'PUT':
          response = client.put(url);
          break;
        case 'DELETE':
          response = client.delete(url);
          break;
        default:
          response = client.sendMultipart(client.multipartRequest('POST', url));
      }
      await dispatched.future;
      token = 'account-b';
      gate.complete(http.Response('', 401));
      expect((await response).statusCode, 401);
      expect(unauthorized, 0);
    });
  }

  test('unauthorized response still clears the session that sent the request',
      () async {
    var unauthorized = 0;
    final client =
        AuthHttpClient(client: MockClient((_) async => http.Response('', 401)));
    client.configure(
        tokenProvider: () => 'current-account',
        onUnauthorized: () async {
          unauthorized++;
        });
    await client.get(Uri.parse('$base/test-private'));
    expect(unauthorized, 1);
  });

  test('artwork probes authenticate and do not reuse another account cache',
      () async {
    String? token = 'first';
    final seen = <String?>[];
    final client = AuthHttpClient(client: MockClient((request) async {
      seen.add(request.headers['Authorization']);
      return http.Response('', token == 'first' ? 200 : 404);
    }));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service = AlbumCoverService.withClient(
        apiService: ApiService(client: client), client: client);
    expect(await service.resolveArtwork(filename: 'same.m4a'),
        '$base/downloads/same.m4a/artwork');
    expect(await service.resolveArtwork(filename: 'same.m4a'), isNotNull);
    token = 'second';
    expect(await service.resolveArtwork(filename: 'same.m4a'), isNull);
    expect(seen, ['Bearer first', 'Bearer second']);
  });

  test('an old account in-flight artwork result cannot populate the new cache',
      () async {
    String? token = 'first';
    final gate = Completer<http.Response>();
    final client = AuthHttpClient(client: MockClient((_) => gate.future));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service = AlbumCoverService.withClient(
        apiService: ApiService(client: client), client: client);
    final old = service.resolveArtwork(filename: 'same.m4a');
    token = 'second';
    gate.complete(http.Response('', 200));
    expect(await old, isNull);
    expect(service.size, 0);
  });

  test('playback refreshes capabilities and exposes only canonical URLs',
      () async {
    final native = _Player();
    var revision = 0;
    final resolved = <String>[];
    final service = AudioPlayerService(
        player: native,
        preloadPlayer: _Player(),
        mediaUrlResolver: (url) async {
          resolved.add(url);
          return '$url?media_token=${++revision}';
        });
    addTearDown(service.dispose);
    await service.playFromUrl('$canonical?media_token=stale');
    await service.playFromUrl(canonical);
    expect(resolved, [canonical, canonical]);
    expect(
        native.urls, ['$canonical?media_token=1', '$canonical?media_token=2']);
    expect(service.currentUrl, canonical);
  });

  test('preload then playback never reuses an expired media capability',
      () async {
    final native = _Player();
    final preload = _Player();
    var revision = 0;
    final service = AudioPlayerService(
        player: native,
        preloadPlayer: preload,
        mediaUrlResolver: (url) async => '$url?media_token=${++revision}');
    addTearDown(service.dispose);
    await service.preloadUrl(canonical);
    await service.preloadUrl(canonical);
    expect(
        preload.urls, ['$canonical?media_token=1', '$canonical?media_token=2']);
    expect(service.preloadedUrl, canonical);
    await service.playFromUrl(canonical);
    expect(native.urls.single, '$canonical?media_token=3');
  });

  test('resume after pause refreshes authorization while preserving position',
      () async {
    final native = _Player();
    var revision = 0;
    final service = AudioPlayerService(
        player: native,
        preloadPlayer: _Player(),
        mediaUrlResolver: (url) async => '$url?media_token=${++revision}');
    addTearDown(service.dispose);
    await service.playFromUrl(canonical);
    await service.pause();
    await service.resume();
    expect(native.urls.last, '$canonical?media_token=2');
    expect(native.starts.last, const Duration(seconds: 22));
    expect(service.currentUrl, canonical);
  });

  test('cancelled authorization cannot subsequently load or start audio',
      () async {
    final native = _Player();
    final gate = Completer<String>();
    final service = AudioPlayerService(
        player: native,
        preloadPlayer: _Player(),
        mediaUrlResolver: (_) => gate.future);
    addTearDown(service.dispose);
    final started = service.playFromUrl(canonical);
    service.cancelPendingPlayback();
    gate.complete('$canonical?media_token=too-late');
    await started;
    expect(native.urls, isEmpty);
    expect(native.started, isFalse);
  });

  test('cleared preload cannot return when authorization resolves later',
      () async {
    final preload = _Player();
    final gate = Completer<String>();
    final service = AudioPlayerService(
        player: _Player(),
        preloadPlayer: preload,
        mediaUrlResolver: (_) => gate.future);
    addTearDown(service.dispose);
    final pending = service.preloadUrl(canonical);
    await service.clearPreload();
    gate.complete('$canonical?media_token=too-late');
    await pending;
    expect(preload.urls, isEmpty);
    expect(service.preloadedUrl, isNull);
  });
}
