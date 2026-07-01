import 'dart:convert';

import '../config.dart';
import '../models/playlist.dart';
import 'auth_http_client.dart';

/// A lightweight view of another user, returned by search and follow listings.
class PublicUser {
  final int id;
  final String username;
  final String tagline;
  final bool isFollowing;

  PublicUser({
    required this.id,
    required this.username,
    this.tagline = '',
    this.isFollowing = false,
  });

  factory PublicUser.fromJson(Map<String, dynamic> json) {
    return PublicUser(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      tagline: json['tagline'] as String? ?? '',
      isFollowing: json['is_following'] as bool? ?? false,
    );
  }

  PublicUser copyWith({bool? isFollowing}) {
    return PublicUser(
      id: id,
      username: username,
      tagline: tagline,
      isFollowing: isFollowing ?? this.isFollowing,
    );
  }
}

/// A friend's full public profile (header + counts + follow state).
class FriendProfile {
  final int id;
  final String username;
  final String tagline;
  final DateTime? createdAt;
  final bool isFollowing;
  final int publicPlaylistCount;

  FriendProfile({
    required this.id,
    required this.username,
    this.tagline = '',
    this.createdAt,
    this.isFollowing = false,
    this.publicPlaylistCount = 0,
  });

  factory FriendProfile.fromJson(Map<String, dynamic> json) {
    return FriendProfile(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      tagline: json['tagline'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      isFollowing: json['is_following'] as bool? ?? false,
      publicPlaylistCount: json['public_playlist_count'] as int? ?? 0,
    );
  }
}

/// Talks to the social endpoints (user search, follow graph, public playlists).
/// Mirrors [ProfileService]/[PlaylistService] and reuses the shared Bearer client.
class FriendsService {
  final String baseUrl;
  final AuthHttpClient _client;

  FriendsService({String? baseUrl, AuthHttpClient? client})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared;

  Future<List<PublicUser>> searchUsers(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    final response = await _client
        .get(Uri.parse('$baseUrl/users/search?q=${Uri.encodeQueryComponent(trimmed)}'));
    if (response.statusCode != 200) {
      throw Exception('Failed to search users: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((item) => PublicUser.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<PublicUser>> getFollowing() async {
    final response = await _client.get(Uri.parse('$baseUrl/following'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load following: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    // The /following list implies you follow each one.
    return data
        .map((item) => PublicUser.fromJson({...item as Map<String, dynamic>, 'is_following': true}))
        .toList();
  }

  Future<FriendProfile> getUserProfile(int userId) async {
    final response = await _client.get(Uri.parse('$baseUrl/users/$userId'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load profile: ${response.statusCode}');
    }
    return FriendProfile.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<Playlist>> getUserPlaylists(int userId) async {
    final response = await _client.get(Uri.parse('$baseUrl/users/$userId/playlists'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load playlists: ${response.statusCode}');
    }
    final Map<String, dynamic> data = jsonDecode(response.body);
    return data.values.map((json) => Playlist.fromJson(json)).toList();
  }

  Future<Playlist> getUserPlaylist(int userId, String playlistId) async {
    final response =
        await _client.get(Uri.parse('$baseUrl/users/$userId/playlists/$playlistId'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load playlist: ${response.statusCode}');
    }
    return Playlist.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<void> follow(int userId) async {
    final response = await _client.post(Uri.parse('$baseUrl/follow/$userId'));
    if (response.statusCode != 200) {
      throw Exception('Failed to follow: ${response.statusCode}');
    }
  }

  Future<void> unfollow(int userId) async {
    final response = await _client.delete(Uri.parse('$baseUrl/follow/$userId'));
    if (response.statusCode != 200) {
      throw Exception('Failed to unfollow: ${response.statusCode}');
    }
  }

  /// Clones a friend's public playlist into the current user's own playlists.
  Future<Playlist> savePlaylistToLibrary(int userId, String playlistId) async {
    final response =
        await _client.post(Uri.parse('$baseUrl/users/$userId/playlists/$playlistId/save'));
    if (response.statusCode != 200) {
      throw Exception('Failed to save playlist: ${response.statusCode}');
    }
    return Playlist.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
