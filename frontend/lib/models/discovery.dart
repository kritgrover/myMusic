import 'playlist.dart';

/// A curated/themed Spotify playlist surfaced on the home (mood rows, curated rows).
class SpotifyPlaylistInfo {
  final String id;
  final String name;
  final String? description;
  final String? thumbnail;
  final String? owner;
  final String? url;

  SpotifyPlaylistInfo({
    required this.id,
    required this.name,
    this.description,
    this.thumbnail,
    this.owner,
    this.url,
  });

  factory SpotifyPlaylistInfo.fromJson(Map<String, dynamic> json) {
    return SpotifyPlaylistInfo(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'],
      thumbnail: json['thumbnail'],
      owner: json['owner'],
      url: json['url'],
    );
  }
}

/// A Spotify artist (recommended-artists row, artist screen, related artists).
class ArtistInfo {
  final String id;
  final String name;
  final String? thumbnail;
  final List<String> genres;
  final int? followers;

  ArtistInfo({
    required this.id,
    required this.name,
    this.thumbnail,
    this.genres = const [],
    this.followers,
  });

  factory ArtistInfo.fromJson(Map<String, dynamic> json) {
    return ArtistInfo(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      thumbnail: json['thumbnail'],
      genres: (json['genres'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      followers: (json['followers'] as num?)?.toInt(),
    );
  }
}

/// Album metadata (new releases, album detail screen, artist discography).
class AlbumInfo {
  final String id;
  final String name;
  final String? artist;
  final String? artistId;
  final String? thumbnail;
  final String? releaseDate;
  final String? type;
  final int? totalTracks;

  AlbumInfo({
    required this.id,
    required this.name,
    this.artist,
    this.artistId,
    this.thumbnail,
    this.releaseDate,
    this.type,
    this.totalTracks,
  });

  factory AlbumInfo.fromJson(Map<String, dynamic> json) {
    return AlbumInfo(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      artist: json['artist'],
      artistId: json['artist_id'],
      thumbnail: json['thumbnail'],
      releaseDate: json['release_date'],
      type: json['type'],
      totalTracks: (json['total_tracks'] as num?)?.toInt(),
    );
  }
}

/// A personalized "Made for You" mix (one row per top genre).
class HomeMix {
  final String id;
  final String title;
  final String genre;
  final List<PlaylistTrack> tracks;

  HomeMix({required this.id, required this.title, required this.genre, required this.tracks});

  factory HomeMix.fromJson(Map<String, dynamic> json) {
    return HomeMix(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      genre: json['genre'] ?? '',
      tracks: (json['tracks'] as List<dynamic>?)
              ?.map((t) => PlaylistTrack.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// A "Because you listened to {artist}" row.
class BecauseRow {
  final String seedArtistId;
  final String seedArtistName;
  final String title;
  final List<PlaylistTrack> tracks;

  BecauseRow({
    required this.seedArtistId,
    required this.seedArtistName,
    required this.title,
    required this.tracks,
  });

  factory BecauseRow.fromJson(Map<String, dynamic> json) {
    return BecauseRow(
      seedArtistId: json['seed_artist_id'] ?? '',
      seedArtistName: json['seed_artist_name'] ?? '',
      title: json['title'] ?? '',
      tracks: (json['tracks'] as List<dynamic>?)
              ?.map((t) => PlaylistTrack.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// A mood/activity category (rendered as a gradient card).
class MoodCategory {
  final String mood;
  final String title;
  final String? thumbnail;

  MoodCategory({required this.mood, required this.title, this.thumbnail});

  factory MoodCategory.fromJson(Map<String, dynamic> json) {
    return MoodCategory(
      mood: json['mood'] ?? '',
      title: json['title'] ?? json['mood'] ?? '',
      thumbnail: json['thumbnail'],
    );
  }
}
