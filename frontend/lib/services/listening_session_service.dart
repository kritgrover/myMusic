import 'dart:async';
import 'dart:math';
import 'api_service.dart';
import 'audio_player_service.dart';

class _ListeningOccurrence {
  final String id;
  final String title;
  final String artist;
  final String? source;
  final String? spotifyId;
  final String? audioIdentity;
  int sequence = 0;
  int listenedMicroseconds = 0;
  int lastQueuedMicroseconds = 0;
  String? lastQueuedReason;
  double durationSeconds;
  _ListeningOccurrence(this.id, this.title, this.artist, this.source,
      this.spotifyId, this.audioIdentity, this.durationSeconds);
}

/// Measures real elapsed playback, independently of the seekable media clock.
/// Each queue occurrence owns a cumulative, idempotent event. Pending payloads
/// are immutable and serialized so retries never race newer checkpoints.
class ListeningSessionService {
  static const maxPendingEvents = 32;
  static const _maxSeconds = 86400;
  static const _reasons = {
    'ongoing',
    'paused',
    'completed',
    'skipped',
    'stopped',
    'error'
  };
  final AudioPlayerService _audio;
  final Future<void> Function(Map<String, dynamic>) _sendEvent;
  final bool Function() _isSessionCurrent;
  final Duration Function() _now;
  final String Function() _eventIdFactory;
  final Map<String, Map<String, dynamic>> _pending = {};
  final Duration checkpointInterval;
  StreamSubscription<PlayerState>? _states;
  Timer? _timer;
  Future<void>? _sending;
  Future<void>? _disposing;
  _ListeningOccurrence? _active;
  late Duration _lastObserved;
  bool _eligible = false;
  bool _disposed = false;
  bool _invalidated = false;
  String? _lastError;

  ListeningSessionService({
    required AudioPlayerService audio,
    required Future<void> Function(Map<String, dynamic>) sendEvent,
    bool Function()? isSessionCurrent,
    Duration Function()? now,
    String Function()? eventIdFactory,
    this.checkpointInterval = const Duration(seconds: 5),
  })  : _audio = audio,
        _sendEvent = sendEvent,
        _isSessionCurrent = isSessionCurrent ?? (() => true),
        _now = now ?? _monotonicClock(),
        _eventIdFactory = eventIdFactory ?? _newEventId {
    if (checkpointInterval <= Duration.zero) {
      throw ArgumentError.value(checkpointInterval, 'checkpointInterval');
    }
    _lastObserved = _now();
    _states = _audio.stateStream.listen(_onAudioState);
    _timer = Timer.periodic(checkpointInterval, (_) {
      unawaited(flush());
    });
  }

  static Duration Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  static String _newEventId() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String? get lastError => _lastError;
  int get pendingEventCount => _pending.length;
  bool get hasActiveEvent => !_disposed && !_invalidated && _active != null;

  bool _checkSession() {
    if (_invalidated) return false;
    if (_isSessionCurrent()) return true;
    _invalidated = true;
    _active = null;
    _eligible = false;
    _pending.clear();
    _timer?.cancel();
    return false;
  }

  static String _text(String value, String fallback, int limit) {
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.isEmpty
        ? fallback
        : String.fromCharCodes(clean.runes.take(limit));
  }

