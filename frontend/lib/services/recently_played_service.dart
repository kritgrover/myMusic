import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';

enum RecentlyPlayedType {
  song,
  playlist,
}

class RecentlyPlayedItem {
  final RecentlyPlayedType type;
  final String id;
  final String title;
  final String? artist;
  final String? thumbnail;
  final String? filename; // For songs
  final String? url; // Original YouTube URL for streaming
  final String? playlistId; // For playlists
  final DateTime playedAt;

  RecentlyPlayedItem({
    required this.type,
    required this.id,
    required this.title,
    this.artist,
    this.thumbnail,
    this.filename,
    this.url,
    this.playlistId,
    required this.playedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'id': id,
      'title': title,
      'artist': artist,
      'thumbnail': thumbnail,
      'filename': filename,
      'url': url,
      'playlistId': playlistId,
      'playedAt': playedAt.toIso8601String(),
    };
  }

  factory RecentlyPlayedItem.fromJson(Map<String, dynamic> json) {
    return RecentlyPlayedItem(
      type: RecentlyPlayedType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => RecentlyPlayedType.song,
      ),
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'],
      thumbnail: json['thumbnail'],
      filename: json['filename'],
      url: json['url'],
      playlistId: json['playlistId'],
      playedAt: DateTime.parse(json['playedAt'] ?? DateTime.now().toIso8601String()),
    );
  }
}

class RecentlyPlayedService extends ChangeNotifier {
  static const String _storageKey = 'recently_played';
  static const int _maxItems = 4;
  List<RecentlyPlayedItem> _items = [];

  List<RecentlyPlayedItem> get items => List.unmodifiable(_items);

  RecentlyPlayedService() {
    _loadItems();
  }

  Future<void> _loadItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_storageKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        _items = jsonList
            .map((json) => RecentlyPlayedItem.fromJson(json))
            .toList();
        // Sort by playedAt descending (most recent first)
        _items.sort((a, b) => b.playedAt.compareTo(a.playedAt));
        // Keep only the most recent items
        if (_items.length > _maxItems) {
          _items = _items.take(_maxItems).toList();
        }
        notifyListeners();
      }
    } catch (e) {
      print('Error loading recently played items: $e');
      _items = [];
    }
  }

  Future<void> _saveItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_items.map((item) => item.toJson()).toList());
      await prefs.setString(_storageKey, jsonString);
    } catch (e) {
      print('Error saving recently played items: $e');
    }
  }

  Future<void> addSong({
    required String id,
    required String title,
    String? artist,
    String? thumbnail,
    String? filename,
    String? url,
  }) async {
    // Remove existing item with same id if it exists
    _items.removeWhere((item) => item.id == id && item.type == RecentlyPlayedType.song);
    
    // Add new item at the beginning
    _items.insert(0, RecentlyPlayedItem(
      type: RecentlyPlayedType.song,
      id: id,
      title: title,
      artist: artist,
      thumbnail: thumbnail,
      filename: filename,
      url: url,
      playedAt: DateTime.now(),
    ));

    // Keep only the most recent items
    if (_items.length > _maxItems) {
      _items = _items.take(_maxItems).toList();
    }

    await _saveItems();
    notifyListeners();
  }

  Future<void> addPlaylist({
    required String playlistId,
    required String title,
    String? thumbnail,
  }) async {
    // Remove existing item with same id if it exists
    _items.removeWhere((item) => item.id == playlistId && item.type == RecentlyPlayedType.playlist);
    
    // Add new item at the beginning
    _items.insert(0, RecentlyPlayedItem(
      type: RecentlyPlayedType.playlist,
      id: playlistId,
      title: title,
      thumbnail: thumbnail,
      playlistId: playlistId,
      playedAt: DateTime.now(),
    ));

    // Keep only the most recent items
    if (_items.length > _maxItems) {
      _items = _items.take(_maxItems).toList();
    }

    await _saveItems();
    notifyListeners();
  }

  Future<void> clear() async {
    _items.clear();
    await _saveItems();
    notifyListeners();
  }
}

