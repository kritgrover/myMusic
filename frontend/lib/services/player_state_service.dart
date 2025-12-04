import 'package:flutter/material.dart';
import 'dart:async';
import 'audio_player_service.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  String? _currentTrackName;
  StreamSubscription? _stateSubscription;

  PlayerStateService() {
    // Listen to player state changes to update UI
    _stateSubscription = _audioPlayerService.stateStream.listen((_) {
      notifyListeners();
    });
  }

  AudioPlayerService get audioPlayer => _audioPlayerService;

  String? get currentTrackName => _currentTrackName;
  String? get currentTrackUrl => _audioPlayerService.currentUrl;

  Future<void> playTrack(String filename, {String? trackName}) async {
    try {
      await _audioPlayerService.playFromBackend(filename);
      _currentTrackName = trackName ?? filename;
      notifyListeners();
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
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _audioPlayerService.dispose();
    super.dispose();
  }
}

