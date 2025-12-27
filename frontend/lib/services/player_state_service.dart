import 'package:flutter/material.dart';
import 'dart:async';
import 'audio_player_service.dart';
import 'recently_played_service.dart';
import '../config.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  final RecentlyPlayedService? _recentlyPlayedService;
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
      }
      
      await _audioPlayerService.playFromBackend(filename);
    } catch (e) {
      rethrow;
    }
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
      }
      
      await _audioPlayerService.playFromUrl(streamingUrl);
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

