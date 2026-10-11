import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/playlist_service.dart';

void main() {
  test('playlist removal encodes complete filename and URL track identities', () async {
    const ids = [
      'fixture/source-track.mp3',
      'https://www.youtube.com/watch?v=testFixture#chapter',
      'percent%2F song?one#two.mp3',
      'café/曲.mp3',
    ];
    final requests = <http.Request>[];
    final client = AuthHttpClient(
      baseUrl: 'http://localhost:8000',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    final service = PlaylistService(client: client, baseUrl: 'http://localhost:8000');
    for (final id in ids) {
      await service.removeTrackFromPlaylist('playlist-id', id);
      final request = requests.last;
      expect(request.method, 'DELETE');
      expect(request.url.query, isEmpty);
      expect(request.url.fragment, isEmpty);
      expect(request.url.pathSegments.last, id);
      expect(request.url.toString(),
          'http://localhost:8000/playlists/playlist-id/songs/${Uri.encodeComponent(id)}');
    }
  });
}
