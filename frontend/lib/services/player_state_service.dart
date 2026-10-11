import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_player_service.dart';
import 'api_service.dart';
import 'recently_played_service.dart';
import 'recommendation_service.dart';
import 'listening_session_service.dart';
import 'media_exceptions.dart';
import '../config.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';

class PlayerStateService extends ChangeNotifier {
  final AudioPlayerService _audioPlayerService;
  final RecentlyPlayedService? _recentlyPlayedService;
  final RecommendationService _recommendationService;
  late final ListeningSessionService _listening;
  String? _currentTrackName;
  String? _currentTrackArtist;
  PlaylistTrack? _currentTrack;
  String? _playbackError;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _errorSubscription;
  StreamSubscription? _completionSubscription;
  bool _disposed = false;
  int _playRequest = 0;
  bool _isPreparing = false;
  QueueItem? _restoredItem;
  Future<String?> Function(QueueItem)? _restoredLoader;

  PlayerStateService({
    AudioPlayerService? audioPlayerService,
    RecentlyPlayedService? recentlyPlayedService,
    RecommendationService? recommendationService,
    ListeningSessionService? listeningSessionService,
  })  : _audioPlayerService = audioPlayerService ?? AudioPlayerService(),
        _recentlyPlayedService = recentlyPlayedService,
        _recommendationService =
            recommendationService ?? RecommendationService() {
    final listeningScope = _recommendationService.sessionScope;
    _listening = listeningSessionService ??
        ListeningSessionService(
            audio: _audioPlayerService,
            sendEvent: _recommendationService.recordListeningEvent,
            isSessionCurrent: () =>
                _recommendationService.sessionScope == listeningScope);
    _stateSubscription = _audioPlayerService.stateStream.listen((_) {
      if (!_disposed) notifyListeners();
    });
    _errorSubscription = _audioPlayerService.errorStream.listen((error) {
      unawaited(_listening.finish('error'));
      _playbackError = error;
      if (!_disposed) notifyListeners();
    });
    _completionSubscription = _audioPlayerService.completionStream.listen((_) {
      unawaited(_listening.finish('completed'));
    });
  }

  AudioPlayerService get audioPlayer => _audioPlayerService;
  String? get currentTrackName => _currentTrackName;
  String? get currentTrackArtist => _currentTrackArtist;
  PlaylistTrack? get currentTrack => _currentTrack;
  String? get currentTrackUrl => _audioPlayerService.currentUrl;
  String? get playbackError => _playbackError;
  bool get isPreparing => _isPreparing;
  Future<void> flushListeningHistory() => _listening.flush();

  Future<void> finishListeningSession() async {
    await _audioPlayerService.pause();
    await _listening.finish('stopped');
  }

  /// Audio already changed decks on its scheduling clock. Adopt its metadata
  /// without loading or starting the song a second time.
  void adoptScheduledTrack(QueueItem item, {bool skipRecentlyPlayed = false}) {
    if (_disposed) return;
    ++_playRequest;
    _isPreparing = false;
    _restoredItem = null;
    _restoredLoader = null;
    _playbackError = null;
    _currentTrackName = item.displayTitle;
    _currentTrackArtist = item.artist;
    final source = item.originalUrl ??
        ApiService.youtubeSourceFromMediaUrl(currentTrackUrl ?? '');
    _currentTrack = PlaylistTrack(
        id: ApiService.canonicalMediaUrl(item.id),
        title: item.displayTitle,
        artist: item.artist,
        album: item.album,
        filename: item.filename ?? '',
        url: source,
        thumbnail: item.thumbnail,
        duration: _audioPlayerService.duration.inMilliseconds / 1000);
    _listening.start(
        title: item.displayTitle,
        artist: item.artist ?? 'Unknown',
        sourceUrl: source,
        previousEndReason: 'completed');
    notifyListeners();
    unawaited(_recordPlayback(
        id: item.id,
        title: item.displayTitle,
        artist: item.artist,
        filename: item.filename,
        originalUrl: source,
        skipRecentlyPlayed: skipRecentlyPlayed));
  }

