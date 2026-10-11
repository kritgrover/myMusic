import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/offline_download_service.dart';
import 'package:music_downloader/services/offline_storage.dart';
import 'package:music_downloader/services/offline_storage_native.dart';

const backend = 'https://music.example.test';
const youtube = 'https://www.youtube.com/watch?v=abcdefghijk';
const otherYoutube = 'https://www.youtube.com/watch?v=lmnopqrstuv';
const spotify = '0123456789012345678901';
final audio = List<int>.generate(4096, (i) => i % 256);

class _Api extends ApiService {
  int resolutions = 0;
  int downloads = 0;
  Future<String?>? resolution;
  Future<DownloadResult>? preparation;
  String source = youtube;
  _Api() : super(baseUrl: backend);
  @override
  Future<String?> resolveToYouTubeUrl(String? url, String title, String? artist,
      {String? album, double? duration, String? spotifyId}) async {
    resolutions++;
    if (resolution != null) return await resolution!;
    return source;
  }

  @override
  Future<DownloadResult> downloadAudio({
    required String url,
    required String title,
    String artist = '',
    String album = '',
    String outputFormat = 'm4a',
    bool embedThumbnail = false,
    String? spotifyId,
  }) async {
    downloads++;
    if (preparation != null) return await preparation!;
    return DownloadResult(
        success: true,
        filePath: '/server/song.m4a',
        filename: 'Artist/song.m4a',
        title: title,
        artist: artist,
        album: album);
  }
}

class _PausedIndexStorage implements OfflineStorage {
  final OfflineStorage delegate;
  final Completer<void> writing = Completer();
  final Completer<void> release = Completer();
  bool pause = true;
  _PausedIndexStorage(this.delegate);
  @override
  Future<void> writeIndex(List<Map<String, dynamic>> entries) async {
    if (pause) {
      pause = false;
      writing.complete();
      await release.future;
    }
    await delegate.writeIndex(entries);
  }

  @override
  Future<List<Map<String, dynamic>>> readIndex() => delegate.readIndex();
  @override
  Future<void> cleanTemporaryFiles() => delegate.cleanTemporaryFiles();
  @override
  Future<void> delete(String name) => delegate.delete(name);
  @override
  Future<bool> exists(String name) => delegate.exists(name);
  @override
  String fileUrl(String name) => delegate.fileUrl(name);
  @override
  Future<void> rename(String from, String to) => delegate.rename(from, to);
  @override
  Future<bool> validate(String name, int bytes, String checksum) =>
      delegate.validate(name, bytes, checksum);
  @override
  Future<OfflineStoredFile> writeStream(String name, Stream<List<int>> stream,
          {int? expectedBytes,
          required bool Function() isCancelled,
          void Function(int bytes)? onProgress}) =>
      delegate.writeStream(name, stream,
          expectedBytes: expectedBytes,
          isCancelled: isCancelled,
          onProgress: onProgress);
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'Condition did not become true');
}

