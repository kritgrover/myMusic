class QueueItem {
  final String id;
  final String? title;
  final String? artist;
  final String? url; // For streaming URLs
  final String? filename; // For local files
  final String? thumbnail;

  QueueItem({
    required this.id,
    this.title,
    this.artist,
    this.url,
    this.filename,
    this.thumbnail,
  });

  // Create from VideoInfo (search results)
  factory QueueItem.fromVideoInfo({
    required String videoId,
    required String? title,
    required String? artist,
    required String streamingUrl,
    String? thumbnail,
  }) {
    return QueueItem(
      id: 'video_$videoId',
      title: title,
      artist: artist,
      url: streamingUrl,
      thumbnail: thumbnail,
    );
  }

  // Create from DownloadedFile
  factory QueueItem.fromDownloadedFile({
    required String filename,
    String? title,
    String? artist,
  }) {
    return QueueItem(
      id: 'file_$filename',
      title: title,
      artist: artist,
      filename: filename,
    );
  }

  // Create from playlist track
  factory QueueItem.fromPlaylistTrack({
    required String trackId,
    required String? title,
    required String? artist,
    required String streamingUrl,
  }) {
    return QueueItem(
      id: 'track_$trackId',
      title: title,
      artist: artist,
      url: streamingUrl,
    );
  }

  String get displayTitle => title ?? filename ?? 'Unknown Track';
  String? get displayArtist => artist;
}