  Future<void> preparePaused(QueueItem item,
      {Duration position = Duration.zero,
      Duration duration = Duration.zero,
      double volume = 1,
      Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    ++_playRequest;
    unawaited(_listening.finish('stopped'));
    _isPreparing = false;
    _restoredItem = item;
    _restoredLoader = loadStreamingUrl;
    final filename = item.filename;
    final mediaUrl = filename != null && filename.isNotEmpty
        ? '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(filename)}'
        : item.url;
    _currentTrackName = item.displayTitle;
    _currentTrackArtist = item.artist;
    _currentTrack = PlaylistTrack(
      id: ApiService.canonicalMediaUrl(item.id),
      title: item.displayTitle,
      artist: item.artist,
      album: item.album,
      filename: filename ?? '',
      url: item.originalUrl,
      thumbnail: item.thumbnail,
      duration: duration.inMilliseconds / 1000,
    );
    _playbackError = null;
    _audioPlayerService.restorePaused(mediaUrl,
        position: position, duration: duration);
    if (!_disposed) notifyListeners();
    await _audioPlayerService.setVolume(volume);
  }

  void cancelPendingPlayback() {
    ++_playRequest;
    _isPreparing = false;
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
    _isPreparing = true;
    _playbackError = null;
    if (!_disposed) notifyListeners();
    var recoveredDownload = false;
    try {
      try {
        await start();
      } on DownloadUnavailableException {
        if (_disposed || request != _playRequest) return;
        final fallback = _downloadFallback(originalUrl);
        if (fallback == null) rethrow;
        await _audioPlayerService.playFromUrl(fallback);
        recoveredDownload = true;
      }
      if (_disposed || request != _playRequest) return;
      _restoredItem = null;
      _restoredLoader = null;
      // Metadata and history describe successfully loaded audio, never a track
      // whose URL failed to load. Persistence cannot delay playback startup.
      _currentTrackName = trackName;
      _currentTrackArtist = trackArtist;
      final source = originalUrl ??
          ApiService.youtubeSourceFromMediaUrl(
              _audioPlayerService.currentUrl ?? id);
      _currentTrack = PlaylistTrack(
        id: ApiService.canonicalMediaUrl(id),
        title: trackName,
        artist: trackArtist,
        filename: recoveredDownload ? '' : filename ?? '',
        url: source == null ? null : ApiService.canonicalMediaUrl(source),
      );
      _listening.start(
          title: trackName,
          artist: trackArtist ?? 'Unknown',
          sourceUrl: source);
      notifyListeners();
      unawaited(_recordPlayback(
        id: id,
        title: trackName,
        artist: trackArtist,
        filename: recoveredDownload ? null : filename,
        originalUrl: source,
        skipRecentlyPlayed: skipRecentlyPlayed,
      ));
    } catch (error) {
      if (!_disposed && request == _playRequest) {
        if (!_audioPlayerService.isPlaying) {
          unawaited(_listening.finish('error'));
        }
        _playbackError = error.toString();
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!_disposed && request == _playRequest) {
        _isPreparing = false;
        notifyListeners();
      }
    }
  }

  static String? _downloadFallback(String? originalUrl) {
    final source = ApiService.canonicalYouTubeSource(originalUrl);
    return source == null
        ? null
        : '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(source)}';
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
          id: ApiService.canonicalMediaUrl(id),
          title: title,
          artist: artist,
          filename: filename,
          url: originalUrl == null
              ? null
              : ApiService.canonicalMediaUrl(originalUrl),
        );
      }
    } catch (error) {
      debugPrint('Could not save recently played: $error');
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
    final request = ++_playRequest;
    _playbackError = null;
    var restored = _restoredItem;
    _isPreparing = true;
    if (!_disposed) notifyListeners();
    try {
      if (restored != null && _audioPlayerService.currentUrl == null) {
        final source = await _restoredLoader?.call(restored);
        if (_disposed || request != _playRequest) return;
        if (source == null || source.isEmpty) {
          throw StateError('Could not find audio for this track. Try again.');
        }
        _audioPlayerService.restorePaused(source,
            position: _audioPlayerService.position,
            duration: _audioPlayerService.duration);
      }
      try {
        await _audioPlayerService.resume();
      } on DownloadUnavailableException {
        if (_disposed || request != _playRequest) return;
        final fallback =
            _downloadFallback(restored?.originalUrl ?? _currentTrack?.url);
        if (fallback == null) rethrow;
        final savedPosition = _audioPlayerService.position;
        final savedDuration = _audioPlayerService.duration;
        _audioPlayerService.restorePaused(fallback,
            position: savedPosition, duration: savedDuration);
        // The file is confirmed missing even if the streaming retry fails.
        // Keep the new source for subsequent resumes and saved sessions.
        restored =
            restored?.copyWithStreamingUrl(fallback, clearFilename: true);
        _restoredItem = restored;
        final track = _currentTrack;
        if (track != null) {
          _currentTrack = PlaylistTrack(
              id: track.id,
              title: track.title,
              artist: track.artist,
              album: track.album,
              filename: '',
              url: track.url,
              thumbnail: track.thumbnail,
              duration: track.duration);
        }
        await _audioPlayerService.resume();
        if (_disposed || request != _playRequest) return;
      }
      if (_disposed || request != _playRequest) return;
      if (!_listening.hasActiveEvent && _currentTrack != null) {
        _listening.start(
            title: _currentTrack!.title,
            artist: _currentTrack!.artist ?? 'Unknown',
            sourceUrl: _currentTrack!.url ??
                ApiService.youtubeSourceFromMediaUrl(currentTrackUrl ?? ''));
      }
      if (restored != null) {
        _restoredItem = null;
        _restoredLoader = null;
        unawaited(_recordPlayback(
            id: restored.id,
            title: restored.displayTitle,
            artist: restored.artist,
            filename: restored.filename,
            originalUrl: restored.originalUrl,
            skipRecentlyPlayed: false));
      }
      notifyListeners();
    } catch (error) {
      if (!_disposed && request == _playRequest) {
        _playbackError = 'Could not resume this track. Please try again.';
        notifyListeners();
      }
      rethrow;
    } finally {
      if (!_disposed && request == _playRequest) {
        _isPreparing = false;
        notifyListeners();
      }
    }
  }

  Future<void> stop() async {
    ++_playRequest;
    _isPreparing = false;
    await _audioPlayerService.stop();
    unawaited(_listening.finish('stopped'));
    _currentTrackName = null;
    _restoredItem = null;
    _restoredLoader = null;
    _currentTrack = null;
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
    _completionSubscription?.cancel();
    unawaited(_listening.dispose());
    _audioPlayerService.dispose();
    super.dispose();
  }
}