void main() {
  late Directory root;
  late _Api api;
  final services = <OfflineDownloadService>[];
  final requested = <http.Request>[];

  OfflineDownloadService service(
      {http.Client Function()? clientFactory,
      OfflineStorageFactory? storageFactory}) {
    final result = OfflineDownloadService(
      supported: true,
      storageFactory: storageFactory ??
          (scope) =>
              NativeOfflineStorage.open(Directory('${root.path}/$scope')),
      apiFactory: (_) => api,
      authHeaders: (url) => Uri.parse(url).host == 'music.example.test'
          ? {'Authorization': 'Bearer private-token'}
          : {},
      clientFactory: clientFactory ??
          () => MockClient((request) async {
                requested.add(request);
                if (request.url.path.endsWith('/artwork')) {
                  return http.Response('', 404);
                }
                return http.Response.bytes(audio, 200, headers: {
                  'content-type': 'audio/mp4',
                  'content-length': '${audio.length}',
                });
              }),
    );
    services.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('music-offline-test-');
    api = _Api();
    requested.clear();
  });
  tearDown(() async {
    for (final entry in services) {
      entry.dispose();
    }
    services.clear();
    // Aborted stream cleanup finishes asynchronously after reset.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await root.delete(recursive: true);
  });

  test('streams an existing backend file with auth and restores it offline',
      () async {
    final first = service();
    await first.initialize(userId: 1, baseUrl: backend);
    await first.downloadTrack(QueueItem(
        id: 'one',
        filename: 'Artist/song.m4a',
        title: 'Studio recording',
        artist: 'Artist',
        originalUrl: youtube));
    expect(api.resolutions, 0);
    expect(api.downloads, 0);
    expect(first.tracks.single.filename, 'Artist/song.m4a');
    expect(first.totalBytes, audio.length);
    expect(first.jobs.single.status, OfflineDownloadStatus.complete);
    expect(requested.first.headers['Authorization'], 'Bearer private-token');
    final url = '$backend/downloads/${Uri.encodeComponent('Artist/song.m4a')}';
    final local = await first.localUrlFor('$url?media_token=expired');
    expect(local, startsWith('file:'));
    expect(await File.fromUri(Uri.parse(local!)).readAsBytes(), audio);
    first.reset();

    final restarted =
        service(clientFactory: () => throw StateError('No network'));
    await restarted.initialize(userId: 1, baseUrl: backend);
    expect(restarted.tracks, hasLength(1));
    expect(await restarted.localUrlFor(url), local);
    expect(
        await restarted
            .localUrlFor('$backend/stream/${Uri.encodeComponent(youtube)}'),
        local);
    final queue = await restarted.localQueueItemFor(
        QueueItem(id: 'lazy', originalUrl: youtube, title: 'Renamed metadata'));
    expect(queue?.filename, 'Artist/song.m4a');
    expect(queue?.url, isNull,
        reason: 'Queue persistence must keep canonical identity');
    expect(
        await restarted.localQueueItemFor(QueueItem(
            id: 'wrong',
            originalUrl: otherYoutube,
            title: 'Studio recording',
            artist: 'Artist')),
        isNull);
    expect(api.resolutions, 0);
  });

  test('resolves missing files once and persists Spotify and playlist identity',
      () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    final now = DateTime.now();
    await offline.downloadPlaylist(Playlist(
      id: 'road',
      name: 'Road trip',
      createdAt: now,
      updatedAt: now,
      tracks: [
        PlaylistTrack(
            id: spotify,
            title: 'Track',
            artist: 'Artist',
            filename: '',
            url: 'https://open.spotify.com/track/$spotify')
      ],
    ));
    expect(api.resolutions, 1);
    expect(api.downloads, 1);
    expect(offline.tracks.single.playlists, {'road': 'Road trip'});
    expect(offline.tracks.single.playlistPositions, {'road': 0});
    final restarted =
        service(clientFactory: () => throw StateError('No network'));
    await restarted.initialize(userId: 1, baseUrl: backend);
    final local = await restarted.localQueueItemFor(QueueItem(
        id: 'spotify', originalUrl: 'https://open.spotify.com/track/$spotify'));
    expect(local?.filename, 'Artist/song.m4a');
    expect(api.resolutions, 1);
    expect(restarted.tracks.single.playlists, {'road': 'Road trip'});
  });

  test(
      'cached backend file gains exact catalog aliases without a second transfer',
      () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    await offline
        .downloadTrack(QueueItem(id: 'file', filename: 'Artist/song.m4a'));
    final before =
        requested.where((r) => !r.url.path.endsWith('/artwork')).length;
    await offline.downloadTrack(
        QueueItem(
            id: 'catalog',
            title: 'Track',
            originalUrl: 'https://open.spotify.com/track/$spotify'),
        playlistId: 'favorites',
        playlistName: 'Favorites');
    expect(offline.tracks, hasLength(1));
    expect(requested.where((r) => !r.url.path.endsWith('/artwork')),
        hasLength(before));
    expect(
        await offline.localQueueItemFor(QueueItem(
            id: 'catalog',
            originalUrl: 'https://open.spotify.com/track/$spotify')),
        isNotNull);
    expect(offline.tracks.single.playlists, {'favorites': 'Favorites'});
    final restored =
        service(clientFactory: () => throw StateError('No network'));
    await restored.initialize(userId: 1, baseUrl: backend);
    expect(
        await restored.localQueueItemFor(QueueItem(
            id: 'catalog',
            originalUrl: 'https://open.spotify.com/track/$spotify')),
        isNotNull);
  });

  test('playlist joining during index commit is durably attached', () async {
    late _PausedIndexStorage paused;
    final offline = service(storageFactory: (scope) async {
      paused = _PausedIndexStorage(
          await NativeOfflineStorage.open(Directory('${root.path}/$scope')));
      return paused;
    });
    await offline.initialize(userId: 1, baseUrl: backend);
    final track = QueueItem(id: 'one', filename: 'song.m4a');
    final first = offline.downloadTrack(track,
        playlistId: 'first', playlistName: 'First');
    await paused.writing.future;
    final second = offline.downloadTrack(track,
        playlistId: 'second', playlistName: 'Second');
    paused.release.complete();
    await Future.wait([first, second]);
    expect(offline.tracks.single.playlists,
        {'first': 'First', 'second': 'Second'});
    final restored = service();
    await restored.initialize(userId: 1, baseUrl: backend);
    expect(restored.tracks.single.playlists,
        {'first': 'First', 'second': 'Second'});
  });

  test('account switch during index commit rolls back unpublished file',
      () async {
    late _PausedIndexStorage paused;
    var firstStorage = true;
    final offline = service(storageFactory: (scope) async {
      final native =
          await NativeOfflineStorage.open(Directory('${root.path}/$scope'));
      if (!firstStorage) return native;
      firstStorage = false;
      paused = _PausedIndexStorage(native);
      return paused;
    });
    await offline.initialize(userId: 1, baseUrl: backend);
    final download =
        offline.downloadTrack(QueueItem(id: 'one', filename: 'song.m4a'));
    await paused.writing.future;
    final switched = offline.initialize(userId: 2, baseUrl: backend);
    expect(offline.tracks, isEmpty);
    paused.release.complete();
    await Future.wait([download, switched]);
    expect(offline.tracks, isEmpty);
    await offline.initialize(userId: 1, baseUrl: backend);
    expect(offline.tracks, isEmpty);
    expect(
        await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('.m4a'))
            .toList(),
        isEmpty);
  });

  test('cancelled server conversion does not block a queued existing file',
      () async {
    final delayed = Completer<DownloadResult>();
    api.preparation = delayed.future;
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    final first =
        offline.downloadTrack(QueueItem(id: 'lazy', originalUrl: youtube));
    await until(() => api.downloads == 1);
    final next =
        offline.downloadTrack(QueueItem(id: 'file', filename: 'ready.m4a'));
    offline.cancel(offline.jobs.first.id);
    await Future.wait([first, next]);
    expect(offline.tracks.single.filename, 'ready.m4a');
    delayed.complete(DownloadResult(
        success: true,
        filePath: '',
        filename: 'late.m4a',
        title: '',
        artist: '',
        album: ''));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(offline.tracks.single.filename, 'ready.m4a');
  });

  test('same title never aliases a different recording', () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    await offline.downloadTrack(QueueItem(
        id: 'one',
        filename: 'studio.m4a',
        title: 'Song',
        artist: 'Artist',
        originalUrl: youtube));
    expect(
        await offline.localQueueItemFor(QueueItem(
            id: 'two',
            filename: 'live.m4a',
            title: 'Song',
            artist: 'Artist',
            originalUrl: youtube)),
        isNull);
    expect(
        await offline.localQueueItemFor(QueueItem(
            id: 'three',
            title: 'Song',
            artist: 'Artist',
            originalUrl: otherYoutube)),
        isNull);
  });

  test('job lookup isolates a corrected recording from an earlier failure',
      () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    final original =
        QueueItem(id: 'same-track', originalUrl: youtube, spotifyId: spotify);
    final corrected = QueueItem(
        id: 'same-track', originalUrl: otherYoutube, spotifyId: spotify);
    api.preparation = Future.value(DownloadResult(
        success: false,
        filePath: '',
        filename: '',
        title: '',
        artist: '',
        album: ''));
    await offline.downloadTrack(original);
    expect(offline.jobFor(original)?.status, OfflineDownloadStatus.failed);
    expect(offline.jobFor(corrected), isNull);

    api.preparation = null;
    api.source = otherYoutube;
    await offline.downloadTrack(corrected);
    expect(offline.jobFor(corrected)?.status, OfflineDownloadStatus.complete);
    expect(offline.jobFor(original)?.status, OfflineDownloadStatus.failed);
    expect(offline.tracks.single.originalUrl, otherYoutube);
  });

  test('rejects truncated transfer and retries without listing the partial',
      () async {
    var broken = true;
    final offline = service(
        clientFactory: () => MockClient.streaming((request, _) async {
              if (request.url.path.endsWith('/artwork')) {
                return http.StreamedResponse(Stream.value([]), 404);
              }
              return http.StreamedResponse(
                  Stream.value(broken ? [1, 2] : audio), 200,
                  contentLength: audio.length,
                  headers: {'content-type': 'audio/mp4'});
            }));
    await offline.initialize(userId: 1, baseUrl: backend);
    await offline.downloadTrack(QueueItem(id: 'one', filename: 'song.m4a'));
    expect(offline.tracks, isEmpty);
    expect(offline.jobs.single.status, OfflineDownloadStatus.failed);
    expect(
        await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('.part'))
            .toList(),
        isEmpty);
    broken = false;
    await offline.retry(offline.jobs.single.id);
    expect(offline.tracks, hasLength(1));
    expect(offline.totalBytes, audio.length);
  });

  test('cancels an interrupted transfer and advances the waiting job',
      () async {
    final blocked = StreamController<List<int>>();
    var first = true;
    final offline = service(
        clientFactory: () => MockClient.streaming((request, _) async {
              if (request.url.path.endsWith('/artwork')) {
                return http.StreamedResponse(Stream.value([]), 404);
              }
              final stream = first ? blocked.stream : Stream.value(audio);
              first = false;
              return http.StreamedResponse(stream, 200,
                  contentLength: audio.length);
            }));
    await offline.initialize(userId: 1, baseUrl: backend);
    final pending =
        offline.downloadTrack(QueueItem(id: 'one', filename: 'one.m4a'));
    await until(
        () => offline.jobs.first.status == OfflineDownloadStatus.downloading);
    blocked.add([1, 2]);
    final next =
        offline.downloadTrack(QueueItem(id: 'two', filename: 'two.m4a'));
    offline.cancel(offline.jobs.first.id);
    await pending;
    await next;
    await blocked.close();
    expect(offline.tracks.single.filename, 'two.m4a');
    expect(offline.jobs.first.status, OfflineDownloadStatus.cancelled);
    expect(
        await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('.part'))
            .toList(),
        isEmpty);
  });

  test('account switch invalidates in-flight preparation synchronously',
      () async {
    final delayed = Completer<String?>();
    api.resolution = delayed.future;
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    final pending =
        offline.downloadTrack(QueueItem(id: 'lazy', originalUrl: youtube));
    await until(() => api.resolutions == 1);
    offline.reset();
    expect(offline.tracks, isEmpty);
    expect(offline.jobs, isEmpty);
    await offline.initialize(userId: 2, baseUrl: backend);
    await offline.downloadTrack(QueueItem(id: 'two', filename: 'two.m4a'));
    delayed.complete(youtube);
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.downloads, 0);
    expect(offline.tracks.single.filename, 'two.m4a');
    await offline.initialize(userId: 1, baseUrl: backend);
    expect(offline.tracks, isEmpty);
    await offline.initialize(userId: 2, baseUrl: backend);
    expect(offline.tracks.single.filename, 'two.m4a');
    await offline.initialize(userId: 2, baseUrl: 'https://other.example.test');
    expect(offline.tracks, isEmpty);
  });

  test('cancelled preparation does not block the next queued download',
      () async {
    final delayed = Completer<String?>();
    api.resolution = delayed.future;
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    final pending =
        offline.downloadTrack(QueueItem(id: 'lazy', originalUrl: youtube));
    await until(() => api.resolutions == 1);
    final next =
        offline.downloadTrack(QueueItem(id: 'two', filename: 'two.m4a'));
    offline.cancel(offline.jobs.first.id);
    await pending;
    await next;
    expect(offline.tracks.single.filename, 'two.m4a');
    delayed.complete(youtube);
    expect(api.downloads, 0);
  });

  test('deleted, corrupt and truncated files are never playable after restart',
      () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    for (final filename in ['deleted.m4a', 'corrupt.m4a', 'truncated.m4a']) {
      await offline.downloadTrack(QueueItem(id: filename, filename: filename));
    }
    final deleted = await offline.localUrlFor('$backend/downloads/deleted.m4a');
    final corrupt = await offline.localUrlFor('$backend/downloads/corrupt.m4a');
    final truncated =
        await offline.localUrlFor('$backend/downloads/truncated.m4a');
    await File.fromUri(Uri.parse(deleted!)).delete();
    await File.fromUri(Uri.parse(corrupt!))
        .writeAsBytes(List.filled(audio.length, 0), flush: true);
    await File.fromUri(Uri.parse(truncated!)).writeAsBytes([0], flush: true);
    expect(await offline.localUrlFor('$backend/downloads/deleted.m4a'), isNull);
    expect(await offline.localUrlFor('$backend/downloads/corrupt.m4a'), isNull);
    expect(
        await offline.localUrlFor('$backend/downloads/truncated.m4a'), isNull);
    final restarted = service();
    await restarted.initialize(userId: 1, baseUrl: backend);
    expect(restarted.tracks, isEmpty);
  });

  test('persists safe names and metadata without media capabilities', () async {
    final offline = service();
    await offline.initialize(userId: 1, baseUrl: backend);
    await offline.downloadTrack(QueueItem(
      id: 'one',
      filename: 'Artist/song.m4a',
      thumbnail:
          '$backend/downloads/Artist%2Fsong.m4a/artwork?media_token=secret',
      originalUrl:
          '$backend/stream/${Uri.encodeComponent(youtube)}?media_token=secret',
    ));
    final index = (await root
            .list(recursive: true)
            .where((e) => e.path.endsWith('index.json'))
            .toList())
        .single;
    final contents = await File(index.path).readAsString();
    expect(contents, isNot(contains('secret')));
    expect(contents, isNot(contains('private-token')));
    expect(contents, isNot(contains('media_token')));
    final row = (jsonDecode(contents)['tracks'] as List).single;
    expect(row['relativePath'], matches(RegExp(r'^[a-z0-9.-]+$')));
    await offline.remove(offline.tracks.single.id);
    expect(offline.totalBytes, 0);
    final restarted = service();
    await restarted.initialize(userId: 1, baseUrl: backend);
    expect(restarted.tracks, isEmpty);
  });

  test('web unsupported state does not initialize or make network calls',
      () async {
    final offline = OfflineDownloadService(
        supported: false,
        storageFactory: (_) => throw StateError('No storage on web'));
    services.add(offline);
    await offline.initialize(userId: 1);
    expect(offline.isSupported, isFalse);
    expect(offline.isInitialized, isFalse);
    await offline.downloadTrack(QueueItem(id: 'one', filename: 'song.m4a'));
    expect(offline.lastError, contains('native app'));
    expect(offline.tracks, isEmpty);
  });
}
