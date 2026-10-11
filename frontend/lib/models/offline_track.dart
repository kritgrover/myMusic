import 'queue_item.dart';

/// A completed device copy. [filename] is always the backend identity.
class OfflineTrack {
  final String id;
  final String filename;
  final String title;
  final String? artist;
  final String? album;
  final String? thumbnail;
  final String? localArtworkUrl;
  final double? duration;
  final String? originalUrl;
  final String? spotifyId;
  final int bytes;
  final DateTime downloadedAt;
  final Map<String, String> playlists;
  final Map<String, int> playlistPositions;
  final List<String> sourceKeys;
  final String relativePath;
  final String checksum;
  final String? artworkPath;

  const OfflineTrack({
    required this.id,
    required this.filename,
    required this.title,
    this.artist,
    this.album,
    this.thumbnail,
    this.localArtworkUrl,
    this.duration,
    this.originalUrl,
    this.spotifyId,
    required this.bytes,
    required this.downloadedAt,
    this.playlists = const {},
    this.playlistPositions = const {},
    this.sourceKeys = const [],
    this.relativePath = '',
    this.checksum = '',
    this.artworkPath,
  });

  List<String> get playlistIds => playlists.keys.toList(growable: false);
  List<String> get playlistNames => playlists.values.toList(growable: false);

  QueueItem toQueueItem() => QueueItem(
        id: id,
        filename: filename,
        title: title,
        artist: artist,
        album: album,
        thumbnail: thumbnail,
        duration: duration,
        originalUrl: originalUrl,
        spotifyId: spotifyId,
      );

  OfflineTrack withPlaylists(
          Map<String, String> names, Map<String, int> positions,
          {Iterable<String> additionalKeys = const [],
          String? sourceUrl,
          String? sourceSpotifyId}) =>
      OfflineTrack(
        id: id,
        filename: filename,
        title: title,
        artist: artist,
        album: album,
        thumbnail: thumbnail,
        localArtworkUrl: localArtworkUrl,
        duration: duration,
        originalUrl: sourceUrl ?? originalUrl,
        spotifyId: sourceSpotifyId ?? spotifyId,
        bytes: bytes,
        downloadedAt: downloadedAt,
        playlists: Map.unmodifiable({...playlists, ...names}),
        playlistPositions:
            Map.unmodifiable({...playlistPositions, ...positions}),
        sourceKeys: {...sourceKeys, ...additionalKeys}.toList(growable: false),
        relativePath: relativePath,
        checksum: checksum,
        artworkPath: artworkPath,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'filename': filename,
        'title': title,
        'artist': artist,
        'album': album,
        'thumbnail': thumbnail,
        'duration': duration,
        'originalUrl': originalUrl,
        'spotifyId': spotifyId,
        'bytes': bytes,
        'downloadedAt': downloadedAt.toIso8601String(),
        'playlists': playlists,
        'playlistPositions': playlistPositions,
        'sourceKeys': sourceKeys,
        'relativePath': relativePath,
        'checksum': checksum,
        'artworkPath': artworkPath,
      };

  factory OfflineTrack.fromJson(Map<String, dynamic> json,
          {String? localArtworkUrl}) =>
      OfflineTrack(
        id: json['id'] as String,
        filename: json['filename'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        thumbnail: json['thumbnail'] as String?,
        duration: (json['duration'] as num?)?.toDouble(),
        originalUrl: json['originalUrl'] as String?,
        spotifyId: json['spotifyId'] as String?,
        bytes: json['bytes'] as int,
        downloadedAt: DateTime.parse(json['downloadedAt'] as String),
        playlists: Map<String, String>.from(json['playlists'] as Map? ?? {}),
        playlistPositions:
            Map<String, int>.from(json['playlistPositions'] as Map? ?? {}),
        sourceKeys: List<String>.from(json['sourceKeys'] as List? ?? []),
        relativePath: json['relativePath'] as String,
        checksum: json['checksum'] as String,
        artworkPath: json['artworkPath'] as String?,
        localArtworkUrl: localArtworkUrl,
      );
}
