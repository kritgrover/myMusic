// Simple in-memory cache for album cover URLs
// Cache is cleared when app closes
class AlbumCoverCache {
  static final AlbumCoverCache _instance = AlbumCoverCache._internal();
  factory AlbumCoverCache() => _instance;
  AlbumCoverCache._internal();

  final Map<String, String?> _cache = {};
  String? get(String key) {
    return _cache[key];
  }

  // Store artwork URL in cache
  void put(String key, String? artworkUrl) {
    _cache[key] = artworkUrl;
  }

  // Check if key exists in cache
  bool containsKey(String key) {
    return _cache.containsKey(key);
  }

  // Generate cache key from track metadata
  static String generateKey({
    String? filename,
    String? title,
    String? artist,
    String? album,
  }) {
    // Priority: filename if available, otherwise title+artist+album
    if (filename != null && filename.isNotEmpty) {
      return 'file:$filename';
    }
    
    // Use title, artist, album for non-downloaded tracks
    final parts = <String>[];
    if (title != null && title.isNotEmpty) parts.add(title);
    if (artist != null && artist.isNotEmpty) parts.add(artist);
    if (album != null && album.isNotEmpty) parts.add(album);
    
    return parts.isEmpty ? 'unknown' : parts.join('|');
  }

  // Clear all cached entries
  void clear() {
    _cache.clear();
  }

  // Get cache size
  int get size => _cache.length;
}

