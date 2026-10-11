import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/media_exceptions.dart';

void main() {
  const base = AppConfig.apiBaseUrl;
  const download = '$base/downloads/fixture/owned.mp3';
  for (final status in [404, 410]) {
    test('missing download HTTP $status has a recoverable safe type', () async {
      final client = AuthHttpClient(
          client: MockClient((_) async => http.Response(
              'secret internal path and media_token=private', status)));
      final api = ApiService(client: client);
      await expectLater(
          api.authorizeMediaUrl('$download?media_token=expired'),
          throwsA(isA<DownloadUnavailableException>().having(
              (error) => error.toString(),
              'safe message',
              'This downloaded file is no longer available.')));
    });

    test('stream HTTP $status does not trigger download recovery', () async {
      final client = AuthHttpClient(
          client: MockClient((_) async => http.Response('', status)));
      await expectLater(
          ApiService(client: client).authorizeMediaUrl(
              '$base/stream/${Uri.encodeComponent('https://youtu.be/abcdefghijk')}'),
          throwsStateError);
    });
  }

  for (final status in [400, 401, 403, 500]) {
    test('download HTTP $status cannot be mistaken for a missing file',
        () async {
      final client = AuthHttpClient(
          client: MockClient((_) async => http.Response('', status)));
      client.configure(
          tokenProvider: () => 'owner', onUnauthorized: () async {});
      await expectLater(ApiService(client: client).authorizeMediaUrl(download),
          throwsStateError);
    });
  }

  test('foreign and nonmedia paths never request missing-download recovery',
      () async {
    final client = AuthHttpClient(client: MockClient((_) async {
      fail('Unrelated paths must not request a capability');
    }));
    for (final value in [
      'https://foreign.example/downloads/owned.mp3',
      '$base/other/owned.mp3'
    ]) {
      expect(await ApiService(client: client).authorizeMediaUrl(value), value);
    }
  });

  test('known YouTube aliases recover one canonical exact track', () {
    const expected = 'https://www.youtube.com/watch?v=abcdefghijk';
    for (final source in [
      'https://youtu.be/abcdefghijk?t=30',
      'http://youtube.com/watch?v=abcdefghijk&list=playlist',
      'https://music.youtube.com/watch?v=abcdefghijk#fragment',
      'https://m.youtube.com/shorts/abcdefghijk',
      'https://www.youtube.com/embed/abcdefghijk',
      'https://www.youtube.com/live/abcdefghijk',
      '$base/stream/${Uri.encodeComponent(expected)}?media_token=short-lived',
    ]) {
      expect(ApiService.canonicalYouTubeSource(source), expected,
          reason: source);
    }
  });

  test('unknown or malformed sources cannot silently select another track', () {
    for (final source in <String?>[
      null,
      '',
      'abcdefghijk',
      '/downloads/owned.mp3',
      'https://foreign.example/watch?v=abcdefghijk',
      'https://youtube.com.evil.test/watch?v=abcdefghijk',
      'https://user:secret@youtube.com/watch?v=abcdefghijk',
      'https://youtube.com:444/watch?v=abcdefghijk',
      'ftp://youtube.com/watch?v=abcdefghijk',
      'https://youtube.com/watch?v=short',
      'https://youtube.com/playlist?list=abcdefghijk',
      'https://youtu.be/abcdefghijk/more',
      'https://youtube.com:%/watch?v=abcdefghijk',
      '$base/stream/${Uri.encodeComponent('https://youtube.com:444/watch?v=abcdefghijk')}',
      'https://foreign.example/stream/${Uri.encodeComponent('https://youtu.be/abcdefghijk')}',
    ]) {
      expect(ApiService.canonicalYouTubeSource(source), isNull, reason: source);
    }
  });
}
