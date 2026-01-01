class QueueItem {
  final String id;
  final String? title;
  final String? artist;
  final String? album;
  final String? url; // For streaming URLs
  final String? filename; // For local files
  final String? thumbnail;
  final String? originalUrl; // Original YouTube/Spotify URL for lazy loading streaming URL

  QueueItem({
    required this.id,
    this.title,
    this.artist,
    this.album,
    this.url,
    this.filename,
    this.thumbnail,
    this.originalUrl,
  });

  // Create from VideoInfo (search results)
  factory QueueItem.fromVideoInfo({
    required String videoId,
    required String? title,
    required String? artist,
    required String streamingUrl,
    String? thumbnail,
    String? album,
  }) {
    return QueueItem(
      id: 'video_$videoId',
      title: title,
      artist: artist,
      album: album,
      url: streamingUrl,
      thumbnail: thumbnail,
    );
  }

  // Create from DownloadedFile
  factory QueueItem.fromDownloadedFile({
    required String filename,
    String? title,
    String? artist,
    String? album,
  }) {
    return QueueItem(
      id: 'file_$filename',
      title: title,
      artist: artist,
      album: album,
      filename: filename,
    );
  }

  // Create from playlist track
  factory QueueItem.fromPlaylistTrack({
    required String trackId,
    required String? title,
    required String? artist,
    required String streamingUrl,
    String? album,
    String? originalUrl,
  }) {
    return QueueItem(
      id: 'track_$trackId',
      title: title,
      artist: artist,
      album: album,
      url: streamingUrl,
      originalUrl: originalUrl,
    );
  }

  // Create from playlist track with original URL (for lazy loading)
  factory QueueItem.fromPlaylistTrackLazy({
    required String trackId,
    required String? title,
    required String? artist,
    required String originalUrl,
    String? album,
    String? thumbnail,
  }) {
    return QueueItem(
      id: 'track_$trackId',
      title: title,
      artist: artist,
      album: album,
      originalUrl: originalUrl,
      thumbnail: thumbnail,
    );
  }

  // Create a copy with updated streaming URL
  QueueItem copyWithStreamingUrl(String streamingUrl) {
    return QueueItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      url: streamingUrl,
      filename: filename,
      thumbnail: thumbnail,
      originalUrl: originalUrl,
    );
  }

  // Create a copy with updated thumbnail
  QueueItem copyWithThumbnail(String? thumbnail) {
    return QueueItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      url: url,
      filename: filename,
      thumbnail: thumbnail,
      originalUrl: originalUrl,
    );
  }

  String get displayTitle => title ?? filename ?? 'Unknown Track';
  String? get displayArtist => artist;
}

