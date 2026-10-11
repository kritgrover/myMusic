import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/services/auth_http_client.dart';

void main() {
  final client = AuthHttpClient.shared;
  final backend = Uri.parse(AppConfig.apiBaseUrl);

  setUp(() => client.configure(
        tokenProvider: () => 'test-token',
        onUnauthorized: () async {},
      ));
  tearDown(() => client.configure(
        tokenProvider: () => null,
        onUnauthorized: () async {},
      ));

  test('backend artwork receives the current bearer token', () {
    expect(
      client.authHeadersForUrl(
          backend.resolve('/playlist_covers/image.jpg').toString()),
      {'Authorization': 'Bearer test-token'},
    );
  });

  test('external and lookalike artwork hosts receive no token', () {
    expect(client.authHeadersForUrl('https://images.example.com/art.jpg'),
        isEmpty);
    expect(
        client.authHeadersForUrl(
            backend.replace(host: '${backend.host}.example.com').toString()),
        isEmpty);
    expect(
        client.authHeadersForUrl(backend.replace(userInfo: 'user').toString()),
        isEmpty);
  });

  test('different schemes and ports receive no token', () {
    expect(
        client.authHeadersForUrl(
            backend.replace(port: backend.port + 1).toString()),
        isEmpty);
    expect(
        client.authHeadersForUrl(backend
            .replace(scheme: backend.scheme == 'http' ? 'https' : 'http')
            .toString()),
        isEmpty);
    expect(client.authHeadersForUrl('file:///art.jpg'), isEmpty);
    expect(client.authHeadersForUrl('/playlist_covers/image.jpg'), isEmpty);
  });
}
