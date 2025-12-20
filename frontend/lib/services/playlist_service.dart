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

  Future<void> savePlaylist(Playlist playlist) async {
    await createPlaylist(playlist.name);
  }

  Future<void> updatePlaylist(String id, String name) async {
    final response = await http.put(
      Uri.parse('$baseUrl/playlists/$id'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to update playlist: ${response.statusCode}');
    }
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

  Future<void> updatePlaylistCover(String playlistId, String? coverImageUrl) async {
    final response = await http.put(
      Uri.parse('$baseUrl/playlists/$playlistId/cover'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'coverImage': coverImageUrl}),
    );
    
    if (response.statusCode != 200) {
      throw Exception('Failed to update cover: ${response.statusCode}');
    }
  }

  Future<void> uploadPlaylistCover(String playlistId, List<int> imageBytes, String filename) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/playlists/$playlistId/cover/upload'),
    );
    
    // Determine content type from filename extension
    String contentType = 'image/jpeg'; // default
    if (filename.contains('.')) {
      final ext = filename.toLowerCase().split('.').last;
      switch (ext) {
        case 'jpg':
        case 'jpeg':
          contentType = 'image/jpeg';
          break;
        case 'png':
          contentType = 'image/png';
          break;
        case 'gif':
          contentType = 'image/gif';
          break;
        case 'webp':
          contentType = 'image/webp';
          break;
      }
    }
    
    final file = http.MultipartFile.fromBytes(
      'file',
      imageBytes,
      filename: filename,
      contentType: http.MediaType.parse(contentType),
    );
    request.files.add(file);
    
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    
    if (response.statusCode != 200) {
      final errorBody = response.body;
      throw Exception('Failed to upload cover: ${response.statusCode} - $errorBody');
    }
  }
}
