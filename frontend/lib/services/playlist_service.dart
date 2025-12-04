import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/playlist.dart';

class PlaylistService {
  final String baseUrl;

  PlaylistService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  Future<List<Playlist>> getAllPlaylists() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/playlists'));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        // Backend returns Dict[str, Playlist]. Values are the playlists.
        return data.values.map((json) => Playlist.fromJson(json)).toList();
      } else {
        return [];
      }
    } catch (e) {
      return [];
    }
  }

  Future<Playlist?> getPlaylist(String id) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/playlists/$id'));
      if (response.statusCode == 200) {
        return Playlist.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<Playlist> createPlaylist(String name) async {
    final response = await http.post(
      Uri.parse('$baseUrl/playlists'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );

    if (response.statusCode == 200) {
      return Playlist.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to create playlist: ${response.statusCode}');
    }
  }

  // Deprecated: Use createPlaylist for new playlists.
  // This is kept for compatibility if called with a new playlist object.
  Future<void> savePlaylist(Playlist playlist) async {
    // We assume this is only called for creation in the old flow
    await createPlaylist(playlist.name);
  }

  Future<void> deletePlaylist(String id) async {
    final response = await http.delete(Uri.parse('$baseUrl/playlists/$id'));
    if (response.statusCode != 200) {
       throw Exception('Failed to delete playlist');
    }
  }

  Future<void> addTrackToPlaylist(String playlistId, PlaylistTrack track) async {
    final response = await http.post(
      Uri.parse('$baseUrl/playlists/$playlistId/songs'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(track.toJson()),
    );
    
    if (response.statusCode != 200) {
      throw Exception('Failed to add track: ${response.statusCode}');
    }
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/playlists/$playlistId/songs/$trackId'),
    );
    
    if (response.statusCode != 200) {
      throw Exception('Failed to remove track: ${response.statusCode}');
    }
  }
}
