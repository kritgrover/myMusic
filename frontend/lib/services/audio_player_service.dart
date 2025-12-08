import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import '../config.dart';

class AudioPlayerService {
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentUrl;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _pausedAt; // Position when paused
  
  AudioPlayer get player => _audioPlayer;
  
  AudioPlayerService() {
    _audioPlayer.onDurationChanged.listen((duration) {
      _duration = duration;
    });
    
    _audioPlayer.onPositionChanged.listen((position) {
      _position = position;
    });
    
    _audioPlayer.onPlayerStateChanged.listen((state) {
      _isPlaying = state == PlayerState.playing;
    });
  }
  
  Future<void> playFromUrl(String url) async {
    try {
      // Stop any currently playing audio first
      if (_audioPlayer.state == PlayerState.playing || _audioPlayer.state == PlayerState.paused) {
        await _audioPlayer.stop();
      }
      _currentUrl = url;
      _pausedAt = null; // Clear paused position when starting a new track
      // Play the audio - this should automatically start playback
      await _audioPlayer.play(UrlSource(url));
    } catch (e) {
      throw Exception('Failed to play audio: $e');
    }
  }
  
  Future<void> playFromFile(String filePath) async {
    try {
      // For local files, we need to use FileSource
      // But first, we need to check if it's a local path or URL
      if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
        await playFromUrl(filePath);
      } else {
        // For local files, we'll need to serve them via the backend
        // Or use FileSource if the file is accessible
        final file = File(filePath);
        if (await file.exists()) {
          await _audioPlayer.play(DeviceFileSource(filePath));
        } else {
          throw Exception('File not found: $filePath');
        }
      }
      _currentUrl = filePath;
    } catch (e) {
      throw Exception('Failed to play file: $e');
    }
  }
  
  Future<void> playFromBackend(String filename) async {
    // Play from backend server
    // URL encode the filename to handle special characters
    final encodedFilename = Uri.encodeComponent(filename);
    final url = '${AppConfig.apiBaseUrl}/downloads/$encodedFilename';
    // Stop any currently playing audio first
    if (_audioPlayer.state == PlayerState.playing || _audioPlayer.state == PlayerState.paused) {
      await _audioPlayer.stop();
    }
    await playFromUrl(url);
  }
  
  Future<void> pause() async {
    if (_audioPlayer.state == PlayerState.playing) {
      // Store current position before pausing
      _pausedAt = _position;
      await _audioPlayer.pause();
    }
  }
  
  Future<void> resume() async {
    if (_audioPlayer.state == PlayerState.paused) {
      // Resume from paused state
      await _audioPlayer.resume();
    } else if (_audioPlayer.state == PlayerState.stopped && _currentUrl != null) {
      // If stopped, restart from last position or beginning
      final resumePosition = _pausedAt ?? _position;
      await _audioPlayer.play(UrlSource(_currentUrl!), position: resumePosition);
      // Clear paused position after resuming
      _pausedAt = null;
    }
  }
  
  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentUrl = null;
    _pausedAt = null;
  }
  
  Future<void> seek(Duration position) async {
    // Only seek if we have a valid source
    if (_currentUrl == null) return;
    
    // If player is stopped, we need to play from the current URL at the seek position
    if (_audioPlayer.state == PlayerState.stopped) {
      await _audioPlayer.play(UrlSource(_currentUrl!), position: position);
    } else {
      // Seek to the new position - this should maintain playing state automatically
      await _audioPlayer.seek(position);
      // Update paused position if we're paused, so resume uses the new position
      if (_audioPlayer.state == PlayerState.paused) {
        _pausedAt = position;
      }
    }
  }
  
  bool get isPlaying => _isPlaying;
  Duration get duration => _duration;
  Duration get position => _position;
  String? get currentUrl => _currentUrl;
  
  Stream<Duration> get positionStream => _audioPlayer.onPositionChanged;
  Stream<Duration> get durationStream => _audioPlayer.onDurationChanged;
  Stream<PlayerState> get stateStream => _audioPlayer.onPlayerStateChanged;
  
  void dispose() {
    _audioPlayer.dispose();
  }
}

