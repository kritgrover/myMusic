import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_player_service.dart';
import 'recently_played_service.dart';
import 'recommendation_service.dart';
import '../config.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService;
  final RecentlyPlayedService? _recentlyPlayedService;
  final RecommendationService _recommendationService;
  String? _currentTrackName;
  String? _currentTrackArtist;
  String? _playbackError;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _errorSubscription;
  bool _disposed = false;
  int _playRequest = 0;

  PlayerStateService({
    AudioPlayerService? audioPlayerService,
    RecentlyPlayedService? recentlyPlayedService,
    RecommendationService? recommendationService,
  })  : _audioPlayerService = audioPlayerService ?? AudioPlayerService(),
        _recentlyPlayedService = recentlyPlayedService,
        _recommendationService =
            recommendationService ?? RecommendationService() {
    _stateSubscription = _audioPlayerService.stateStream.listen((_) {
      if (!_disposed) notifyListeners();
    });
    _errorSubscription = _audioPlayerService.errorStream.listen((error) {
      _playbackError = error;
      if (!_disposed) notifyListeners();
    });
  }

  AudioPlayerService get audioPlayer => _audioPlayerService;
  String? get currentTrackName => _currentTrackName;
  String? get currentTrackArtist => _currentTrackArtist;
  String? get currentTrackUrl => _audioPlayerService.currentUrl;
  String? get playbackError => _playbackError;

  void cancelPendingPlayback() {
    ++_playRequest;
    _audioPlayerService.cancelPendingPlayback();
  }

  Future<void> playTrack(
    String filename, {
    String? trackName,
    String? trackArtist,
    String? url,
    bool skipRecentlyPlayed = false,
  }) =>
      _play(
        start: () => _audioPlayerService.playFromBackend(filename),
        id: filename,
        trackName: trackName ?? filename,
        trackArtist: trackArtist,
        filename: filename,
        originalUrl: url,
        skipRecentlyPlayed: skipRecentlyPlayed,
      );

  Future<void> streamTrack(
    String streamingUrl, {
    String? trackName,
    String? trackArtist,
    String? url,
    bool skipRecentlyPlayed = false,
  }) =>
      _play(
        start: () => _audioPlayerService.playFromUrl(streamingUrl),
        id: url ?? streamingUrl,
        trackName: trackName ?? 'Streaming',
        trackArtist: trackArtist,
        originalUrl: url,
        skipRecentlyPlayed: skipRecentlyPlayed,
      );

  Future<void> _play({
    required Future<void> Function() start,
    required String id,
    required String trackName,
    String? trackArtist,
    String? filename,
    String? originalUrl,
    required bool skipRecentlyPlayed,
  }) async {
    final request = ++_playRequest;
    _playbackError = null;
    try {
      await start();
      if (_disposed || request != _playRequest) return;
      // Metadata and history describe successfully loaded audio, never a track
      // whose URL failed to load. Persistence cannot delay playback startup.
      _currentTrackName = trackName;
      _currentTrackArtist = trackArtist;
      notifyListeners();
      unawaited(_recordPlayback(
        id: id,
        title: trackName,
        artist: trackArtist,
        filename: filename,
        originalUrl: originalUrl,
        skipRecentlyPlayed: skipRecentlyPlayed,
      ));
    } catch (error) {
      if (!_disposed && request == _playRequest) {
        _playbackError = error.toString();
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> _recordPlayback({
    required String id,
    required String title,
    String? artist,
    String? filename,
    String? originalUrl,
    required bool skipRecentlyPlayed,
  }) async {
    // History failures should never turn successful audio playback into an error.
    try {
      if (!skipRecentlyPlayed && _recentlyPlayedService != null) {
        await _recentlyPlayedService!.addSong(
          id: id,
          title: title,
          artist: artist,
          filename: filename,
          url: originalUrl,
        );
      }
    } catch (error) {
      debugPrint('Could not save recently played: $error');
    }
    try {
      await _recommendationService.logHistory(
        title: title,
        artist: artist ?? 'Unknown',
        durationPlayed: 0.0,
      );
    } catch (error) {
      debugPrint('Could not save listening history: $error');
    }
  }

  Future<void> playPlaylist(
      {required String playlistId,
      required String playlistName,
      String? coverUrl}) async {
    await _recentlyPlayedService?.addPlaylist(
      playlistId: playlistId,
      title: playlistName,
      thumbnail: coverUrl,
    );
  }

  Future<void> preloadTrackUrl(String url) =>
      _audioPlayerService.preloadUrl(url);

  Future<void> preloadTrack(String filename) {
    final encodedFilename = Uri.encodeComponent(filename);
    return _audioPlayerService
        .preloadUrl('${AppConfig.apiBaseUrl}/downloads/$encodedFilename');
  }

  Future<void> pause() async {
    await _audioPlayerService.pause();
    if (!_disposed) notifyListeners();
  }

  Future<void> resume() async {
    _playbackError = null;
    await _audioPlayerService.resume();
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    ++_playRequest;
    await _audioPlayerService.stop();
    _currentTrackName = null;
    _currentTrackArtist = null;
    _playbackError = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_playRequest;
    _stateSubscription?.cancel();
    _errorSubscription?.cancel();
    _audioPlayerService.dispose();
    super.dispose();
  }
}
