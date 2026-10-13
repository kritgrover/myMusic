import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/offline_download_job.dart';
import '../models/offline_track.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import 'api_service.dart';
import 'auth_http_client.dart';
import 'offline_storage.dart';

export '../models/offline_download_job.dart';
export '../models/offline_track.dart';

typedef OfflineApiFactory = ApiService Function(String baseUrl);
typedef OfflineAuthHeaders = Map<String, String> Function(String url);

/// Device downloads are independent of the server's downloaded-file library.
/// Only committed, checksum-verified files are exposed for local playback.
class OfflineDownloadService extends ChangeNotifier {
  static final OfflineDownloadService shared = OfflineDownloadService();

  final OfflineStorageFactory _storageFactory;
  final http.Client Function() _clientFactory;
  final OfflineApiFactory _apiFactory;
  final OfflineAuthHeaders _authHeaders;
  final bool _supported;
  OfflineStorage? _storage;
  ApiService? _api;
  String _baseUrl = AppConfig.apiBaseUrl;
  String? _scope;
  int _generation = 0;
  int? _pumping;
  bool _initialized = false;
  bool _disposed = false;
  String? _lastError;
  Future<void>? _initializing;
  Future<void> _indexTail = Future.value();
  final Map<String, OfflineTrack> _tracks = {};
  final Map<String, _Work> _work = {};

  OfflineDownloadService({
    OfflineStorageFactory? storageFactory,
    http.Client Function()? clientFactory,
    OfflineApiFactory? apiFactory,
    OfflineAuthHeaders? authHeaders,
    bool? supported,
  })  : _storageFactory = storageFactory ?? createOfflineStorage,
        _clientFactory = clientFactory ?? http.Client.new,
        _apiFactory = apiFactory ?? ((url) => ApiService(baseUrl: url)),
        _authHeaders = authHeaders ?? AuthHttpClient.shared.authHeadersForUrl,
        _supported = supported ?? offlineStorageSupported;

  bool get isSupported => _supported;
  bool get isInitialized => _initialized;
  String? get lastError => _lastError;
  List<OfflineTrack> get tracks => List.unmodifiable(_tracks.values);
  List<OfflineDownloadJob> get jobs =>
      List.unmodifiable(_work.values.map((work) => work.job));

  /// Looks up the requested recording rather than another job with the same
  /// catalog ID (for example, a previously failed source that was corrected).
  OfflineDownloadJob? jobFor(QueueItem item) {
    final id = sha256.convert(utf8.encode(_keys(item).first)).toString();
    return _work[id]?.job;
  }

