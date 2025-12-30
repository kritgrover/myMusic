import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/playlist.dart';

class RecommendationService {
  final String baseUrl;

  RecommendationService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  Future<void> logHistory({
    required String title,
    required String artist,
    required double durationPlayed,
    String? spotifyId,
  }) async {
    try {
      await http.post(
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
      final response = await http.get(Uri.parse('$baseUrl/recommendations/daily'));
      
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

  Future<List<dynamic>> getNewReleases() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/recommendations/new-releases'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      print('Error getting new releases: $e');
      return [];
    }
  }

  Future<List<dynamic>> getGenrePlaylists(String genre) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/recommendations/genre/$genre'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      print('Error getting genre playlists: $e');
      return [];
    }
  }

  Future<List<PlaylistTrack>> getSpotifyPlaylistTracks(String playlistId) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/recommendations/playlist/$playlistId'));
      
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

