class Playlist {
  final String id;
  final String name;
  final List<PlaylistTrack> tracks;
  final DateTime createdAt;
  final DateTime updatedAt;

  Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'songs': tracks.map((track) => track.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      tracks: ((json['songs'] ?? json['tracks']) as List<dynamic>?)
              ?.map((track) => PlaylistTrack.fromJson(track))
              .toList() ??
          [],
      createdAt: DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
      updatedAt: DateTime.parse(json['updatedAt'] ?? DateTime.now().toIso8601String()),
    );
  }

  Playlist copyWith({
    String? id,
    String? name,
    List<PlaylistTrack>? tracks,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      tracks: tracks ?? this.tracks,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class PlaylistTrack {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String filename; // For downloaded files
  final String? url; // For YouTube videos
  final String? thumbnail;
  final double? duration;

  PlaylistTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.filename,
    this.url,
    this.thumbnail,
    this.duration,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'filename': filename,
      'url': url,
      'thumbnail': thumbnail,
      'duration': duration,
    };
  }

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) {
    return PlaylistTrack(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'],
      album: json['album'],
      filename: json['filename'] ?? '',
      url: json['url'],
      thumbnail: json['thumbnail'],
      duration: json['duration']?.toDouble(),
    );
  }

  // Create from VideoInfo (search results)
  factory PlaylistTrack.fromVideoInfo(dynamic videoInfo) {
    return PlaylistTrack(
      id: videoInfo.id ?? '',
      title: videoInfo.title ?? '',
      artist: videoInfo.uploader,
      filename: '', // Not downloaded yet
      url: videoInfo.url,
      thumbnail: videoInfo.thumbnail,
      duration: videoInfo.duration is double ? videoInfo.duration : (videoInfo.duration?.toDouble()),
    );
  }

  // Create from DownloadedFile
  factory PlaylistTrack.fromDownloadedFile(dynamic downloadedFile) {
    // Use title if available, otherwise use filename
    String displayTitle = downloadedFile.title ?? downloadedFile.filename;
    
    return PlaylistTrack(
      id: downloadedFile.filename,
      title: displayTitle,
      artist: downloadedFile.artist,
      filename: downloadedFile.filename,
    );
  }
}
