import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/lyrics.dart';

class LyricsService extends ChangeNotifier {
  final String baseUrl;
  Lyrics? _currentLyrics;
  bool _isLoading = false;
  String? _error;

  LyricsService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  Lyrics? get currentLyrics => _currentLyrics;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasLyrics => _currentLyrics != null && _currentLyrics!.hasLyrics;

  Future<Lyrics?> fetchLyrics(
    String trackName,
    String artistName, {
    String? albumName,
    int? duration,
  }) async {
    if (trackName.isEmpty || artistName.isEmpty) {
      _error = 'Track name and artist name are required';
      notifyListeners();
      return null;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$baseUrl/lyrics').replace(queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        if (albumName != null && albumName.isNotEmpty) 'album_name': albumName,
        if (duration != null) 'duration': duration.toString(),
      });

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _currentLyrics = Lyrics.fromJson(data);
        _error = null;
        _isLoading = false;
        notifyListeners();
        return _currentLyrics;
      } else if (response.statusCode == 404) {
        _error = 'Lyrics not found';
        _currentLyrics = null;
        _isLoading = false;
        notifyListeners();
        return null;
      } else {
        final errorData = jsonDecode(response.body);
        _error = errorData['detail'] as String? ?? 'Failed to fetch lyrics';
        _currentLyrics = null;
        _isLoading = false;
        notifyListeners();
        return null;
      }
    } catch (e) {
      _error = 'Error fetching lyrics: $e';
      _currentLyrics = null;
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  void clearLyrics() {
    _currentLyrics = null;
    _error = null;
    _isLoading = false;
    notifyListeners();
  }
}
