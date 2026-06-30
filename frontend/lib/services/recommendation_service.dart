import 'dart:convert';
import '../config.dart';
import '../models/playlist.dart';
import '../models/discovery.dart';
import 'auth_http_client.dart';

class RecommendationService {
  final String baseUrl;
  final AuthHttpClient _client;

  RecommendationService({String? baseUrl, AuthHttpClient? client})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared;

  Future<void> logHistory({
    required String title,
    required String artist,
    required double durationPlayed,
    String? spotifyId,
  }) async {
    try {
      await _client.post(
        Uri.parse('$baseUrl/history'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'song_title': title,
          'artist': artist,
          'duration_played': durationPlayed,
          'spotify_id': spotifyId,
        }),
      );
    } catch (e) {
      print('Error logging history: $e');
    }
  }

  Future<List<PlaylistTrack>> getDailyMix() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/daily'));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => PlaylistTrack(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          artist: json['artist'],
          album: json['album'],
          filename: '', // Not downloaded
          url: json['url'],
          thumbnail: json['thumbnail'],
          duration: 0, // Spotify doesn't always return duration in this view
        )).toList();
      }
      return [];
    } catch (e) {
      print('Error getting daily mix: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getNewReleases() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/new-releases'));
      
      if (response.statusCode == 200) {
        return List<Map<String, dynamic>>.from(
          (jsonDecode(response.body) as List).map((e) => e as Map<String, dynamic>),
        );
      }
      return [];
    } catch (e) {
      print('Error getting new releases: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getForYou() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/for-you'));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => PlaylistTrack(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          artist: json['artist'],
          album: json['album'],
          filename: '',
          url: json['url'],
          thumbnail: json['thumbnail'],
          duration: 0,
        )).toList();
      }
      return [];
    } catch (e) {
      print('Error getting for-you recommendations: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getGenreTracks(String genre) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/genre/$genre'));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => PlaylistTrack(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          artist: json['artist'],
          album: json['album'],
          filename: '',
          url: json['url'],
          thumbnail: json['thumbnail'],
          duration: 0,
        )).toList();
      }
      return [];
    } catch (e) {
      print('Error getting genre tracks: $e');
      return [];
    }
  }

  Future<List<dynamic>> getGenrePlaylists(String genre) async {
    try {
      // Use the legacy playlists endpoint
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/genre/$genre/playlists'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      print('Error getting genre playlists: $e');
      return [];
    }
  }

  Future<List<String>> getAvailableGenres() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/genres'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<String>.from(data['genres'] ?? []);
      }
      return [];
    } catch (e) {
      print('Error getting available genres: $e');
      return [];
    }
  }

  Future<List<dynamic>> getBrowseNewReleases({String country = 'US'}) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/browse/new-releases?country=$country'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      print('Error getting browse new releases: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getAlbumTracks(String albumId) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/recommendations/album/$albumId/tracks'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => PlaylistTrack(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          artist: json['artist'],
          album: json['album'],
          filename: '',
          url: json['url'],
          thumbnail: json['thumbnail'],
          duration: (json['duration'] as num?)?.toDouble() ?? 0,
        )).toList();
      }
      return [];
    } catch (e) {
      print('Error getting album tracks: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Spotify-style home shelves
  // ---------------------------------------------------------------------------

  Future<List<HomeMix>> getMixes() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/mixes'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => HomeMix.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting mixes: $e');
      return [];
    }
  }

  Future<List<SpotifyPlaylistInfo>> getCuratedPlaylists() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/curated'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => SpotifyPlaylistInfo.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting curated playlists: $e');
      return [];
    }
  }

  Future<List<MoodCategory>> getMoods() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/moods'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => MoodCategory.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting moods: $e');
      return [];
    }
  }

  Future<List<SpotifyPlaylistInfo>> getMoodPlaylists(String mood) async {
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/recommendations/mood/${Uri.encodeComponent(mood)}/playlists'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => SpotifyPlaylistInfo.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting mood playlists: $e');
      return [];
    }
  }

  Future<List<BecauseRow>> getBecauseYouListened() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/because-you-listened'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => BecauseRow.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting because-you-listened: $e');
      return [];
    }
  }

  Future<List<ArtistInfo>> getRecommendedArtists() async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/artists'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => ArtistInfo.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting recommended artists: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Album & artist detail
  // ---------------------------------------------------------------------------

  Future<AlbumInfo?> getAlbum(String albumId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/album/$albumId'));
      if (response.statusCode == 200) {
        return AlbumInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Error getting album: $e');
      return null;
    }
  }

  Future<ArtistInfo?> getArtist(String artistId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/artist/$artistId'));
      if (response.statusCode == 200) {
        return ArtistInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Error getting artist: $e');
      return null;
    }
  }

  Future<List<PlaylistTrack>> getArtistTopTracks(String artistId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/artist/$artistId/top-tracks'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => PlaylistTrack.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting artist top tracks: $e');
      return [];
    }
  }

  Future<List<AlbumInfo>> getArtistAlbums(String artistId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/artist/$artistId/albums'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => AlbumInfo.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting artist albums: $e');
      return [];
    }
  }

  Future<List<ArtistInfo>> getRelatedArtists(String artistId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/artist/$artistId/related'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => ArtistInfo.fromJson(j as Map<String, dynamic>)).toList();
      }
      return [];
    } catch (e) {
      print('Error getting related artists: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getSpotifyPlaylistTracks(String playlistId) async {
    try {
      final response = await _client.get(Uri.parse('$baseUrl/recommendations/playlist/$playlistId'));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => PlaylistTrack(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          artist: json['artist'],
          album: json['album'],
          filename: '',
          url: json['url'],
          thumbnail: json['thumbnail'],
          duration: 0,
        )).toList();
      }
      return [];
    } catch (e) {
      print('Error getting spotify playlist tracks: $e');
      return [];
    }
  }
}

