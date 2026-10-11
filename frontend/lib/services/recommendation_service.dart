import 'dart:convert';
import '../config.dart';
import '../models/playlist.dart';
import '../models/discovery.dart';
import 'auth_http_client.dart';

class RecommendationService {
  final String baseUrl;
  final AuthHttpClient _client;
  final Duration listeningReportTimeout;

  RecommendationService(
      {String? baseUrl,
      AuthHttpClient? client,
      this.listeningReportTimeout = const Duration(seconds: 5)})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared {
    if (listeningReportTimeout <= Duration.zero) {
      throw ArgumentError.value(listeningReportTimeout,
          'listeningReportTimeout', 'Must be a positive duration.');
    }
  }

  /// Non-secret identity used by the listening recorder to discard pending
  /// events when an account signs out or another account signs in.
  String get sessionScope => _client.cacheScope;

  Future<void> recordListeningEvent(Map<String, dynamic> body) async {
    final scope = sessionScope;
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/history/listening'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(listeningReportTimeout);
      if (scope != sessionScope) {
        throw StateError('The listening session changed.');
      }
      if (response.statusCode != 200) {
        throw StateError(
            'Could not record listening progress (${response.statusCode}).');
      }
    } catch (_) {
      if (scope != sessionScope) {
        throw StateError('The listening session changed.');
      }
      rethrow;
    }
  }

  Map<String, dynamic> _trackJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    return {
      ..._artworkJson(json),
      'duration': duration is num && duration.isFinite && duration >= 0
          ? duration.toDouble()
          : 0.0,
      'filename': json['filename'] is String ? json['filename'] : '',
    };
  }

  Map<String, dynamic> _artworkJson(Map<String, dynamic> json) {
    final thumbnail = json['thumbnail'];
    return {
      ...json,
      'thumbnail': thumbnail is String && thumbnail.startsWith('/')
          ? Uri.parse(baseUrl).resolve(thumbnail).toString()
          : thumbnail,
    };
  }

  Map<String, dynamic> _rowJson(Map<String, dynamic> json) => {
        ...json,
        'tracks': (json['tracks'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(_trackJson)
            .toList(),
      };

  Future<List<PlaylistTrack>> _getTracks(String path) async {
    final scope = sessionScope;
    try {
      final response = await _client.get(Uri.parse('$baseUrl$path'));
      if (scope != sessionScope || response.statusCode != 200) return [];
      final data = jsonDecode(response.body);
      if (data is! List) return [];
      return data
          .whereType<Map<String, dynamic>>()
          .map((json) => PlaylistTrack.fromJson(_trackJson(json)))
          .toList();
    } catch (_) {
      return [];
    }
  }

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
    return _getTracks('/recommendations/daily');
  }

  Future<List<Map<String, dynamic>>> getNewReleases() async {
    final scope = sessionScope;
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/new-releases'));

      if (scope == sessionScope && response.statusCode == 200) {
        return List<Map<String, dynamic>>.from(
          (jsonDecode(response.body) as List)
              .map((e) => _artworkJson(e as Map<String, dynamic>)),
        );
      }
      return [];
    } catch (e) {
      print('Error getting new releases: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getForYou() async {
    return _getTracks('/recommendations/for-you');
  }

  Future<List<PlaylistTrack>> getGenreTracks(String genre) async {
    return _getTracks('/recommendations/genre/${Uri.encodeComponent(genre)}');
  }

  Future<List<dynamic>> getGenrePlaylists(String genre) async {
    try {
      // Use the legacy playlists endpoint
      final response = await _client
          .get(Uri.parse('$baseUrl/recommendations/genre/$genre/playlists'));

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
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/genres'));

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
      final response = await _client.get(Uri.parse(
          '$baseUrl/recommendations/browse/new-releases?country=$country'));

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
    return _getTracks(
        '/recommendations/album/${Uri.encodeComponent(albumId)}/tracks');
  }

  // ---------------------------------------------------------------------------
  // Spotify-style home shelves
  // ---------------------------------------------------------------------------

  Future<List<HomeMix>> getMixes() async {
    final scope = sessionScope;
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/mixes'));
      if (scope == sessionScope && response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => HomeMix.fromJson(_rowJson(j as Map<String, dynamic>)))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting mixes: $e');
      return [];
    }
  }

  Future<List<SpotifyPlaylistInfo>> getCuratedPlaylists() async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/curated'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => SpotifyPlaylistInfo.fromJson(j as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting curated playlists: $e');
      return [];
    }
  }

  Future<List<MoodCategory>> getMoods() async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/moods'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => MoodCategory.fromJson(j as Map<String, dynamic>))
            .toList();
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
        Uri.parse(
            '$baseUrl/recommendations/mood/${Uri.encodeComponent(mood)}/playlists'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => SpotifyPlaylistInfo.fromJson(j as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting mood playlists: $e');
      return [];
    }
  }

  Future<List<BecauseRow>> getBecauseYouListened() async {
    final scope = sessionScope;
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/recommendations/because-you-listened'));
      if (scope == sessionScope && response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map(
                (j) => BecauseRow.fromJson(_rowJson(j as Map<String, dynamic>)))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting because-you-listened: $e');
      return [];
    }
  }

  Future<List<ArtistInfo>> getRecommendedArtists() async {
    final scope = sessionScope;
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/recommendations/artists'));
      if (scope == sessionScope && response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) =>
                ArtistInfo.fromJson(_artworkJson(j as Map<String, dynamic>)))
            .toList();
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
        return AlbumInfo.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Error getting album: $e');
      return null;
    }
  }

  Future<ArtistInfo?> getArtist(String artistId) async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/artist/$artistId'));
      if (response.statusCode == 200) {
        return ArtistInfo.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('Error getting artist: $e');
      return null;
    }
  }

  Future<List<PlaylistTrack>> getArtistTopTracks(String artistId) async {
    return _getTracks('/artist/${Uri.encodeComponent(artistId)}/top-tracks');
  }

  Future<List<AlbumInfo>> getArtistAlbums(String artistId) async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/artist/$artistId/albums'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => AlbumInfo.fromJson(j as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting artist albums: $e');
      return [];
    }
  }

  Future<List<ArtistInfo>> getRelatedArtists(String artistId) async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl/artist/$artistId/related'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data
            .map((j) => ArtistInfo.fromJson(j as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('Error getting related artists: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getSpotifyPlaylistTracks(
      String playlistId) async {
    return _getTracks(
        '/recommendations/playlist/${Uri.encodeComponent(playlistId)}');
  }
}