  /// Only a canonical individual YouTube source is sent. Capabilities, artwork,
  /// local paths, arbitrary hosts, credentials, and tracking parameters vanish.
  static String? canonicalSourceUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return _canonicalSource(value);
    } on FormatException {
      return null;
    }
  }

  static String? _canonicalSource(String value) {
    final recovered = ApiService.youtubeSourceFromMediaUrl(value);
    if (recovered != null) return recovered;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        !const ['http', 'https'].contains(uri.scheme) ||
        (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80))) {
      return null;
    }
    String? id;
    if (uri.host == 'youtu.be' && uri.pathSegments.length == 1) {
      id = uri.pathSegments.single;
    } else if (const [
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com'
    ].contains(uri.host)) {
      if (uri.path == '/watch') {
        id = uri.queryParameters['v'];
      } else if (uri.pathSegments.length == 2 &&
          const ['shorts', 'embed', 'live'].contains(uri.pathSegments.first)) {
        id = uri.pathSegments.last;
      }
    }
    return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)
        ? 'https://www.youtube.com/watch?v=$id'
        : null;
  }

  static double _duration(Duration value) =>
      (value.inMicroseconds / 1000000).clamp(0, _maxSeconds).toDouble();

  bool get _canCount => _audio.isPlaying && !_audio.isBuffering;

  void _observe() {
    final current = _now();
    final elapsed = current - _lastObserved;
    final active = _active;
    if (active != null && _eligible && !elapsed.isNegative) {
      active.listenedMicroseconds =
          (active.listenedMicroseconds + elapsed.inMicroseconds)
              .clamp(0, _maxSeconds * 1000000);
    }
    _lastObserved = current;
    _eligible = active != null && _canCount;
    if (active != null &&
        active.durationSeconds == 0 &&
        active.audioIdentity == _audio.currentUrl) {
      active.durationSeconds = _duration(_audio.duration);
    }
  }

  void _onAudioState(PlayerState state) {
    if (_disposed || !_checkSession()) return;
    final wasEligible = _eligible;
    _observe();
    if (wasEligible && !_eligible && state == PlayerState.paused) {
      _enqueue('paused', onlyIfAdvanced: true);
      unawaited(_drain());
    }
  }

  void start({
    required String title,
    required String artist,
    String? sourceUrl,
    String? spotifyId,
    String previousEndReason = 'skipped',
  }) {
    if (_disposed || !_checkSession()) return;
    _validateReason(previousEndReason);
    final id = _eventIdFactory();
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'eventIdFactory', 'Invalid event ID');
    }
    _observe();
    if (_active != null) _enqueue(previousEndReason);
    _active = _ListeningOccurrence(
        id,
        _text(title, 'Unknown Track', 300),
        _text(artist, 'Unknown Artist', 300),
        canonicalSourceUrl(sourceUrl) ?? canonicalSourceUrl(_audio.currentUrl),
        spotifyId != null &&
                RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(spotifyId.trim())
            ? spotifyId.trim()
            : null,
        _audio.currentUrl,
        _duration(_audio.duration));
    _lastObserved = _now();
    _eligible = _canCount;
    unawaited(_drain());
  }

  static void _validateReason(String reason) {
    if (!_reasons.contains(reason)) throw ArgumentError.value(reason, 'reason');
  }

  void _enqueue(String reason, {bool onlyIfAdvanced = false}) {
    final active = _active;
    if (active == null || !_checkSession()) return;
    if (onlyIfAdvanced &&
        active.listenedMicroseconds <= active.lastQueuedMicroseconds &&
        !(reason == 'paused' &&
            active.listenedMicroseconds > 0 &&
            active.lastQueuedReason != 'paused')) {
      return;
    }
    active.lastQueuedMicroseconds = active.listenedMicroseconds;
    active.lastQueuedReason = reason;
    final payload = Map<String, dynamic>.unmodifiable({
      'event_id': active.id,
      'sequence': ++active.sequence,
      'song_title': active.title,
      'artist': active.artist,
      if (active.source != null) 'source_url': active.source,
      if (active.spotifyId != null) 'spotify_id': active.spotifyId,
      'duration_seconds': active.durationSeconds,
      'listened_seconds': active.listenedMicroseconds / 1000000,
      'end_reason': reason,
    });
    _pending[active.id] = payload;
    _boundPending();
  }

  void _boundPending() {
    while (_pending.length > maxPendingEvents) {
      _pending.remove(_pending.keys.first);
    }
  }

  Future<void> _drain() {
    if (!_checkSession()) return Future.value();
    final sending = _sending;
    if (sending != null) return sending;
    // Deferring the body lets _sending be installed before a synchronous sender
    // callback can ask for another checkpoint.
    final next = Future<void>.microtask(() async {
      while (_pending.isNotEmpty && _checkSession()) {
        final id = _pending.keys.first;
        final payload = _pending.remove(id)!;
        try {
          await _sendEvent(payload);
          if (!_checkSession()) return;
          _lastError = null;
        } catch (_) {
          if (!_checkSession()) return;
          final newer = _pending[id];
          if (newer == null ||
              (newer['sequence'] as int) < (payload['sequence'] as int)) {
            _pending[id] = payload;
          }
          _boundPending();
          _lastError =
              'Listening history will retry when the connection is available.';
          return;
        }
      }
    });
    _sending = next;
    return next.whenComplete(() {
      if (identical(_sending, next)) _sending = null;
    });
  }

  /// Capture progress and attempt pending delivery. No event is emitted before
  /// playback has advanced, and failed checkpoints keep the same event ID.
  Future<void> flush() {
    if (_disposed || !_checkSession()) return _sending ?? Future.value();
    _observe();
    _enqueue(_eligible ? 'ongoing' : 'paused', onlyIfAdvanced: true);
    return _drain();
  }

  Future<void> finish(String reason) {
    _validateReason(reason);
    if (_disposed || !_checkSession()) return _sending ?? Future.value();
    _observe();
    _enqueue(reason);
    _active = null;
    _eligible = false;
    return _drain();
  }

  Future<void> dispose() {
    if (_disposing != null) return _disposing!;
    if (!_disposed && _checkSession()) {
      _observe();
      _enqueue('stopped');
    }
    _disposed = true;
    _active = null;
    _eligible = false;
    _timer?.cancel();
    final subscription = _states;
    _states = null;
    return _disposing =
        Future.wait([if (subscription != null) subscription.cancel(), _drain()])
            .then((_) => _pending.clear());
  }
}
