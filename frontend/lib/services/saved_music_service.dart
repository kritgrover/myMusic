import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../config.dart';
import '../models/playlist.dart';
import 'auth_http_client.dart';
import 'api_service.dart';

enum SavedMusicKind { tracks, albums, artists }

class SavedAlbum {
  final String id;
  final String title;
  final String? artist;
  final String? thumbnail;
  const SavedAlbum(
      {required this.id, required this.title, this.artist, this.thumbnail});
  factory SavedAlbum.fromJson(Map<String, dynamic> json) => SavedAlbum(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      thumbnail: json['thumbnail'] as String?);
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist ?? '',
        'thumbnail': thumbnail ?? ''
      };
}

class SavedArtist {
  final String id;
  final String name;
  final String? thumbnail;
  const SavedArtist({required this.id, required this.name, this.thumbnail});
  factory SavedArtist.fromJson(Map<String, dynamic> json) => SavedArtist(
      id: json['id'] as String,
      name: json['name'] as String,
      thumbnail: json['thumbnail'] as String?);
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'thumbnail': thumbnail ?? ''};
}

class SavedMusicException implements Exception {
  final String message;
  const SavedMusicException(this.message);
  @override
  String toString() => message;
}

/// Shared library state. A saved track has the same identity across a search
/// result, a playlist row, a download, and the current playback queue.
class SavedMusicService extends ChangeNotifier {
  static final SavedMusicService shared = SavedMusicService();
  final AuthHttpClient _client;
  final String baseUrl;
  final Map<SavedMusicKind, Map<String, Map<String, dynamic>>> _items = {
    for (final kind in SavedMusicKind.values) kind: {},
  };
  final Set<String> _busy = {};
  final Set<String> _deletedDownloads = {};
  String? _session;
  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;
  String? _error;
  int _revision = 0;