  int get totalBytes =>
      _tracks.values.fold(0, (sum, track) => sum + track.bytes);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _indexTail.then((_) => operation());
    _indexTail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> initialize({required int userId, String? baseUrl}) async {
    final backend =
        (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    final scope = sha256.convert(utf8.encode('$backend\n$userId')).toString();
    if (_scope == scope && (_initialized || _initializing != null)) {
      return _initializing ?? Future.value();
    }
    reset();
    _baseUrl = backend;
    _scope = scope;
    final generation = _generation;
    if (!isSupported) {
      _lastError = 'Device downloads are available in the native app.';
      _notify();
      return;
    }
    final initialization = _serialized(() async {
      try {
        final storage = await _storageFactory(scope);
        if (!_current(generation)) return;
        await storage.cleanTemporaryFiles();
        if (!_current(generation)) return;
        final entries = await storage.readIndex();
        if (!_current(generation)) return;
        final valid = <String, OfflineTrack>{};
        for (final entry in entries) {
          try {
            var track = OfflineTrack.fromJson(entry);
            if (!await storage.validate(
                track.relativePath, track.bytes, track.checksum)) {
              if (!_current(generation)) return;
              continue;
            }
            if (!_current(generation)) return;
            if (track.artworkPath != null &&
                await storage.exists(track.artworkPath!)) {
              if (!_current(generation)) return;
              track = OfflineTrack.fromJson(entry,
                  localArtworkUrl: storage.fileUrl(track.artworkPath!));
            }
            valid[track.id] = track;
          } on FormatException {
            /* Ignore malformed records. */
          } on TypeError {/* Ignore malformed records. */}
        }
        if (!_current(generation)) return;
        if (valid.length != entries.length) {
          await storage
              .writeIndex(valid.values.map((e) => e.toJson()).toList());
          if (!_current(generation)) return;
        }
        _storage = storage;
        _api = _apiFactory(backend);
        _tracks.addAll(valid);
        _initialized = true;
        _lastError = null;
      } catch (error) {
        if (_current(generation)) {
          _lastError = 'Could not open device downloads: $error';
        }
      } finally {
        if (_current(generation)) {
          _initializing = null;
          _notify();
        }
      }
    });
    _initializing = initialization;
    await initialization;
  }

  /// Invalidates jobs before any asynchronous cleanup can run.
  void reset() {
    _generation++;
    for (final work in _work.values) {
      work.cancel();
    }
    _work.clear();
    _tracks.clear();
    _storage = null;
    _api = null;
    _scope = null;
    _initializing = null;
    _initialized = false;
    _lastError = null;
    _pumping = null;
    _notify();
  }

  String? _filename(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final normalized = value.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized
            .split('/')
            .any((part) => part.isEmpty || part == '..' || part == '.')) {
      return null;
    }
    return normalized;
  }

  Uri? _backendUri(String? value) {
    if (value == null) return null;
    final backend = Uri.parse(_baseUrl);
    final uri = backend.resolve(value);
    return uri.userInfo.isEmpty &&
            uri.scheme == backend.scheme &&
            uri.host == backend.host &&
            uri.port == backend.port
        ? uri
        : null;
  }

  String? _fileFromUrl(String? value) {
    final uri = _backendUri(value);
    if (uri == null ||
        !uri.path.startsWith('/downloads/') ||
        uri.path.endsWith('/artwork')) {
      return null;
    }
    try {
      return _filename(
          Uri.decodeComponent(uri.path.substring('/downloads/'.length)));
    } on FormatException {
      return null;
    }
  }

  String? _source(String? value) {
    if (value == null) return null;
    final direct = ApiService.canonicalYouTubeSource(value);
    if (direct != null) return direct;
    final uri = _backendUri(value);
    if (uri == null || !uri.path.startsWith('/stream/')) return null;
    try {
      return ApiService.canonicalYouTubeSource(
          Uri.decodeComponent(uri.path.substring('/stream/'.length)));
    } on FormatException {
      return null;
    }
  }

