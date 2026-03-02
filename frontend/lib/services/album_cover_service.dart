import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Centralized service for resolving album cover URLs.
/// Handles caching, in-flight request deduplication, file artwork, and iTunes API.
class AlbumCoverService {
  static final AlbumCoverService _instance = AlbumCoverService._internal();
  factory AlbumCoverService() => _instance;
  AlbumCoverService._internal();

  final ApiService _apiService = ApiService();

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
    final future = _doResolve(cacheKey, filename, title, artist, album);
    _pending[cacheKey] = future;

    try {
      final result = await future;
      return result;
    } finally {
      _pending.remove(cacheKey);
    }
  }

  Future<String?> _doResolve(
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
          final response = await http.get(Uri.parse(fileArtworkUrl));
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

      _cache[cacheKey] = artworkUrl ?? '';
      return artworkUrl;
    } catch (e) {
      _cache[cacheKey] = '';
      return null;
    }
  }

  /// Legacy: direct cache get (for callers that only need cache lookup)
  String? get(String key) {
    if (!_cache.containsKey(key)) return null;
    final v = _cache[key]!;
    return v.isEmpty ? null : v;
  }

  /// Legacy: direct cache put
  void put(String key, String? artworkUrl) {
    _cache[key] = artworkUrl ?? '';
  }

  void clear() {
    _cache.clear();
    _pending.clear();
  }

  int get size => _cache.length;
}