  SavedMusicService({AuthHttpClient? client, String? baseUrl})
      : _client = client ?? AuthHttpClient.shared,
        baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  String _ensureSession() {
    final session = _client.cacheScope;
    if (_session != session) {
      for (final values in _items.values) {
        values.clear();
      }
      _busy.clear();
      _deletedDownloads.clear();
      _loading = null;
      _loaded = false;
      _error = null;
      _revision++;
      _session = session;
    }
    return session;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get isLoading {
    _ensureSession();
    return _loading != null;
  }

  bool get isLoaded {
    _ensureSession();
    return _loaded;
  }

  String? get error {
    _ensureSession();
    return _error;
  }

  static String _normalize(String? value) =>
      (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  static String trackKey(PlaylistTrack track) =>
      'track_${sha256.convert(utf8.encode(jsonEncode([
            _normalize(track.title),
            _normalize(track.artist)
          ])))}';

  Map<String, dynamic> _displayMetadata(Map<String, dynamic> item) {
    final result = Map<String, dynamic>.from(item);
    var thumbnail = result['thumbnail'] as String?;
    final filename = (result['filename'] as String?)?.replaceAll('\\', '/');
    if (filename != null && _deletedDownloads.contains(filename)) {
      result['filename'] = '';
      final artwork = Uri.tryParse(thumbnail ?? '');
      if (artwork != null &&
          Uri.decodeComponent(artwork.path) == '/downloads/$filename/artwork') {
        result['thumbnail'] = thumbnail = '';
      }
    }
    if (thumbnail != null &&
        thumbnail.startsWith('/') &&
        !thumbnail.startsWith('//')) {
      result['thumbnail'] = Uri.parse(baseUrl).resolve(thumbnail).toString();
    }
    return result;
  }

  List<PlaylistTrack> get tracks {
    _ensureSession();
    return List.unmodifiable(_items[SavedMusicKind.tracks]!
        .values
        .map((item) => PlaylistTrack.fromJson(_displayMetadata(item))));
  }

  List<SavedAlbum> get albums {
    _ensureSession();
    return List.unmodifiable(_items[SavedMusicKind.albums]!
        .values
        .map((item) => SavedAlbum.fromJson(_displayMetadata(item))));
  }

  List<SavedArtist> get artists {
    _ensureSession();
    return List.unmodifiable(_items[SavedMusicKind.artists]!
        .values
        .map((item) => SavedArtist.fromJson(_displayMetadata(item))));
  }

  bool isSaved(SavedMusicKind kind, String id) {
    _ensureSession();
    return _items[kind]!.containsKey(id);
  }

  bool isTrackSaved(PlaylistTrack track) =>
      isSaved(SavedMusicKind.tracks, trackKey(track));
  bool isBusy(SavedMusicKind kind, String id) {
    _ensureSession();
    return _busy.contains('${kind.name}:$id');
  }

  /// Removing a download keeps its liked-song entry playable through its
  /// source URL (or metadata search), including when the refresh is offline.
  Future<void> refreshAfterDownloadDeletion(String filename) async {
    _ensureSession();
    final removed = filename.replaceAll('\\', '/');
    _deletedDownloads.add(removed);
    final tracks = _items[SavedMusicKind.tracks]!;
    for (final entry in tracks.entries.toList()) {
      if ((entry.value['filename'] as String?)?.replaceAll('\\', '/') !=
          removed) {
        continue;
      }
      final updated = {...entry.value, 'filename': ''};
      final thumbnail = Uri.tryParse(updated['thumbnail'] as String? ?? '');
      if (thumbnail != null &&
          Uri.decodeComponent(thumbnail.path) ==
              '/downloads/$removed/artwork') {
        updated['thumbnail'] = '';
      }
      tracks[entry.key] = updated;
    }
    // A refresh already in flight may still contain the removed file.
    _revision++;
    _notify();
    try {
      await load(force: true);
    } catch (_) {
      // The delete succeeded. Keep the local correction and allow the normal
      // library retry panel to report a separate refresh failure.
    }
  }

  Future<void> load({bool force = false}) {
    final session = _ensureSession();
    if (_loading != null) return _loading!;
    if (_loaded && !force) return Future.value();
    final revision = _revision;
    final hadPendingMutations = _busy.isNotEmpty;
    _error = null;
    // Defer the request so _loading is assigned even with a synchronous mock.
    final future = Future<void>.microtask(() async {
      try {
        final response = await _client.get(Uri.parse('$baseUrl/library'));
        if (_disposed || session != _client.cacheScope) return;
        if (response.statusCode != 200) {
          throw const SavedMusicException(
              'Could not load your library. Please retry.');
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (!hadPendingMutations && _busy.isEmpty && revision == _revision) {
          final nextItems =
              <SavedMusicKind, Map<String, Map<String, dynamic>>>{};
          for (final kind in SavedMusicKind.values) {
            final values =
                (data[kind.name] as List).cast<Map<String, dynamic>>();
            nextItems[kind] = Map.fromEntries(
                values.map((item) => MapEntry(item['id'] as String, item)));
          }
          for (final kind in SavedMusicKind.values) {
            _items[kind]!
              ..clear()
              ..addAll(nextItems[kind]!);
          }
          // A later authoritative refresh may include a fresh download of the
          // same file. Pre-deletion responses cannot reach this branch.
          _deletedDownloads.removeWhere((filename) =>
              nextItems[SavedMusicKind.tracks]!.values.any((item) =>
                  (item['filename'] as String?)?.replaceAll('\\', '/') ==
                  filename));
        }
        _loaded = true;
      } catch (error) {
        if (!_disposed && session == _client.cacheScope) {
          _error = error is SavedMusicException
              ? error.message
              : 'Could not load your library. Please retry.';
          throw SavedMusicException(_error!);
        }
      } finally {
        if (!_disposed && session == _client.cacheScope) {
          _loading = null;
          _notify();
        }
      }
    });
    _loading = future;
    _notify();
    return future;
  }

  static String _trackSource(PlaylistTrack track) {
    final uri = Uri.tryParse(track.url ?? '');
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        !const ['http', 'https'].contains(uri.scheme) ||
        !const [
          'youtube.com',
          'www.youtube.com',
          'm.youtube.com',
          'music.youtube.com',
          'youtu.be'
        ].contains(uri.host)) {
      return '';
    }
    return uri.toString();
  }

  Future<void> toggleTrack(PlaylistTrack track) =>
      _toggle(SavedMusicKind.tracks, trackKey(track), {
        'id': trackKey(track),
        'source_id': ApiService.canonicalMediaUrl(track.id),
        'title': track.title.trim(),
        'artist': track.artist?.trim() ?? '',
        'album': track.album ?? '',
        'filename': track.filename,
        'url': _trackSource(track),
        'thumbnail': track.thumbnail ?? '',
        'duration': track.duration ?? 0,
      });
  Future<void> toggleAlbum(SavedAlbum album) =>
      _toggle(SavedMusicKind.albums, album.id, album.toJson());
  Future<void> toggleArtist(SavedArtist artist) =>
      _toggle(SavedMusicKind.artists, artist.id, artist.toJson());

  Future<void> _toggle(
      SavedMusicKind kind, String id, Map<String, dynamic> value) async {
    final session = _ensureSession();
    final busyKey = '${kind.name}:$id';
    if (_busy.contains(busyKey)) return;
    await load();
    if (_disposed || session != _client.cacheScope) return;
    // A second tap may have awaited the same initial load.
    if (!_busy.add(busyKey)) return;
    final items = _items[kind]!;
    final old = items[id];
    _revision++;
    _error = null;
    if (old == null) {
      final previous = Map<String, Map<String, dynamic>>.from(items);
      items.clear();
      items[id] = value;
      items.addAll(previous);
    } else {
      items.remove(id);
    }
    _notify();
    try {
      final uri =
          Uri.parse('$baseUrl/library/${kind.name}/${Uri.encodeComponent(id)}');
      final response = old == null
          ? await _client.put(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(value))
          : await _client.delete(uri);
      if (_disposed || session != _client.cacheScope) return;
      if (response.statusCode != 200) {
        throw SavedMusicException(old == null
            ? 'Could not save this item. Please try again.'
            : 'Could not remove this item. Please try again.');
      }
      if (old == null) {
        items[id] = jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (error) {
      if (!_disposed && session == _client.cacheScope) {
        if (old == null) {
          items.remove(id);
        } else {
          items[id] = old;
        }
        _error = error is SavedMusicException
            ? error.message
            : 'Could not update your library. Please try again.';
        throw SavedMusicException(_error!);
      }
    } finally {
      if (!_disposed && session == _client.cacheScope) {
        _revision++;
        _busy.remove(busyKey);
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
