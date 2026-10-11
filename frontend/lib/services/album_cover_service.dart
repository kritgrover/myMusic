import 'api_service.dart';
import 'auth_http_client.dart';

/// Centralized service for resolving album cover URLs.
/// Handles caching, in-flight request deduplication, file artwork, and iTunes API.
class AlbumCoverService {
  static final AlbumCoverService _instance = AlbumCoverService._internal();
  factory AlbumCoverService() => _instance;
  AlbumCoverService._internal()
      : _apiService = ApiService(),
        _client = AuthHttpClient.shared;
  AlbumCoverService.withClient(
      {required ApiService apiService, required AuthHttpClient client})
      : _apiService = apiService,
        _client = client;

  final ApiService _apiService;
  final AuthHttpClient _client;
  String? _sessionScope;

  String _ensureSession() {
    final scope = _client.cacheScope;
    if (_sessionScope != scope) {
      clear();
      _sessionScope = scope;
    }
    return scope;
  }

  /// In-memory cache: key -> artwork URL (empty string = no artwork found)
  final Map<String, String> _cache = {};

  /// In-flight fetches: key -> Future that will resolve to artwork URL
  final Map<String, Future<String?>> _pending = {};

  /// Generate cache key from track metadata
  static String generateKey({
    String? filename,
    String? title,
    String? artist,
    String? album,
  }) {
    if (filename != null && filename.isNotEmpty) {
      return 'file:$filename';
    }
    final parts = <String>[];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (artist != null && artist.isNotEmpty) parts.add(artist);
    if (album != null && album.isNotEmpty) parts.add(album);
    return parts.isEmpty ? 'unknown' : parts.join('|');
  }

  /// Resolve artwork URL. Checks: existing URL -> cache -> in-flight -> file artwork -> iTunes API.
  Future<String?> resolveArtwork({
    String? filename,
    String? title,
    String? artist,
    String? album,
    String? existingUrl,
  }) async {
    final session = _ensureSession();
    if (existingUrl != null && existingUrl.isNotEmpty) {
      return existingUrl;
    }

    final cacheKey = generateKey(
      filename: filename,
      title: title,
      artist: artist,
      album: album,
    );

    // Check cache
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      return cached.isEmpty ? null : cached;
    }

    // Check in-flight: reuse existing fetch
    if (_pending.containsKey(cacheKey)) {
      return _pending[cacheKey];
    }

    // Start new fetch
    final future =
        _doResolve(session, cacheKey, filename, title, artist, album);
    _pending[cacheKey] = future;

    try {
      final result = await future;
      return result;
    } finally {
      if (_client.cacheScope == session) _pending.remove(cacheKey);
    }
  }

  Future<String?> _doResolve(
    String session,
    String cacheKey,
    String? filename,
    String? title,
    String? artist,
    String? album,
  ) async {
    try {
      String? artworkUrl;

      // Priority 1: File artwork
      if (filename != null && filename.isNotEmpty) {
        try {
          final fileArtworkUrl = _apiService.getFileArtworkUrl(filename);
          final response = await _client.get(Uri.parse(fileArtworkUrl));
          if (_client.cacheScope != session) return null;
          if (response.statusCode == 200) {
            artworkUrl = fileArtworkUrl;
          }
        } catch (_) {
          // Continue to iTunes
        }
      }

      // Priority 2: iTunes API
      if (artworkUrl == null && title != null && title.isNotEmpty) {
        artworkUrl = await _apiService.fetchAlbumCover(
          title: title,
          artist: artist ?? '',
          album: album ?? '',
        );
      }

      if (_client.cacheScope != session) return null;
      _cache[cacheKey] = artworkUrl ?? '';
      return artworkUrl;
    } catch (e) {
      if (_client.cacheScope == session) _cache[cacheKey] = '';
      return null;
    }
  }

  /// Legacy: direct cache get (for callers that only need cache lookup)
  String? get(String key) {
    _ensureSession();
    if (!_cache.containsKey(key)) return null;
    final v = _cache[key]!;
    return v.isEmpty ? null : v;
  }

  /// Legacy: direct cache put
  void put(String key, String? artworkUrl) {
    _ensureSession();
    _cache[key] = artworkUrl ?? '';
  }

  void clear() {
    _cache.clear();
    _pending.clear();
  }

  int get size {
    _ensureSession();
    return _cache.length;
  }
}
