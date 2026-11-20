import 'dart:convert';

import 'api_service.dart';
import 'auth_http_client.dart';

/// Centralized service for resolving album cover URLs.
/// Handles caching, in-flight request deduplication, file artwork, and iTunes API.
class AlbumCoverService {
  static final AlbumCoverService _instance = AlbumCoverService._internal();
  factory AlbumCoverService() => _instance;
  AlbumCoverService._internal()
      : _apiService = ApiService(),
        _followsServer = true,
        _requestTimeout = const Duration(seconds: 12),
        _client = AuthHttpClient.shared;
  AlbumCoverService.withClient(
      {required ApiService apiService,
      required AuthHttpClient client,
      Duration requestTimeout = const Duration(seconds: 12)})
      : _apiService = apiService,
        _followsServer = false,
        _requestTimeout = requestTimeout,
        _client = client;

  ApiService _apiService;
  final bool _followsServer;
  final Duration _requestTimeout;
  final AuthHttpClient _client;
  String? _sessionScope;

  String _ensureSession() {
    final scope = _client.cacheScope;
    if (_sessionScope != scope) {
      clear();
      if (_followsServer) _apiService = ApiService(baseUrl: _client.baseUrl);
      _sessionScope = scope;
    }
    return scope;
  }

  /// In-memory cache: key -> artwork URL (empty string = no artwork found)
  final Map<String, String> _cache = {};
  final Map<String, DateTime> _missingUntil = {};

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
    return jsonEncode([title ?? '', artist ?? '', album ?? '']);
  }

  /// YouTube video frames are useful fallbacks, not verified album covers.
  static bool isVideoThumbnail(String? url) {
    final host = Uri.tryParse(url ?? '')?.host.toLowerCase() ?? '';
    return host == 'ytimg.com' ||
        host.endsWith('.ytimg.com') ||
        host == 'img.youtube.com';
  }

  /// Resolve artwork while retaining a video thumbnail if no matching cover is
  /// available. Only the resolved cover is cached, never a caller's fallback.
  Future<String?> resolveArtwork({
    String? filename,
    String? title,
    String? artist,
    String? album,
    String? existingUrl,
  }) async {
    final session = _ensureSession();
    if (existingUrl != null &&
        existingUrl.isNotEmpty &&
        !isVideoThumbnail(existingUrl)) {
      return existingUrl;
    }
    final fallback = existingUrl?.isNotEmpty == true ? existingUrl : null;

    final preferCatalog = isVideoThumbnail(existingUrl) &&
        filename != null &&
        filename.isNotEmpty;
    final cacheKey = preferCatalog
        ? jsonEncode(['catalog-first', filename, title, artist, album])
        : generateKey(
            filename: filename,
            title: title,
            artist: artist,
            album: album,
          );

    // Check cache
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      if (cached.isNotEmpty && !_missingUntil.containsKey(cacheKey)) {
        return cached;
      }
      if (_missingUntil[cacheKey]?.isAfter(DateTime.now()) ?? false) {
        return cached.isEmpty ? fallback : cached;
      }
      _cache.remove(cacheKey);
      _missingUntil.remove(cacheKey);
    }

    // Check in-flight: reuse existing fetch
    if (_pending.containsKey(cacheKey)) {
      final result = await _pending[cacheKey];
      return _client.cacheScope == session ? result ?? fallback : null;
    }

    // Start new fetch
    final future = _doResolve(
        session, cacheKey, filename, title, artist, album, preferCatalog);
    _pending[cacheKey] = future;

    try {
      final result = await future;
      return _client.cacheScope == session ? result ?? fallback : null;
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
    bool preferCatalog,
  ) async {
    try {
      String? artworkUrl;
      var matchedCatalog = false;

      Future<String?> catalogArtwork() => _apiService
          .fetchAlbumCover(
            title: title!,
            artist: artist ?? '',
            album: album ?? '',
          )
          .timeout(_requestTimeout);

      // A downloaded file may have the same video frame embedded. When that
      // provenance is known, verify the album cover before trying file artwork.
      if (preferCatalog && title != null && title.isNotEmpty) {
        try {
          artworkUrl = await catalogArtwork();
          matchedCatalog = artworkUrl != null;
        } catch (_) {
          // Embedded artwork remains a useful fallback during an outage.
        }
      }
      if (_client.cacheScope != session) return null;

      if (artworkUrl == null && filename != null && filename.isNotEmpty) {
        try {
          final fileArtworkUrl = _apiService.getFileArtworkUrl(filename);
          final response = await _client
              .get(Uri.parse(fileArtworkUrl))
              .timeout(_requestTimeout);
          if (_client.cacheScope != session) return null;
          if (response.statusCode == 200) {
            artworkUrl = fileArtworkUrl;
          }
        } catch (_) {
          // Continue to iTunes
        }
      }
      if (_client.cacheScope != session) return null;

      if (!preferCatalog &&
          artworkUrl == null &&
          title != null &&
          title.isNotEmpty) {
        artworkUrl = await catalogArtwork();
      }

      if (_client.cacheScope != session) return null;
      _cache[cacheKey] = artworkUrl ?? '';
      if (artworkUrl == null || (preferCatalog && !matchedCatalog)) {
        // Do not let a temporary embedded fallback permanently suppress a
        // later successful metadata lookup.
        _missingUntil[cacheKey] =
            DateTime.now().add(const Duration(minutes: 1));
      }
      return artworkUrl;
    } catch (e) {
      // Transient failures should be retried on the next lookup, not cached as
      // proof that this recording has no album cover.
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
    _missingUntil.clear();
    _pending.clear();
  }

  int get size {
    _ensureSession();
    return _cache.length;
  }
}
