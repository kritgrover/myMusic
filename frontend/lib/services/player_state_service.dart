import 'package:flutter/material.dart';
import 'dart:async';
import 'audio_player_service.dart';
import 'recently_played_service.dart';
import 'recommendation_service.dart';
import '../config.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  final RecentlyPlayedService? _recentlyPlayedService;
  final RecommendationService _recommendationService = RecommendationService();
  String? _currentTrackName;

  String? _currentTrackArtist;
  String? _currentTrackFilename;
  StreamSubscription? _stateSubscription;

  PlayerStateService({RecentlyPlayedService? recentlyPlayedService})
      : _recentlyPlayedService = recentlyPlayedService {
    // Listen to player state changes to update UI
    _stateSubscription = _audioPlayerService.stateStream.listen((_) {
      notifyListeners();
    });
  }

  AudioPlayerService get audioPlayer => _audioPlayerService;

  String? get currentTrackName => _currentTrackName;
  String? get currentTrackArtist => _currentTrackArtist;
  String? get currentTrackUrl => _audioPlayerService.currentUrl;

  Future<void> playTrack(String filename, {String? trackName, String? trackArtist, String? url, bool skipRecentlyPlayed = false}) async {
    try {
      // Set track info
      _currentTrackName = trackName ?? filename;
      _currentTrackArtist = trackArtist;
      _currentTrackFilename = filename;
      notifyListeners();
      
      // Track in recently played immediately when song starts (unless skipped)
      if (!skipRecentlyPlayed && _recentlyPlayedService != null && trackName != null) {
        await _recentlyPlayedService!.addSong(
          id: filename,
          title: trackName,
          artist: trackArtist,
          filename: filename,
          url: url,
        );

        // Log to recommendation engine
        _recommendationService.logHistory(
          title: trackName,
          artist: trackArtist ?? 'Unknown',
          durationPlayed: 0.0,
        );
      }
      
      await _audioPlayerService.playFromBackend(filename);
      notifyListeners(); // Notify listeners to update UI

    } catch (e) {
      rethrow;
    }
  }

  // Play a playlist (track usage in recently played)
  Future<void> playPlaylist({required String playlistId, required String playlistName, String? coverUrl}) async {
    if (_recentlyPlayedService != null) {
      await _recentlyPlayedService!.addPlaylist(
        playlistId: playlistId,
        title: playlistName,
        thumbnail: coverUrl,
      );
    }
    // Note: Actual playlist playing (queueing) is handled by the UI calling QueueService
    // This method is just for tracking history
  }

  Future<void> streamTrack(String streamingUrl, {String? trackName, String? trackArtist, String? url, bool skipRecentlyPlayed = false}) async {
    try {
      // Set track info
      _currentTrackName = trackName ?? 'Streaming';
      _currentTrackArtist = trackArtist;
      _currentTrackFilename = null;
      notifyListeners();
      
      // Track in recently played immediately when song starts (unless skipped)
      if (!skipRecentlyPlayed && _recentlyPlayedService != null && trackName != null) {
        await _recentlyPlayedService!.addSong(
          id: streamingUrl,
          title: trackName,
          artist: trackArtist,
          url: url,
        );

        // Log to recommendation engine
        _recommendationService.logHistory(
          title: trackName,
          artist: trackArtist ?? 'Unknown',
          durationPlayed: 0.0,
        );
      }
      
      await _audioPlayerService.playFromUrl(streamingUrl);
      notifyListeners(); // Notify listeners to update UI

    } catch (e) {
      rethrow;
    }
  }
  
  // Preload a track URL
  Future<void> preloadTrackUrl(String url) async {
    await _audioPlayerService.preloadUrl(url);
  }
  
  // Preload a track from backend filename
  Future<void> preloadTrack(String filename) async {
    final encodedFilename = Uri.encodeComponent(filename);
    final url = '${AppConfig.apiBaseUrl}/downloads/$encodedFilename';
    await _audioPlayerService.preloadUrl(url);
  }

  Future<void> pause() async {
    await _audioPlayerService.pause();
    notifyListeners();
  }

  Future<void> resume() async {
    await _audioPlayerService.resume();
    notifyListeners();
  }

  Future<void> stop() async {
    await _audioPlayerService.stop();
    _currentTrackName = null;
    _currentTrackArtist = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _audioPlayerService.dispose();
    super.dispose();
  }
}

