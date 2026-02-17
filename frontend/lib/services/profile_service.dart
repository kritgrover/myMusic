import 'dart:convert';

import '../config.dart';
import 'auth_http_client.dart';

class UserProfile {
  final int id;
  final String username;
  final String tagline;
  final DateTime? createdAt;

  UserProfile({
    required this.id,
    required this.username,
    required this.tagline,
    this.createdAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      tagline: json['tagline'] as String? ?? '',
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) : null,
    );
  }
}

class ProfileHistoryItem {
  final int id;
  final String title;
  final String artist;
  final DateTime playedAt;
  final double durationPlayed;
  final String? spotifyId;

  ProfileHistoryItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.playedAt,
    required this.durationPlayed,
    this.spotifyId,
  });

  factory ProfileHistoryItem.fromJson(Map<String, dynamic> json) {
    final timestamp = json['timestamp'] as String? ?? '';
    return ProfileHistoryItem(
      id: json['id'] as int? ?? 0,
      title: json['song_title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      playedAt: DateTime.tryParse(timestamp) ?? DateTime.now(),
      durationPlayed: (json['duration_played'] as num?)?.toDouble() ?? 0.0,
      spotifyId: json['spotify_id'] as String?,
    );
  }
}

class AnalyticsTotals {
  final int plays;
  final double minutes;
  final int uniqueArtists;

  AnalyticsTotals({
    required this.plays,
    required this.minutes,
    required this.uniqueArtists,
  });

  factory AnalyticsTotals.fromJson(Map<String, dynamic> json) {
    return AnalyticsTotals(
      plays: json['plays'] as int? ?? 0,
      minutes: (json['minutes'] as num?)?.toDouble() ?? 0.0,
      uniqueArtists: json['unique_artists'] as int? ?? 0,
    );
  }
}

class ArtistStat {
  final String artist;
  final int count;

  ArtistStat({required this.artist, required this.count});

  factory ArtistStat.fromJson(Map<String, dynamic> json) {
    return ArtistStat(
      artist: json['artist'] as String? ?? '',
      count: json['count'] as int? ?? 0,
    );
  }
}

class TrackStat {
  final String title;
  final String artist;
  final int count;

  TrackStat({required this.title, required this.artist, required this.count});

  factory TrackStat.fromJson(Map<String, dynamic> json) {
    return TrackStat(
      title: json['song_title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      count: json['count'] as int? ?? 0,
    );
  }
}

class AnalyticsRecap {
  final String period;
  final DateTime? startDate;
  final DateTime? endDate;
  final AnalyticsTotals totals;
  final List<ArtistStat> topArtists;
  final List<TrackStat> topTracks;
  final List<String> topGenres;

  AnalyticsRecap({
    required this.period,
    required this.startDate,
    required this.endDate,
    required this.totals,
    required this.topArtists,
    required this.topTracks,
    required this.topGenres,
  });

  factory AnalyticsRecap.fromJson(Map<String, dynamic> json) {
    return AnalyticsRecap(
      period: json['period'] as String? ?? 'weekly',
      startDate: json['start_date'] != null ? DateTime.tryParse(json['start_date'] as String) : null,
      endDate: json['end_date'] != null ? DateTime.tryParse(json['end_date'] as String) : null,
      totals: AnalyticsTotals.fromJson((json['totals'] as Map<String, dynamic>?) ?? <String, dynamic>{}),
      topArtists: ((json['top_artists'] as List<dynamic>?) ?? const [])
          .map((item) => ArtistStat.fromJson(item as Map<String, dynamic>))
          .toList(),
      topTracks: ((json['top_tracks'] as List<dynamic>?) ?? const [])
          .map((item) => TrackStat.fromJson(item as Map<String, dynamic>))
          .toList(),
      topGenres: List<String>.from((json['top_genres'] as List<dynamic>?) ?? const []),
    );
  }
}

class ProfileService {
  final String baseUrl;
  final AuthHttpClient _client;

  ProfileService({String? baseUrl, AuthHttpClient? client})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _client = client ?? AuthHttpClient.shared;

  Future<UserProfile> getProfile() async {
    final response = await _client.get(Uri.parse('$baseUrl/profile/me'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load profile');
    }
    return UserProfile.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<UserProfile> updateProfile({
    required String username,
    required String tagline,
  }) async {
    final response = await _client.put(
      Uri.parse('$baseUrl/profile/me'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'tagline': tagline,
      }),
    );
    if (response.statusCode != 200) {
      final body = response.body;
      throw Exception('Failed to update profile: $body');
    }
    return UserProfile.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<ProfileHistoryItem>> getRecentHistory({int limit = 20}) async {
    final response = await _client.get(Uri.parse('$baseUrl/history/recent?limit=$limit'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load recent history');
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data.map((item) => ProfileHistoryItem.fromJson(item as Map<String, dynamic>)).toList();
  }

  Future<AnalyticsRecap> getAnalyticsRecap({String period = 'weekly'}) async {
    final response = await _client.get(Uri.parse('$baseUrl/analytics/recap?period=$period'));
    if (response.statusCode != 200) {
      throw Exception('Failed to load analytics recap');
    }
    return AnalyticsRecap.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}
