import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/playlist.dart';
import '../models/discovery.dart';
import 'auth_http_client.dart';

class CatalogAccessException extends StateError {
  CatalogAccessException()
      : super('Spotify does not allow this connection to read this playlist. '
            'You can still discover music through songs, artists, and albums.');
}

class RecommendationService extends ChangeNotifier {
  final String baseUrl;
  final AuthHttpClient _client;
  final Duration listeningReportTimeout;
  final Duration requestTimeout;
  final Map<String, String> _discoveryIssues = {};
  final Map<String, int> _requests = {};
  String? _issuesScope;
  bool _disposed = false;
  static const _homePaths = {
    '/recommendations/daily',
    '/recommendations/new-releases',
    '/recommendations/mixes',
    '/recommendations/because-you-listened',
    '/recommendations/curated',
    '/recommendations/artists',
    '/recommendations/moods',
  };

  RecommendationService(
      {String? baseUrl,
      AuthHttpClient? client,
      this.requestTimeout = const Duration(seconds: 45),
      this.listeningReportTimeout = const Duration(seconds: 5)})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared {
    if (listeningReportTimeout <= Duration.zero) {
      throw ArgumentError.value(listeningReportTimeout,
          'listeningReportTimeout', 'Must be a positive duration.');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
          requestTimeout, 'requestTimeout', 'Must be a positive duration.');
    }
  }

  String? get discoveryMessage =>
      _issuesScope == sessionScope && _discoveryIssues.isNotEmpty
          ? _discoveryIssues.values.first
          : null;

  Future<http.Response> _get(Uri uri, {Duration? timeout}) async {
    final scope = sessionScope;
    if (_issuesScope != scope) {
      _issuesScope = scope;
      _discoveryIssues.clear();
      _requests.clear();
    }
    final path = uri.path;
    final revision = (_requests[path] ?? 0) + 1;
    _requests[path] = revision;
    void update(String? issue) {
      if (_disposed ||
          scope != sessionScope ||
          _issuesScope != scope ||
          _requests[path] != revision ||
          !_homePaths.contains(path)) {
        return;
      }
      final previous = _discoveryIssues[path];
      if (issue == null) {
        _discoveryIssues.remove(path);
      } else {
        _discoveryIssues[path] = issue;
      }
      if (previous != issue) notifyListeners();
    }

    try {
      final response =
          await _client.get(uri).timeout(timeout ?? requestTimeout);
      if (response.statusCode == 200 && _homePaths.contains(path)) {
        final data = jsonDecode(response.body);
        if (data is! List || data.any((row) => row is! Map<String, dynamic>)) {
          throw const FormatException('Invalid discovery response.');
        }
      }
      update(response.statusCode == 200
          ? null
          : 'Some discovery sections could not load. Your library is still available.');
      return response;
    } catch (_) {
      update(
          'Some discovery sections could not load. Your library is still available.');
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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
      final response = await _get(Uri.parse('$baseUrl$path'));
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
          await _get(Uri.parse('$baseUrl/recommendations/new-releases'));

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
      final response = await _get(
          Uri.parse('$baseUrl/recommendations/genre/$genre/playlists'));

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
      final response = await _get(Uri.parse('$baseUrl/recommendations/genres'));

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
      final response = await _get(Uri.parse(
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
    final scope = sessionScope;
    final response = await _get(
        Uri.parse(
            '$baseUrl/recommendations/album/${Uri.encodeComponent(albumId)}/tracks'),
        timeout: const Duration(seconds: 55));
    if (scope != sessionScope) {
      throw StateError('The listening session changed.');
    }
    if (response.statusCode != 200) {
      throw StateError('Could not load the album tracks. Please retry.');
    }
    final data = jsonDecode(response.body);
    if (data is! List || data.any((j) => j is! Map<String, dynamic>)) {
      throw const FormatException('The album track response was invalid.');
    }
    return data
        .map((j) =>
            PlaylistTrack.fromJson(_trackJson(j as Map<String, dynamic>)))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Spotify-style home shelves
  // ---------------------------------------------------------------------------

  Future<List<HomeMix>> getMixes() async {
    final scope = sessionScope;
    try {
      final response = await _get(Uri.parse('$baseUrl/recommendations/mixes'));
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
          await _get(Uri.parse('$baseUrl/recommendations/curated'));
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
      final response = await _get(Uri.parse('$baseUrl/recommendations/moods'));
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
      final response = await _get(
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
      final response = await _get(
          Uri.parse('$baseUrl/recommendations/because-you-listened'));
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
          await _get(Uri.parse('$baseUrl/recommendations/artists'));
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
    final scope = sessionScope;
    try {
      final response = await _get(
              Uri.parse('$baseUrl/album/${Uri.encodeComponent(albumId)}'))
          .timeout(const Duration(seconds: 12));
      if (scope == sessionScope && response.statusCode == 200) {
        return AlbumInfo.fromJson(
            _artworkJson(jsonDecode(response.body) as Map<String, dynamic>));
      }
      return null;
    } catch (e) {
      print('Error getting album: $e');
      return null;
    }
  }

  Future<ArtistInfo?> getArtist(String artistId) async {
    final scope = sessionScope;
    try {
      final response = await _get(
              Uri.parse('$baseUrl/artist/${Uri.encodeComponent(artistId)}'))
          .timeout(const Duration(seconds: 12));
      if (scope == sessionScope && response.statusCode == 200) {
        return ArtistInfo.fromJson(
            _artworkJson(jsonDecode(response.body) as Map<String, dynamic>));
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
    final scope = sessionScope;
    final response = await _get(
        Uri.parse('$baseUrl/artist/${Uri.encodeComponent(artistId)}/albums'),
        timeout: const Duration(seconds: 55));
    if (scope != sessionScope) {
      throw StateError('The listening session changed.');
    }
    if (response.statusCode != 200) {
      throw StateError('Could not load the discography. Please retry.');
    }
    final data = jsonDecode(response.body);
    if (data is! List || data.any((j) => j is! Map<String, dynamic>)) {
      throw const FormatException('The discography response was invalid.');
    }
    return data
        .map((j) => AlbumInfo.fromJson(_artworkJson(j as Map<String, dynamic>)))
        .toList();
  }

  Future<List<ArtistInfo>> getRelatedArtists(String artistId) async {
    final scope = sessionScope;
    try {
      final response = await _get(Uri.parse(
              '$baseUrl/artist/${Uri.encodeComponent(artistId)}/related'))
          .timeout(const Duration(seconds: 12));
      if (scope == sessionScope && response.statusCode == 200) {
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
    final scope = sessionScope;
    final response = await _get(Uri.parse(
            '$baseUrl/recommendations/playlist/${Uri.encodeComponent(playlistId)}'))
        .timeout(const Duration(seconds: 12));
    if (scope != sessionScope) {
      throw StateError('The listening session changed.');
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 403) throw CatalogAccessException();
      throw StateError('Could not load the playlist tracks. Please retry.');
    }
    final data = jsonDecode(response.body);
    if (data is! List || data.any((j) => j is! Map<String, dynamic>)) {
      throw const FormatException('The playlist track response was invalid.');
    }
    return data
        .map((j) =>
            PlaylistTrack.fromJson(_trackJson(j as Map<String, dynamic>)))
        .toList();
  }
}
