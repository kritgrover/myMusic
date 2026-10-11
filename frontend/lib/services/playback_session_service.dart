import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../models/queue_item.dart';
import 'api_service.dart';
import 'auth_http_client.dart';
import 'player_state_service.dart';
import 'queue_service.dart';

class PlaybackSessionSnapshot {
  final Map<String, dynamic> queueSnapshot;
  final QueueItem? activeTrack;
  final Duration position;
  final Duration duration;
  final double volume;
  final Duration crossfadeDuration;
  const PlaybackSessionSnapshot(
      {required this.queueSnapshot,
      this.activeTrack,
      this.position = Duration.zero,
      this.duration = Duration.zero,
      this.volume = 1,
      this.crossfadeDuration = Duration.zero});

  Map<String, dynamic> toJson() => {
        'queue': queueSnapshot,
        'activeTrack': activeTrack == null
            ? null
            : QueueService.itemToSnapshot(activeTrack!),
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'volume': volume,
        'crossfadeMs': crossfadeDuration.inMilliseconds
      };
}

/// Persists one account's playback state. Loading only reads validated data;
/// the host prepares paused playback after checking its own lifecycle guards.
class PlaybackSessionService {
  static const int maxStoredCharacters = 2 * 1024 * 1024;
  static const int _maxDurationMs = 24 * 60 * 60 * 1000;
  static final Map<String, Future<void>> _pendingWrites = {};
  final int _userId;
  final QueueService _queue;
  final PlayerStateService _player;
  final AuthHttpClient _auth;
  final String _backend;
  final String _storageKey;
  final String _scope;
  final Future<SharedPreferences> Function() _preferencesProvider;
  final Duration saveInterval;
  Future<SharedPreferences>? _preferences;
  Future<void> _writes = Future.value();
  String? _lastError;
  bool _started = false;
  bool _disposed = false;
  bool _reading = false;
  bool _hasFlushed = false;
  Timer? _periodic;
  Timer? _debounce;
  StreamSubscription<double>? _volumeSubscription;

  PlaybackSessionService(
      {required int userId,
      required QueueService queue,
      required PlayerStateService player,
      AuthHttpClient? authClient,
      String? baseUrl,
      Future<SharedPreferences> Function()? preferencesProvider,
      this.saveInterval = const Duration(seconds: 5)})
      : _userId = userId,
        _queue = queue,
        _player = player,
        _auth = authClient ?? AuthHttpClient.shared,
        _scope = (authClient ?? AuthHttpClient.shared).cacheScope,
        _backend = _backendNamespace(baseUrl ?? AppConfig.apiBaseUrl),
        _storageKey = storageKeyFor(userId: userId, baseUrl: baseUrl),
        _preferencesProvider =
            preferencesProvider ?? SharedPreferences.getInstance {
    if (userId < 1) throw ArgumentError.value(userId, 'userId');
    if (saveInterval <= Duration.zero) {
      throw ArgumentError.value(saveInterval, 'saveInterval');
    }
  }

