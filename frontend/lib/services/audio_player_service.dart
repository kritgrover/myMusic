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
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _preloadPlayer = AudioPlayer();
  String? _currentUrl;
  String? _preloadedUrl;
  bool _isPreloadedReady = false;
  
  AudioPlayer get player => _audioPlayer;
  
  AudioPlayerService() {
    // Listen to preload player state to know when it's ready
    _preloadPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.ready && _preloadedUrl != null) {
        _isPreloadedReady = true;
      }
    });
  }
  
  Future<void> playFromUrl(String url) async {
    try {
      _currentUrl = url;
      
      // If this URL was preloaded, the OS/network cache should make it load faster
      // Clear preload state since we're now playing it
      if (_preloadedUrl == url) {
        _preloadedUrl = null;
        _isPreloadedReady = false;
        _preloadPlayer.stop();
      }
      
      // Set the URL source (should be faster if it was preloaded due to cache)
      await _audioPlayer.setUrl(url);
      // Start playing
      await _audioPlayer.play();
    } catch (e) {
      throw Exception('Failed to play audio: $e');
    }
  }
  
  // Preload a URL in the background without playing it
  Future<void> preloadUrl(String url) async {
    try {
      // Don't preload if it's already the current URL or already preloaded
      if (url == _currentUrl || url == _preloadedUrl) {
        return;
      }
      
      _preloadedUrl = url;
      _isPreloadedReady = false;
      // Preload the URL (this will start downloading/buffering)
      await _preloadPlayer.setUrl(url);
      // Don't call play() - just let it buffer in the background
    } catch (e) {
      // Silently fail preloading - it's not critical
      _preloadedUrl = null;
      _isPreloadedReady = false;
    }
  }
  
  // Clear preloaded song
  void clearPreload() {
    _preloadedUrl = null;
    _isPreloadedReady = false;
    _preloadPlayer.stop();
  }
  
  String? get preloadedUrl => _preloadedUrl;
  bool get isPreloadedReady => _isPreloadedReady;
  
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
  Stream<void> get completionStream => _audioPlayer.playerStateStream
      .where((state) => state.processingState == ProcessingState.completed)
      .map((_) => null);
  
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
