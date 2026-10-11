import 'playlist.dart';

/// Search retains provider identity and recording details alongside playable data.
class SearchEntry {
  final Map<String, dynamic> data;
  const SearchEntry(this.data);

  String get id => (data['id'] ?? '').toString();
  String get kind => (data['kind'] ?? 'track').toString();
  String get title => (data['title'] ?? data['name'] ?? '').toString();
  String get artist => (data['artist'] ?? data['owner'] ?? '').toString();
  String get provider => (data['provider'] ?? '').toString();
  String get recordingLabel => (data['recording_label'] ?? '').toString();
  String? get thumbnail => data['thumbnail'] as String?;
  String get origin => (data['library_origin'] ?? '').toString();
  PlaylistTrack get track => PlaylistTrack.fromJson({
        ...data,
        'id': _trackIdentity,
        'title': title,
        'artist': artist,
        'filename': data['filename'] ?? '',
      });

  String get _trackIdentity {
    for (final key in ['spotify_id', 'source_id', 'id']) {
      final value = data[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return '';
  }
}

class SearchResults {
  final List<SearchEntry> songs;
  final List<SearchEntry> artists;
  final List<SearchEntry> albums;
  final List<SearchEntry> playlists;
  final List<SearchEntry> library;
  final List<String> suggestions;
  final List<String> warnings;

  const SearchResults({
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
    this.library = const [],
    this.suggestions = const [],
    this.warnings = const [],
  });

  bool get isEmpty =>
      songs.isEmpty &&
      artists.isEmpty &&
      albums.isEmpty &&
      playlists.isEmpty &&
      library.isEmpty;

  factory SearchResults.fromJson(Map<String, dynamic> json) {
    List<SearchEntry> entries(String key) => (json[key] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((value) => SearchEntry(Map.unmodifiable(value)))
        .toList(growable: false);
    return SearchResults(
      songs: entries('songs'),
      artists: entries('artists'),
      albums: entries('albums'),
      playlists: entries('playlists'),
      library: entries('library'),
      suggestions:
          (json['suggestions'] as List? ?? []).whereType<String>().toList(),
      warnings: (json['warnings'] as List? ?? []).whereType<String>().toList(),
    );
  }
}
