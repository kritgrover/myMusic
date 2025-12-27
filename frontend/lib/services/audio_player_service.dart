import 'package:just_audio/just_audio.dart';
import '../config.dart';

// Player state enum for compatibility
enum PlayerState {
  stopped,
  playing,
  paused,
  buffering,
}

class AudioPlayerService {
  AudioPlayer _audioPlayer = AudioPlayer();
  AudioPlayer _preloadPlayer = AudioPlayer();
  String? _currentUrl;
  String? _preloadedUrl;
  
  AudioPlayer get player => _audioPlayer;
  
  AudioPlayerService() {
  }
  
  Future<void> playFromUrl(String url) async {
    try {
      _currentUrl = url;
      
      // If this URL is already preloaded, load from cache
      if (_preloadedUrl == url) {
        final preloadState = _preloadPlayer.processingState;
        // If preload is ready, load from cache
        if (preloadState == ProcessingState.ready) {
          // Clear preload and stop the player
          _preloadedUrl = null;
          _preloadPlayer.stop().catchError((_) {});
        }
      }
      
      await _audioPlayer.setUrl(url);
      await _audioPlayer.play();
    } catch (e) {
      throw Exception('Failed to play audio: $e');
    }
  }
  
  // Preload the next song URL
  Future<void> preloadUrl(String url) async {
    try {
      // Don't preload if it's the same as current or already preloaded
      if (url == _currentUrl || url == _preloadedUrl) {
        return;
      }
      
      // Clear any existing preload
      if (_preloadedUrl != null) {
        try {
          await _preloadPlayer.stop();
        } catch (e) {
          // Ignore errors
        }
      }
      
      _preloadedUrl = url;
      // Preload the URL - setUrl() starts loading in the background
      await _preloadPlayer.setUrl(url);
    } catch (e) {
      // Silently fail preloading - it's not critical
      _preloadedUrl = null;
    }
  }
  
  // Clear preloaded song
  Future<void> clearPreload() async {
    _preloadedUrl = null;
    try {
      await _preloadPlayer.stop();
    } catch (e) {
      // Ignore errors
    }
  }
  
  String? get preloadedUrl => _preloadedUrl;
  
  Future<void> playFromFile(String filePath) async {
    try {
      // For URLs, use playFromUrl
      if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
        await playFromUrl(filePath);
        return;
      }
      
      // For local files, we'll serve them via the backend
      // Convert to backend URL
      final encodedFilename = Uri.encodeComponent(filePath);
      final url = '${AppConfig.apiBaseUrl}/downloads/$encodedFilename';
      await playFromUrl(url);
    } catch (e) {
      throw Exception('Failed to play file: $e');
    }
  }
  
  Future<void> playFromBackend(String filename) async {
    // Play from backend server
    final encodedFilename = Uri.encodeComponent(filename);
    final url = '${AppConfig.apiBaseUrl}/downloads/$encodedFilename';
    await playFromUrl(url);
  }
  
  Future<void> pause() async {
    await _audioPlayer.pause();
  }
  
  Future<void> resume() async {
    await _audioPlayer.play();
  }
  
  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentUrl = null;
  }
  
  Future<void> seek(Duration position) async {
    try {
      await _audioPlayer.seek(position);
    } catch (e) {
      // Ignore seek errors
    }
  }
  
  bool get isPlaying => _audioPlayer.playing;
  Duration get duration => _audioPlayer.duration ?? Duration.zero;
  Duration get position => _audioPlayer.position;
  String? get currentUrl => _currentUrl;
  
  // Streams for listening to changes
  Stream<Duration> get positionStream => _audioPlayer.positionStream;
  Stream<Duration?> get durationStream => _audioPlayer.durationStream;
  
  // Map just_audio's player state to our PlayerState enum
  Stream<PlayerState> get stateStream => _audioPlayer.playerStateStream.map((state) {
    if (state.playing) {
      return PlayerState.playing;
    }
    if (state.processingState == ProcessingState.loading || 
        state.processingState == ProcessingState.buffering) {
      return PlayerState.buffering;
    }
    if (state.processingState == ProcessingState.ready) {
      return PlayerState.paused;
    }
    return PlayerState.stopped;
  });

  // Stream that emits when a song completes
  // This stream always listens to the current main player
  Stream<void> get completionStream {
    // Create a stream that listens to the current player
    return _audioPlayer.playerStateStream
        .where((state) => state.processingState == ProcessingState.completed)
        .map((_) => null);
  }
  
  // Get buffering state
  bool get isBuffering {
    final state = _audioPlayer.playerState;
    return state.processingState == ProcessingState.loading || 
           state.processingState == ProcessingState.buffering;
  }
  
  void dispose() {
    _audioPlayer.dispose();
    _preloadPlayer.dispose();
  }
}
