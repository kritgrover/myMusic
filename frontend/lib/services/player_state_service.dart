import 'package:flutter/material.dart';
import 'dart:async';
import 'audio_player_service.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  String? _currentTrackName;
  String? _currentTrackArtist;
  StreamSubscription? _stateSubscription;

  PlayerStateService() {
    // Listen to player state changes to update UI
    _stateSubscription = _audioPlayerService.stateStream.listen((_) {
      notifyListeners();
    });
  }

  AudioPlayerService get audioPlayer => _audioPlayerService;

  String? get currentTrackName => _currentTrackName;
  String? get currentTrackArtist => _currentTrackArtist;
  String? get currentTrackUrl => _audioPlayerService.currentUrl;

  Future<void> playTrack(String filename, {String? trackName, String? trackArtist}) async {
    try {
      // Set track info
      _currentTrackName = trackName ?? filename;
      _currentTrackArtist = trackArtist;
      notifyListeners();
      await _audioPlayerService.playFromBackend(filename);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> streamTrack(String streamingUrl, {String? trackName, String? trackArtist}) async {
    try {
      // Set track info
      _currentTrackName = trackName ?? 'Streaming';
      _currentTrackArtist = trackArtist;
      notifyListeners();
      await _audioPlayerService.playFromUrl(streamingUrl);
    } catch (e) {
      rethrow;
    }
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

