import 'dart:async';
import 'dart:math';
import 'api_service.dart';
import 'audio_player_service.dart';
import 'listening_event_store.dart';

class _ListeningOccurrence {
  final String id;
  final String title;
  final String artist;
  final String? source;
  final String? spotifyId;
  final String? audioIdentity;
  final String startedAt;
  int sequence = 0;
  int listenedMicroseconds = 0;
  int lastQueuedMicroseconds = 0;
  String? lastQueuedReason;
  double durationSeconds;
  _ListeningOccurrence(this.id, this.title, this.artist, this.source,
      this.spotifyId, this.audioIdentity, this.durationSeconds, this.startedAt);
}

/// Measures real elapsed playback, independently of the seekable media clock.
/// Each queue occurrence owns a cumulative, idempotent event. Pending payloads
/// are immutable and serialized so retries never race newer checkpoints.
class ListeningSessionService {
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
  final DateTime Function() _wallNow;
  final Future<ListeningEventStore> _store;
  final Map<String, Map<String, dynamic>> _pending = {};
  final Map<String, Map<String, dynamic>> _dirty = {};
  final Map<String, int> _persisted = {};
  final Duration checkpointInterval;
  final Duration sendTimeout;
  StreamSubscription<PlayerState>? _states;
  Timer? _timer;
  Future<void>? _sending;
  Future<void>? _disposing;
  Future<void>? _persisting;
  Future<void>? _loading;
  late final Future<void> ready;
  bool _loaded = false;
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
    DateTime Function()? wallNow,
    Future<ListeningEventStore>? store,
    this.checkpointInterval = const Duration(seconds: 5),
    this.sendTimeout = const Duration(seconds: 8),
  })  : _audio = audio,
        _sendEvent = sendEvent,
        _isSessionCurrent = isSessionCurrent ?? (() => true),
        _now = now ?? _monotonicClock(),
        _eventIdFactory = eventIdFactory ?? _newEventId,
        _wallNow = wallNow ?? DateTime.now,
        _store = store ?? Future.value(MemoryListeningEventStore()) {
    if (checkpointInterval <= Duration.zero) {
      throw ArgumentError.value(checkpointInterval, 'checkpointInterval');
    }
    if (sendTimeout <= Duration.zero) {
      throw ArgumentError.value(sendTimeout, 'sendTimeout');
    }
    _lastObserved = _now();
    _states = _audio.stateStream.listen(_onAudioState);
    _timer = Timer.periodic(checkpointInterval, (_) {
      unawaited(flush());
    });
    ready = _restore();
    unawaited(ready.then((_) => _drain()));
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
    // Credentials can be invalidated before the screen's dispose callback.
    // Capture the old occurrence into its immutable account store first.
    _observe();
    _enqueue('stopped', checkSession: false);
    _invalidated = true;
    _active = null;
    _eligible = false;
    _timer?.cancel();
    unawaited(_persist());
    return false;
  }

  Future<void> _restore({bool refresh = false}) {
    if (_loaded && !refresh) return Future.value();
    if (_loading != null) return _loading!;
    final work = Future<void>.microtask(() async {
      try {
        final events = await (await _store).read();
        for (final raw in events) {
          final event = validateStoredListeningEvent(raw);
          if (event == null) continue;
          final id = event['event_id'] as String;
          final sequence = event['sequence'] as int;
          final current = _pending[id];
          if (current == null || (current['sequence'] as int) < sequence) {
            _pending[id] = event;
            _dirty.remove(id);
          }
          _persisted[id] = max(_persisted[id] ?? 0, sequence);
        }
        _loaded = true;
      } catch (_) {
        _lastError = 'Could not restore listening history. It will retry.';
      }
    });
    _loading = work;
    return work.whenComplete(() {
      if (identical(_loading, work)) _loading = null;
    });
  }

  Future<void> _persist() {
    if (_persisting != null) return _persisting!;
    final work = Future<void>.microtask(() async {
      await _restore();
      if (!_loaded) return;
      try {
        final store = await _store;
        while (_dirty.isNotEmpty) {
          final id = _dirty.keys.first;
          final payload = _dirty[id]!;
          await store.put(payload);
          _persisted[id] = payload['sequence'] as int;
          if (identical(_dirty[id], payload)) _dirty.remove(id);
        }
      } catch (_) {
        _lastError =
            'Could not save listening history on this device. It will retry.';
      }
    });
    _persisting = work;
    return work.whenComplete(() {
      if (identical(_persisting, work)) _persisting = null;
    });
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
        _duration(_audio.duration),
        _wallNow().toUtc().toIso8601String());
    _lastObserved = _now();
    _eligible = _canCount;
    unawaited(_drain());
  }

  static void _validateReason(String reason) {
    if (!_reasons.contains(reason)) throw ArgumentError.value(reason, 'reason');
  }

  void _enqueue(String reason,
      {bool onlyIfAdvanced = false, bool checkSession = true}) {
    final active = _active;
    if (active == null || (checkSession && !_checkSession())) return;
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
      'started_at': active.startedAt,
    });
    _pending[active.id] = payload;
    _dirty[active.id] = payload;
    unawaited(_persist());
  }

  Future<void> _drain() {
    if (!_checkSession()) return Future.value();
    final sending = _sending;
    if (sending != null) return sending;
    // Deferring the body lets _sending be installed before a synchronous sender
    // callback can ask for another checkpoint.
    final next = Future<void>.microtask(() async {
      // A previous account session may finish a delayed checkpoint after this
      // service loaded. Reconcile once per delivery pass so that write does not
      // wait for another app restart. Never scan once per individual event.
      await _restore(refresh: true);
      await _persist();
      while (_pending.isNotEmpty && _checkSession()) {
        final id = _pending.keys.first;
        final payload = _pending[id]!;
        final sequence = payload['sequence'] as int;
        // Never put an event on the wire before its checkpoint is durable.
        if (_persisted[id] != sequence) {
          await _persist();
          if (_persisted[id] != sequence) return;
        }
        if (!_checkSession()) return;
        try {
          await _sendEvent(payload).timeout(sendTimeout);
          if (!_checkSession()) return;
          await (await _store).acknowledge(id, sequence);
          if (identical(_pending[id], payload)) {
            _pending.remove(id);
            _persisted.remove(id);
          }
          _lastError = null;
        } catch (_) {
          if (!_checkSession()) return;
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

  /// Save a checkpoint without waiting for connectivity (background/logout).
  Future<void> persistPending() {
    if (!_disposed && _checkSession()) {
      _observe();
      _enqueue(_eligible ? 'ongoing' : 'paused', onlyIfAdvanced: true);
    }
    return _persist();
  }

  Future<void> finish(String reason, {bool send = true}) {
    _validateReason(reason);
    if (_disposed || !_checkSession()) {
      return send ? (_sending ?? Future.value()) : _persist();
    }
    _observe();
    _enqueue(reason);
    _active = null;
    _eligible = false;
    return send ? _drain() : _persist();
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
    return _disposing = Future.wait([
      if (subscription != null) subscription.cancel(),
      _persist(),
      _drain(),
    ]).then((_) {});
  }
}