  static String _backendNamespace(String baseUrl) => sha256
      .convert(utf8.encode(baseUrl.replaceFirst(RegExp(r'/+$'), '')))
      .toString();
  static String storageKeyFor({required int userId, String? baseUrl}) =>
      'playback_session_v1_${_backendNamespace(baseUrl ?? AppConfig.apiBaseUrl)}_$userId';
  String? get lastError => _lastError;
  bool get _sameSession => _scope == _auth.cacheScope;
  Future<SharedPreferences> _prefs() async {
    try {
      return await (_preferences ??= _preferencesProvider());
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  static int _boundedTime(Object? value) => value is num && value.isFinite
      ? value.round().clamp(0, _maxDurationMs)
      : 0;
  static double _boundedVolume(Object? value) =>
      value is num && value.isFinite ? value.toDouble().clamp(0, 1) : 1;

  Future<PlaybackSessionSnapshot?> load() async {
    if (_disposed || !_sameSession) return null;
    _reading = true;
    try {
      // A manual flush followed by load sees the completed serialized write.
      await _writes;
      final preferences = await _prefs();
      await _pendingWrites[_storageKey];
      if (_disposed || !_sameSession) return null;
      final stored = preferences.getString(_storageKey);
      if (stored == null || stored.length > maxStoredCharacters) return null;
      final raw = jsonDecode(stored);
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['userId'] != _userId ||
          raw['backend'] != _backend) {
        return null;
      }
      final queue = QueueService.validateSnapshot(raw['queue']);
      if (queue == null) return null;
      final active = QueueService.itemFromSnapshot(raw['activeTrack']);
      final durationMs = _boundedTime(raw['durationMs']);
      final positionMs = _boundedTime(raw['positionMs']);
      final selected = queue['currentIndex'] as int;
      if (active != null && selected >= 0) {
        final queued = QueueService.itemFromSnapshot(
            (queue['entries'] as List)[selected]['item']);
        if (queued == null || !_sameMedia(queued, active)) {
          queue['currentIndex'] = -1;
        }
      }
      _lastError = null;
      return PlaybackSessionSnapshot(
          queueSnapshot: queue,
          activeTrack: active,
          position: Duration(
              milliseconds: durationMs > 0
                  ? positionMs.clamp(0, durationMs)
                  : positionMs),
          duration: Duration(milliseconds: durationMs),
          volume: _boundedVolume(raw['volume']),
          crossfadeDuration: Duration(
              milliseconds: _boundedTime(raw['crossfadeMs']).clamp(0, 12000)));
    } catch (_) {
      if (!_disposed && _sameSession) {
        _lastError = 'Could not restore the previous playback session.';
      }
      return null;
    } finally {
      _reading = false;
    }
  }

  static bool _sameMedia(QueueItem a, QueueItem b) {
    if ((a.filename ?? '').isNotEmpty && (b.filename ?? '').isNotEmpty) {
      return a.filename!.replaceAll('\\', '/') ==
          b.filename!.replaceAll('\\', '/');
    }
    if ((a.url ?? '').isNotEmpty &&
        (b.url ?? '').isNotEmpty &&
        QueueService.persistentReference(a.url) ==
            QueueService.persistentReference(b.url)) {
      return true;
    }
    final aSource =
        ApiService.youtubeSourceFromMediaUrl(a.url ?? '') ?? a.originalUrl;
    final bSource =
        ApiService.youtubeSourceFromMediaUrl(b.url ?? '') ?? b.originalUrl;
    if ((aSource ?? '').isNotEmpty && (bSource ?? '').isNotEmpty) {
      return QueueService.persistentReference(aSource) ==
          QueueService.persistentReference(bSource);
    }
    return a.id == b.id &&
        a.title == b.title &&
        a.artist == b.artist &&
        (a.url ?? '').isEmpty &&
        (b.url ?? '').isEmpty;
  }

  PlaybackSessionSnapshot? _capture() {
    if (_disposed || !_sameSession) return null;
    _player.audioPlayer.synchronizeTransitions();
    if (_disposed ||
        !_sameSession ||
        _queue.isTransitioning ||
        _player.isPreparing) {
      return null;
    }
    final queue = QueueService.validateSnapshot(_queue.exportSnapshot());
    if (queue == null) {
      _lastError = 'The playback queue is too large to save.';
      return null;
    }
    final selected = queue['currentIndex'] as int;
    final queued = selected < 0
        ? null
        : QueueService.itemFromSnapshot(
            (queue['entries'] as List)[selected]['item']);
    final track = _player.currentTrack;
    final currentUrl = _player.currentTrackUrl;
    QueueItem? active;
    if (track != null || currentUrl != null) {
      active = QueueService.itemFromSnapshot(QueueService.itemToSnapshot(
          QueueItem(
              id: track?.id ?? currentUrl ?? '',
              title: track?.title ?? _player.currentTrackName,
              artist: track?.artist ?? _player.currentTrackArtist,
              album: track?.album,
              filename: track?.filename,
              url: currentUrl,
              thumbnail: track?.thumbnail,
              originalUrl: track?.url ??
                  ApiService.youtubeSourceFromMediaUrl(currentUrl ?? ''))));
      if (active != null && queued != null && _sameMedia(queued, active)) {
        active = queued;
      } else {
        // Standalone playback must not resume an unrelated old queue selection.
        queue['currentIndex'] = -1;
      }
    } else {
      queue['currentIndex'] = -1;
    }
    final durationMs = active == null
        ? 0
        : _boundedTime(_player.audioPlayer.duration.inMilliseconds);
    final positionMs = active == null
        ? 0
        : _boundedTime(_player.audioPlayer.position.inMilliseconds);
    return PlaybackSessionSnapshot(
        queueSnapshot: queue,
        activeTrack: active,
        position: Duration(
            milliseconds:
                durationMs > 0 ? positionMs.clamp(0, durationMs) : positionMs),
        duration: Duration(milliseconds: durationMs),
        volume: _boundedVolume(_player.audioPlayer.volume),
        crossfadeDuration: _queue.crossfadeDuration);
  }

  void start() {
    if (_disposed || _started || !_sameSession) return;
    _started = true;
    _queue.addListener(_changed);
    _player.addListener(_changed);
    _volumeSubscription =
        _player.audioPlayer.volumeStream.listen((_) => _changed());
    _periodic = Timer.periodic(saveInterval, (_) {
      unawaited(flush());
    });
  }

  void _changed() {
    if (_disposed || !_sameSession) return;
    _debounce?.cancel();
    if (!_player.audioPlayer.isPlaying && !_queue.isTransitioning) {
      unawaited(flush());
    } else {
      _debounce = Timer(const Duration(milliseconds: 150), () {
        unawaited(flush());
      });
    }
  }

  Future<void> _write(PlaybackSessionSnapshot snapshot) {
    final encoded = jsonEncode({
      'version': 1,
      'userId': _userId,
      'backend': _backend,
      ...snapshot.toJson()
    });
    if (encoded.length > maxStoredCharacters) {
      _lastError = 'The playback session is too large to save.';
      return Future.value();
    }
    // Capture JSON before awaiting storage. Old writes always finish before
    // newer snapshots, and disposal never reads an already-disposed player.
    _writes =
        (_pendingWrites[_storageKey] ?? Future<void>.value()).then((_) async {
      try {
        if (!_sameSession) return;
        final preferences = await _prefs();
        if (!_sameSession) return;
        if (preferences.getString(_storageKey) == encoded) {
          _lastError = null;
          return;
        }
        if (!await preferences.setString(_storageKey, encoded)) {
          throw StateError('Storage rejected playback session');
        }
        _lastError = null;
      } catch (_) {
        if (_sameSession) _lastError = 'Could not save playback progress.';
      }
    });
    _pendingWrites[_storageKey] = _writes;
    final currentWrite = _writes;
    unawaited(currentWrite.then((_) {
      if (identical(_pendingWrites[_storageKey], currentWrite)) {
        _pendingWrites.remove(_storageKey);
      }
    }));
    return _writes;
  }

  Future<void> flush() {
    _debounce?.cancel();
    if (_reading && !_started) return _writes;
    final snapshot = _capture();
    if (snapshot != null) _hasFlushed = true;
    return snapshot == null ? _writes : _write(snapshot);
  }

  void dispose() {
    if (_disposed) return;
    final hasUserState = _queue.queueLength > 0 ||
        _player.currentTrack != null ||
        _player.currentTrackUrl != null;
    final snapshot =
        (_started || _hasFlushed || hasUserState) ? _capture() : null;
    _disposed = true;
    _periodic?.cancel();
    _debounce?.cancel();
    _volumeSubscription?.cancel();
    if (_started) {
      _queue.removeListener(_changed);
      _player.removeListener(_changed);
    }
    if (snapshot != null) unawaited(_write(snapshot));
  }
}
