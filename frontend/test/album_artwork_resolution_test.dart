import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/services/album_cover_service.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/widgets/album_cover.dart';
import 'package:music_downloader/widgets/horizontal_song_list.dart';

const _base = 'https://music.example.test';
const _video = 'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg';
const _otherVideo = 'https://img.youtube.com/vi/lmnopqrstuv/0.jpg';
const _cover = 'https://i.scdn.co/image/album-art';

class _CoverApi extends Fake implements ApiService {
  final Future<String?> Function(String title) lookup;
  _CoverApi(this.lookup);

  @override
  Future<String?> fetchAlbumCover({
    required String title,
    String artist = '',
    String album = '',
  }) =>
      lookup(title);
}

AlbumCoverService _service(http.Client transport) {
  final client = AuthHttpClient(client: transport, baseUrl: _base);
  return AlbumCoverService.withClient(
    apiService: ApiService(client: client, baseUrl: _base),
    client: client,
  );
}

void main() {
  test('catalog artwork is authoritative and does not trigger a lookup',
      () async {
    final service = _service(MockClient((_) async {
      fail('An existing catalog cover must not be searched again');
    }));
    expect(
        await service.resolveArtwork(
            filename: 'just-pretend.m4a',
            title: 'Just Pretend',
            artist: 'Bad Omens',
            existingUrl: _cover),
        _cover);
  });

  test('known video artwork prefers metadata over a cached embedded image',
      () async {
    final paths = <String>[];
    final service = _service(MockClient((request) async {
      paths.add(request.url.path);
      return request.url.path == '/album-cover'
          ? http.Response(jsonEncode({'artwork_url': _cover}), 200)
          : http.Response('embedded video frame', 200);
    }));
    const fileArtwork = '$_base/downloads/just-pretend.m4a/artwork';
    expect(await service.resolveArtwork(filename: 'just-pretend.m4a'),
        fileArtwork);
    expect(
        await service.resolveArtwork(
            filename: 'just-pretend.m4a',
            title: 'Just Pretend',
            artist: 'Bad Omens',
            existingUrl: _video),
        _cover);
    expect(paths, ['/downloads/just-pretend.m4a/artwork', '/album-cover']);
  });

  test('known video artwork can fall back to authenticated embedded art',
      () async {
    final paths = <String>[];
    final client = AuthHttpClient(
        baseUrl: _base,
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['Authorization'], 'Bearer account');
          return request.url.path == '/album-cover'
              ? http.Response(jsonEncode({'artwork_url': null}), 200)
              : http.Response('embedded artwork', 200);
        }));
    client.configure(
        tokenProvider: () => 'account', onUnauthorized: () async {});
    final service = AlbumCoverService.withClient(
        client: client, apiService: ApiService(client: client, baseUrl: _base));
    expect(
        await service.resolveArtwork(
            filename: 'song.m4a',
            title: 'Song',
            artist: 'Artist',
            existingUrl: _video),
        '$_base/downloads/song.m4a/artwork');
    expect(paths, ['/album-cover', '/downloads/song.m4a/artwork']);
  });

  test('video artwork is replaced by a cover matched to track metadata',
      () async {
    var calls = 0;
    final service = _service(MockClient((request) async {
      calls++;
      expect(request.url.path, '/album-cover');
      expect(request.url.queryParameters, {
        'title': 'Just Pretend',
        'artist': 'Bad Omens',
        'album': 'The Death of Peace of Mind',
      });
      return http.Response(jsonEncode({'artwork_url': _cover}), 200);
    }));
    for (final thumbnail in [_video, _otherVideo]) {
      expect(
          await service.resolveArtwork(
            title: 'Just Pretend',
            artist: 'Bad Omens',
            album: 'The Death of Peace of Mind',
            existingUrl: thumbnail,
          ),
          _cover);
    }
    expect(calls, 1);
  });

  test('shared missing lookup preserves each caller video fallback', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final service = _service(MockClient((_) {
      calls++;
      return gate.future;
    }));
    final first = service.resolveArtwork(
        title: 'Song', artist: 'Artist', existingUrl: _video);
    final second = service.resolveArtwork(
        title: 'Song', artist: 'Artist', existingUrl: _otherVideo);
    gate.complete(http.Response(jsonEncode({'artwork_url': null}), 200));
    expect(await first, _video);
    expect(await second, _otherVideo);
    expect(
        await service.resolveArtwork(
            title: 'Song', artist: 'Artist', existingUrl: _otherVideo),
        _otherVideo);
    expect(calls, 1);
    expect(
        service.get(
            AlbumCoverService.generateKey(title: 'Song', artist: 'Artist')),
        isNull);
  });

  test('a low confidence cover never replaces the video fallback', () async {
    final service = _service(MockClient((_) async => http.Response(
        jsonEncode({
          'artwork_url': 'https://images.example.test/wrong-artist.jpg',
          'low_confidence': true,
          'match_score': 10,
        }),
        200)));
    expect(
        await service.resolveArtwork(
            title: 'Song', artist: 'Artist', existingUrl: _video),
        _video);
  });

  test('a failed lookup without a video has no invented cover', () async {
    final service = _service(MockClient((_) async => http.Response('', 503)));
    expect(
        await service.resolveArtwork(title: 'Song', artist: 'Artist'), isNull);
  });

  test('lookup timeout retains the video and permits a later retry', () async {
    var calls = 0;
    final client = AuthHttpClient(baseUrl: _base);
    final gate = Completer<String?>();
    final service = AlbumCoverService.withClient(
      client: client,
      apiService:
          _CoverApi((_) => ++calls == 1 ? gate.future : Future.value(_cover)),
      requestTimeout: const Duration(milliseconds: 10),
    );
    expect(await service.resolveArtwork(title: 'Song', existingUrl: _video),
        _video);
    expect(await service.resolveArtwork(title: 'Song', existingUrl: _video),
        _cover);
    gate.complete('https://images.example.test/late.jpg');
    await Future<void>.delayed(Duration.zero);
    expect(await service.resolveArtwork(title: 'Song', existingUrl: _video),
        _cover);
  });

  test('late results and fallbacks do not cross an account change', () async {
    var token = 'first-account';
    final gate = Completer<http.Response>();
    final client =
        AuthHttpClient(baseUrl: _base, client: MockClient((_) => gate.future));
    client.configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service = AlbumCoverService.withClient(
        client: client, apiService: ApiService(client: client, baseUrl: _base));
    final pending = service.resolveArtwork(title: 'Song', existingUrl: _video);
    token = 'second-account';
    gate.complete(http.Response(jsonEncode({'artwork_url': _cover}), 200));
    expect(await pending, isNull);
    expect(service.size, 0);
  });

  test('metadata cache distinguishes artist and album fields', () {
    expect(AlbumCoverService.generateKey(title: 'Song', artist: 'Name'),
        isNot(AlbumCoverService.generateKey(title: 'Song', album: 'Name')));
    expect(
        AlbumCoverService.generateKey(title: 'Song|Artist', artist: 'Name'),
        isNot(AlbumCoverService.generateKey(
            title: 'Song', artist: 'Artist|Name')));
  });

  testWidgets('video stays visible while resolving and stale tracks cannot win',
      (tester) async {
    final gates = <String, Completer<String?>>{};
    final service = AlbumCoverService.withClient(
      client: AuthHttpClient(baseUrl: _base),
      apiService:
          _CoverApi((title) => (gates[title] ??= Completer<String?>()).future),
    );
    Future<void> show(String title, String thumbnail) => tester.pumpWidget(
          MaterialApp(
            home: AlbumCover(
              service: service,
              title: title,
              artist: 'Artist',
              artworkUrl: thumbnail,
            ),
          ),
        );
    String imageUrl() {
      final image = tester.widget<Image>(find.byType(Image)).image;
      return ((image is ResizeImage ? image.imageProvider : image)
              as NetworkImage)
          .url;
    }

    await show('First', _video);
    expect(imageUrl(), _video);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await show('Second', _otherVideo);
    expect(imageUrl(), _otherVideo);
    gates['First']!.complete('https://images.example.test/first.jpg');
    await tester.pump();
    expect(imageUrl(), _otherVideo);
    gates['Second']!.complete(_cover);
    await tester.pumpAndSettle();
    expect(imageUrl(), _cover);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Home song cards pass recording metadata to the artwork resolver',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HorizontalSongList(
          title: 'Because you enjoy Bad Omens',
          songs: [
            VideoInfo(
              id: 'catalog-track',
              title: 'Just Pretend',
              uploader: 'Bad Omens',
              album: 'The Death of Peace of Mind',
              duration: 204,
              url: '',
              thumbnail: _cover,
            )
          ],
          onPlay: (_) {},
          onAddToQueue: (_) {},
        ),
      ),
    ));
    final cover = tester.widget<AlbumCover>(find.byType(AlbumCover));
    expect(cover.title, 'Just Pretend');
    expect(cover.artist, 'Bad Omens');
    expect(cover.album, 'The Death of Peace of Mind');
    expect(cover.artworkUrl, _cover);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
