import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';

class PlaylistService {
  static const String _playlistsKey = 'playlists';

  Future<List<Playlist>> getAllPlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlistsJson = prefs.getString(_playlistsKey);
      
      if (playlistsJson == null) {
        return [];
      }

      final List<dynamic> playlistsList = jsonDecode(playlistsJson);
      return playlistsList.map((json) => Playlist.fromJson(json)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<Playlist?> getPlaylist(String id) async {
    final playlists = await getAllPlaylists();
    try {
      return playlists.firstWhere((p) => p.id == id);
    } catch (e) {
      return null;
    }
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final playlists = await getAllPlaylists();
    final index = playlists.indexWhere((p) => p.id == playlist.id);
    
    final updatedPlaylist = playlist.copyWith(
      updatedAt: DateTime.now(),
    );

    if (index >= 0) {
      playlists[index] = updatedPlaylist;
    } else {
      playlists.add(updatedPlaylist);
    }

    await _saveAllPlaylists(playlists);
  }

  Future<void> deletePlaylist(String id) async {
    final playlists = await getAllPlaylists();
    playlists.removeWhere((p) => p.id == id);
    await _saveAllPlaylists(playlists);
  }

  Future<void> addTrackToPlaylist(String playlistId, PlaylistTrack track) async {
    final playlist = await getPlaylist(playlistId);
    if (playlist == null) return;

    final updatedTracks = List<PlaylistTrack>.from(playlist.tracks);
    
    // Check if track already exists
    if (!updatedTracks.any((t) => t.id == track.id)) {
      updatedTracks.add(track);
    }

    final updatedPlaylist = playlist.copyWith(
      tracks: updatedTracks,
      updatedAt: DateTime.now(),
    );

    await savePlaylist(updatedPlaylist);
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    final playlist = await getPlaylist(playlistId);
    if (playlist == null) return;

    final updatedTracks = playlist.tracks.where((t) => t.id != trackId).toList();
    final updatedPlaylist = playlist.copyWith(
      tracks: updatedTracks,
      updatedAt: DateTime.now(),
    );

    await savePlaylist(updatedPlaylist);
  }

  Future<void> _saveAllPlaylists(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    final playlistsJson = jsonEncode(playlists.map((p) => p.toJson()).toList());
    await prefs.setString(_playlistsKey, playlistsJson);
  }
}