  String? _safeUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    final source = _source(value);
    if (source != null) return source;
    final spotify = ApiService.spotifyTrackId(value);
    if (spotify != null) return 'https://open.spotify.com/track/$spotify';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    final resolved = Uri.parse(_baseUrl).resolveUri(uri);
    if (!const ['http', 'https'].contains(resolved.scheme)) return null;
    // Never persist signed capabilities, credentials, or expiring query tokens.
    return resolved
        .replace(query: null, fragment: null)
        .toString()
        .split('?')
        .first
        .split('#')
        .first;
  }

  List<String> _keys(QueueItem item) {
    final filename = _filename(item.filename) ?? _fileFromUrl(item.url);
    if (filename != null) return ['file:$filename'];
    final source = _source(item.originalUrl) ?? _source(item.url);
    if (source != null) return ['source:$source'];
    final spotify =
        ApiService.spotifyTrackId(item.originalUrl, id: item.spotifyId);
    if (spotify != null) return ['spotify:$spotify'];
    return ['id:${item.id}'];
  }

  OfflineTrack? _find(QueueItem item) {
    final keys = _keys(item);
    for (final track in _tracks.values) {
      if (keys.any(track.sourceKeys.contains)) return track;
    }
    return null;
  }

  Future<void> downloadTrack(QueueItem track,
          {String? playlistId, String? playlistName}) =>
      _download(track, playlistId: playlistId, playlistName: playlistName);

  Future<void> _download(
    QueueItem track, {
    String? playlistId,
    String? playlistName,
    int? position,
  }) async {
    if (!_initialized || _storage == null) {
      _lastError = isSupported
          ? 'Device downloads are not ready.'
          : 'Device downloads are available in the native app.';
      _notify();
      return;
    }
    final generation = _generation;
    final names = <String, String>{
      if (playlistId != null) playlistId: playlistName ?? 'Playlist'
    };
    final positions = <String, int>{
      if (playlistId != null && position != null) playlistId: position
    };
    final existing = _find(track);
    if (existing != null) {
      final local = await _localUrl(existing);
      if (!_current(generation)) return;
      if (local != null) {
        await _attachMembership(existing.id, names, positions, generation,
            additionalKeys: _aliases(track),
            sourceUrl: _source(track.originalUrl) ?? _source(track.url),
            sourceSpotifyId: ApiService.spotifyTrackId(track.originalUrl,
                id: track.spotifyId));
        return;
      }
    }
    final id = sha256.convert(utf8.encode(_keys(track).first)).toString();
    final active = _work[id];
    if (active != null && !active.done.isCompleted) {
      active.playlists.addAll(names);
      active.positions.addAll(positions);
      await active.done.future;
      if (_current(generation) && active.resultId != null) {
        await _attachMembership(active.resultId!, names, positions, generation);
      }
      return;
    }
    final work = _Work(id, track, names, positions);
    _work[id] = work;
    _lastError = null;
    _notify();
    unawaited(_pump(generation));
    await work.done.future;
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    final generation = _generation;
    final pending = <Future<void>>[];
    for (var i = 0; i < playlist.tracks.length && _current(generation); i++) {
      final track = playlist.tracks[i];
      pending.add(_download(
          QueueItem(
            id: 'track_${track.id}',
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            filename: track.filename,
            originalUrl: track.url,
            thumbnail: track.thumbnail,
            spotifyId: ApiService.spotifyTrackId(track.url, id: track.id),
          ),
          playlistId: playlist.id,
          playlistName: playlist.name,
          position: i));
    }
    await Future.wait(pending);
  }

  List<String> _aliases(QueueItem track, {String? resolvedSource}) {
    final source =
        resolvedSource ?? _source(track.originalUrl) ?? _source(track.url);
    final spotify =
        ApiService.spotifyTrackId(track.originalUrl, id: track.spotifyId);
    return {
      ..._keys(track).where((key) => !key.startsWith('source:')),
      if (source != null) 'source:$source',
      if (spotify != null) 'spotify:$spotify',
    }.toList(growable: false);
  }

  Future<void> _attachMembership(String id, Map<String, String> names,
          Map<String, int> positions, int generation,
          {Iterable<String> additionalKeys = const [],
          String? sourceUrl,
          String? sourceSpotifyId}) =>
      _serialized(() async {
        if (!_current(generation) || _storage == null) return;
        final old = _tracks[id];
        if (old == null || (names.isEmpty && additionalKeys.isEmpty)) return;
        final updated = old.withPlaylists(names, positions,
            additionalKeys: additionalKeys,
            sourceUrl: sourceUrl,
            sourceSpotifyId: sourceSpotifyId);
        final snapshot = {..._tracks, id: updated};
        await _storage!
            .writeIndex(snapshot.values.map((e) => e.toJson()).toList());
        if (!_current(generation)) return;
        _tracks[id] = updated;
        _notify();
      });

  Future<void> _pump(int generation) async {
    if (_pumping == generation || !_current(generation)) return;
    _pumping = generation;
    try {
      while (_current(generation)) {
        final queued =
            _work.values.where((w) => w.status == OfflineDownloadStatus.queued);
        if (queued.isEmpty) break;
        await _run(queued.first, generation, _storage!, _api!);
      }
    } finally {
      if (_pumping == generation) _pumping = null;
    }
  }

  Future<void> _run(_Work work, int generation, OfflineStorage storage,
      ApiService api) async {
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temp = '${work.id}-$generation-$nonce.part';
    String? artworkTemp;
    bool active() => _current(generation) && !work.cancelled;
    void check() {
      if (!active()) throw const OfflineCancelled();
    }

    void status(OfflineDownloadStatus value) {
      if (active()) {
        work.status = value;
        _notify();
      }
    }

    try {
      status(OfflineDownloadStatus.preparing);
      if (work.track.filename?.isNotEmpty == true &&
          _filename(work.track.filename) == null) {
        throw const FormatException('Invalid backend filename.');
      }
      var filename =
          _filename(work.track.filename) ?? _fileFromUrl(work.track.url);
      var source = _source(work.track.originalUrl) ?? _source(work.track.url);
      if (filename == null) {
        source = await work.wait(api
            .resolveToYouTubeUrl(
              work.track.originalUrl ?? work.track.url,
              work.track.displayTitle,
              work.track.artist,
              album: work.track.album,
              duration: work.track.duration,
              spotifyId: work.track.spotifyId,
            )
            .timeout(const Duration(seconds: 30)));
        check();
        if (source == null) {
          throw StateError('No audio source is available for this track.');
        }
        final result = await work.wait(api
            .downloadAudio(
              url: source,
              title: work.track.displayTitle,
              artist: work.track.artist ?? '',
              album: work.track.album ?? '',
              spotifyId: work.track.spotifyId,
            )
            .timeout(const Duration(minutes: 10)));
        check();
        filename = result.success ? _filename(result.filename) : null;
        if (filename == null) {
          throw StateError('The server did not return a completed audio file.');
        }
      }
      check();
      final existing = _find(QueueItem(id: work.id, filename: filename));
      if (existing != null && await _localUrl(existing) != null) {
        check();
        await _attachMembership(
            existing.id, work.playlists, work.positions, generation,
            additionalKeys: _aliases(work.track, resolvedSource: source),
            sourceUrl: source,
            sourceSpotifyId: ApiService.spotifyTrackId(work.track.originalUrl,
                id: work.track.spotifyId));
        check();
        work.resultId = existing.id;
        status(OfflineDownloadStatus.complete);
        return;
      }
      final client = _clientFactory();
      work.client = client;
      final url = '$_baseUrl/downloads/${Uri.encodeComponent(filename)}';
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = false;
      request.headers.addAll(_authHeaders(url));
      final response = await work
          .wait(client.send(request).timeout(const Duration(seconds: 60)));
      check();
      if (response.statusCode != 200) {
        throw StateError('Audio download failed (${response.statusCode}).');
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.contains('text/') ||
          contentType.contains('json') ||
          contentType.contains('html')) {
        throw StateError('The server did not return an audio file.');
      }
      status(OfflineDownloadStatus.downloading);
      final stored = await storage.writeStream(
        temp,
        _interruptible(
            response.stream.timeout(const Duration(seconds: 60)), work),
        expectedBytes: response.contentLength,
        isCancelled: () => !active(),
        onProgress: (count) {
          if (active()) {
            work.progress =
                response.contentLength != null && response.contentLength! > 0
                    ? (count / response.contentLength!).clamp(0.0, 1.0)
                    : null;
            _notify();
          }
        },
      );
      check();
      final extensionMatch =
          RegExp(r'\.([a-zA-Z0-9]{1,5})$').firstMatch(filename);
      final extension = extensionMatch?.group(1)?.toLowerCase() ?? 'audio';
      final path = '${work.id}-$nonce.$extension';
      final thumbnail = _safeUrl(work.track.thumbnail) ?? '$url/artwork';
      String? artworkPath;
      // Artwork failure never prevents saving the completed audio.
      try {
        final artworkRequest = http.Request('GET', Uri.parse(thumbnail))
          ..followRedirects = false;
        artworkRequest.headers.addAll(_authHeaders(thumbnail));
        final artwork = await work.wait(
            client.send(artworkRequest).timeout(const Duration(seconds: 8)));
        check();
        if (artwork.statusCode == 200 &&
            (artwork.headers['content-type'] ?? '').startsWith('image/') &&
            (artwork.contentLength ?? 0) <= 10 * 1024 * 1024) {
          artworkTemp = '${work.id}-$nonce-art.part';
          var artworkBytes = 0;
          await storage.writeStream(
              artworkTemp,
              _interruptible(
                      artwork.stream.timeout(const Duration(seconds: 8)), work)
                  .map((chunk) {
                artworkBytes += chunk.length;
                if (artworkBytes > 10 * 1024 * 1024) {
                  throw StateError('Artwork is too large.');
                }
                return chunk;
              }),
              expectedBytes: artwork.contentLength,
              isCancelled: () => !active());
          check();
          artworkPath = '${work.id}-$nonce.art';
        } else {
          await artwork.stream.listen((_) {}).cancel();
        }
      } catch (_) {
        check();
      }
      check();
      final spotify = ApiService.spotifyTrackId(work.track.originalUrl,
          id: work.track.spotifyId);
      var track = OfflineTrack(
        id: work.id,
        filename: filename,
        title: work.track.displayTitle,
        artist: work.track.artist,
        album: work.track.album,
        duration: work.track.duration,
        thumbnail: thumbnail,
        originalUrl: source ?? _safeUrl(work.track.originalUrl),
        spotifyId: spotify,
        bytes: stored.bytes,
        downloadedAt: DateTime.now().toUtc(),
        playlists: Map.unmodifiable(work.playlists),
        playlistPositions: Map.unmodifiable(work.positions),
        sourceKeys: {
          ..._keys(work.track).where((key) => !key.startsWith('source:')),
          'file:$filename',
          if (source != null) 'source:$source',
          if (spotify != null) 'spotify:$spotify',
        }.toList(growable: false),
        relativePath: path,
        checksum: stored.checksum,
        artworkPath: artworkPath,
        localArtworkUrl:
            artworkPath == null ? null : storage.fileUrl(artworkPath),
      );
      await _serialized(() async {
        check();
        final previous = _tracks.values.map((e) => e.toJson()).toList();
        await storage.rename(temp, path);
        try {
          check();
          if (artworkPath != null) {
            await storage.rename(artworkTemp!, artworkPath);
            check();
          }
          track = track.withPlaylists(work.playlists, work.positions);
          await storage.writeIndex([...previous, track.toJson()]);
          if (!active()) {
            await storage.writeIndex(previous);
            check();
          }
          _tracks[track.id] = track;
          work.resultId = track.id;
        } catch (_) {
          await storage.delete(path);
          if (artworkPath != null) await storage.delete(artworkPath);
          rethrow;
        }
      });
      check();
      work.progress = 1;
      status(OfflineDownloadStatus.complete);
    } on OfflineCancelled {
      if (_current(generation)) {
        work.status = OfflineDownloadStatus.cancelled;
        _notify();
      }
    } catch (error) {
      if (active()) {
        work.status = OfflineDownloadStatus.failed;
        work.error = error.toString();
        _lastError = work.error;
        _notify();
      }
    } finally {
      work.client?.close();
      work.client = null;
      try {
        await storage.delete(temp);
      } catch (_) {}
      if (artworkTemp != null) {
        try {
          await storage.delete(artworkTemp);
        } catch (_) {}
      }
      if (!work.done.isCompleted) work.done.complete();
    }
  }

  Stream<List<int>> _interruptible(
      Stream<List<int>> stream, _Work work) async* {
    final iterator = StreamIterator(stream);
    try {
      while (await Future.any([
        iterator.moveNext(),
        work.abort.future.then((_) => false),
      ])) {
        if (work.cancelled) throw const OfflineCancelled();
        yield iterator.current;
      }
      if (work.cancelled) throw const OfflineCancelled();
    } finally {
      await iterator.cancel();
    }
  }

  void cancel(String id) {
    final work = _work[id];
    if (work == null || work.status == OfflineDownloadStatus.complete) return;
    work.cancel();
    work.status = OfflineDownloadStatus.cancelled;
    _notify();
  }

  Future<void> retry(String id) async {
    final work = _work[id];
    if (work == null ||
        !const [OfflineDownloadStatus.failed, OfflineDownloadStatus.cancelled]
            .contains(work.status)) {
      return;
    }
    final generation = _generation;
    await _download(work.track);
    if (!_current(generation)) return;
    final current = _work[id];
    if (current != null && current.status == OfflineDownloadStatus.complete) {
      await _attachMembership(
          current.resultId ?? id, work.playlists, work.positions, generation);
    }
  }

  Future<void> remove(String id) async {
    cancel(id);
    final generation = _generation;
    await _serialized(() async {
      if (!_current(generation) || _storage == null) return;
      final track = _tracks[id];
      if (track == null) return;
      final storage = _storage!;
      final remaining = {..._tracks}..remove(id);
      await storage
          .writeIndex(remaining.values.map((e) => e.toJson()).toList());
      if (_current(generation)) {
        _tracks.remove(id);
        _notify();
      }
      await storage.delete(track.relativePath);
      if (track.artworkPath != null) await storage.delete(track.artworkPath!);
    });
  }

  Future<String?> _localUrl(OfflineTrack? track) async {
    if (track == null || !_initialized || _storage == null) return null;
    final generation = _generation;
    final storage = _storage!;
    final valid =
        await storage.validate(track.relativePath, track.bytes, track.checksum);
    if (!_current(generation)) return null;
    if (!valid) {
      await remove(track.id);
      return null;
    }
    return storage.fileUrl(track.relativePath);
  }

  Future<String?> localUrlFor(String canonicalUrl) async {
    if (!_initialized) return null;
    final filename = _fileFromUrl(canonicalUrl);
    final source = _source(canonicalUrl);
    if (filename == null && source == null) return null;
    return _localUrl(
        _find(QueueItem(id: '', filename: filename, originalUrl: source)));
  }

  Future<QueueItem?> localQueueItemFor(QueueItem item) async {
    final generation = _generation;
    final track = _find(item);
    final url = await _localUrl(track);
    if (url == null || track == null || !_current(generation)) return null;
    return QueueItem(
      id: item.id,
      title: item.title ?? track.title,
      artist: item.artist ?? track.artist,
      album: item.album ?? track.album,
      duration: item.duration ?? track.duration,
      filename: track.filename,
      thumbnail: item.thumbnail ?? track.thumbnail,
      originalUrl: track.originalUrl,
      spotifyId: item.spotifyId ?? track.spotifyId,
    );
  }

  @override
  void dispose() {
    reset();
    _disposed = true;
    super.dispose();
  }
}

class _Work {
  final String id;
  final QueueItem track;
  final Map<String, String> playlists;
  final Map<String, int> positions;
  final Completer<void> done = Completer();
  final Completer<void> abort = Completer();
  OfflineDownloadStatus status = OfflineDownloadStatus.queued;
  double? progress;
  String? error;
  String? resultId;
  http.Client? client;
  bool cancelled = false;

  _Work(this.id, this.track, this.playlists, this.positions);
  Future<T> wait<T>(Future<T> future) => Future.any([
        future,
        abort.future.then<T>((_) => throw const OfflineCancelled()),
      ]);
  OfflineDownloadJob get job => OfflineDownloadJob(
      id: id, track: track, status: status, progress: progress, error: error);
  void cancel() {
    cancelled = true;
    client?.close();
    if (!abort.isCompleted) abort.complete();
    if (!done.isCompleted) done.complete();
  }
}
