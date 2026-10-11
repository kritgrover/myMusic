import 'dart:async';
import 'dart:math' as math;
import 'package:just_audio/just_audio.dart';
import '../config.dart';
import 'api_service.dart';
import 'media_exceptions.dart';
import 'scheduled_audio_engine.dart';
import 'scheduled_audio_factory.dart';

typedef MediaUrlResolver = Future<String> Function(String canonicalUrl);

enum PlayerState { stopped, playing, paused, buffering }

class _PreparedNext {
  final String canonical;
  final Object token;
  final Duration crossfade;
  final Object sourceTag = Object();
  AudioPlayer? deck;
  bool ready = false;
  _PreparedNext(this.canonical, this.token, this.crossfade);
}

/// One logical player, independent of the physical deck playing its audio.
/// Canonical references live here; capabilities exist only in loaded sources.
class AudioPlayerService {
  final AudioPlayer _first;
  final AudioPlayer _second;
  late AudioPlayer _active;
  final MediaUrlResolver _resolveMediaUrl;
  final ScheduledAudioEngine? _scheduled;
  final _errors = StreamController<String>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _states = StreamController<PlayerState>.broadcast();
  final _volumes = StreamController<double>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _handoffs = StreamController<Object>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<AudioPlayer, ConcatenatingAudioSource> _playlists = {};
  Future<void> _nativeMutations = Future.value();
  Future<void> _stageCleanup = Future.value();
  bool _mutatingPlaylist = false;
  bool _usingScheduled = false;
  bool _disposed = false;
  bool _completed = false;
  bool _synchronizing = false;
  int _handoffRevision = 0;
  int _playRequest = 0;
  int _preloadRequest = 0;
  int? _loadingRequest;
  AudioPlayer? _completionDuringMutation;
  final Set<String> _progressiveSources = {};
  String? _currentUrl;
  String? _preloadedUrl;
  _PreparedNext? _next;
  AudioPlayer? _outgoing;
  Timer? _transitionTimer;
  Stopwatch? _fadeClock;
  Duration _fadeLength = Duration.zero;
  Completer<void>? _fadeFinished;
  double _volume = 1;
  bool _restored = false;
  Duration _restoredPosition = Duration.zero;
  Duration _restoredDuration = Duration.zero;
  Future<void>? _restoreStop;

  AudioPlayerService(
      {AudioPlayer? player,
      AudioPlayer? preloadPlayer,
      MediaUrlResolver? mediaUrlResolver,
      ScheduledAudioEngine? scheduledEngine,
      bool useScheduledEngine = true})
      : _first = player ?? AudioPlayer(),
        _second = preloadPlayer ?? AudioPlayer(),
        _resolveMediaUrl = mediaUrlResolver ?? ApiService().authorizeMediaUrl,
        _scheduled = scheduledEngine ??
            (useScheduledEngine ? createScheduledAudioEngine() : null) {
    _active = _first;
    _volume = _active.volume;
    _listenToDeck(_first);
    _listenToDeck(_second);
    final engine = _scheduled;
    if (engine != null) {
      _subscriptions.addAll([
        engine.positionStream.listen((_) {
          if (_usingScheduled && !_restored && _loadingRequest == null) {
            _publishPosition();
          }
        }),
        engine.durationStream.listen((_) {
          if (_usingScheduled && !_restored && _loadingRequest == null) {
            _publishDuration();
          }
        }),
        engine.stateStream.listen((_) {
          if (_usingScheduled && !_restored && _loadingRequest == null) {
            _publishState();
          }
        }),
        engine.errorStream.listen((_) {
          if (_usingScheduled && !_disposed) {
            _errors.add('Could not play this track. Please try again.');
          }
        }),
        engine.completionStream.listen((_) {
          if (_usingScheduled && !_restored && _loadingRequest == null) {
            _emitCompletion();
          }
        }),
        engine.handoffStream.listen((token) {
          final next = _next;
          if (_usingScheduled && next != null && identical(token, next)) {
            _adopt(next);
          }
        }),
      ]);
    }
  }

  void _listenToDeck(AudioPlayer deck) {
    _subscriptions.addAll([
      deck.positionStream.listen((_) {
        if (_isLiveDeck(deck)) {
          _detectNativeHandoff(deck);
          _publishPosition();
          _checkTransition();
        }
      }),
      deck.durationStream.listen((_) {
        if (_isLiveDeck(deck)) {
          _detectNativeHandoff(deck);
          _publishDuration();
        }
      }),
      deck.playerStateStream.listen((state) {
        if (!_isLiveDeck(deck)) return;
        if (_mutatingPlaylist &&
            state.processingState == ProcessingState.completed) {
          _completionDuringMutation = deck;
          return;
        }
        _detectNativeHandoff(deck);
        if (state.processingState == ProcessingState.completed) {
          if (_next?.ready == true && _next?.deck != null) {
            unawaited(_beginCrossfade(_next!, Duration.zero));
          } else {
            _emitCompletion();
          }
        } else {
          _completed = false;
        }
        _publishState();
      }),
      deck.sequenceStateStream.listen((_) {
        if (_isLiveDeck(deck)) _detectNativeHandoff(deck);
      }),
    ]);
  }

  bool _isLiveDeck(AudioPlayer deck) =>
      !_disposed &&
      !_usingScheduled &&
      !_restored &&
      _loadingRequest == null &&
      identical(deck, _active);
  AudioPlayer get player => _active;
  AudioPlayer get _idle => identical(_active, _first) ? _second : _first;
  Stream<String> get errorStream => _errors.stream;
  Stream<Duration> get positionStream => _positions.stream;
  Stream<Duration?> get durationStream => _durations.stream;
  Stream<PlayerState> get stateStream => _states.stream;
  Stream<double> get volumeStream => _volumes.stream;
  Stream<void> get completionStream => _completions.stream;
  Stream<Object> get handoffStream => _handoffs.stream;
  String? get currentUrl => _currentUrl;
  void synchronizeTransitions() {
    if (_disposed || _restored || _synchronizing) return;
    _synchronizing = true;
    try {
      if (_usingScheduled) {
        _scheduled!.synchronize();
      } else {
        _detectNativeHandoff(_active);
      }
    } finally {
      _synchronizing = false;
    }
  }

  String? get preloadedUrl => _preloadedUrl;
  double get volume => _volume;
  Duration get position => _restored
      ? _restoredPosition
      : _usingScheduled
          ? _scheduled!.position
          : _active.position;
  Duration get duration => _restored
      ? _restoredDuration
      : _usingScheduled
          ? _scheduled!.duration
          : _active.duration ?? Duration.zero;
  bool get isPlaying =>
      !_restored &&
      (_usingScheduled
          ? _scheduled!.isPlaying
          : _active.playing &&
              _active.processingState != ProcessingState.completed &&
              _active.processingState != ProcessingState.idle);
  bool get isBuffering =>
      !_restored &&
      (_loadingRequest != null ||
          (_usingScheduled
              ? _scheduled!.isBuffering
              : _active.processingState == ProcessingState.loading ||
                  _active.processingState == ProcessingState.buffering));

  void _publishPosition() {
    if (!_disposed) _positions.add(position);
  }

  void _publishDuration() {
    if (!_disposed) _durations.add(duration);
  }

  void _publishState() {
    if (_disposed) return;
    _states.add(_restored
        ? PlayerState.paused
        : isBuffering
            ? PlayerState.buffering
            : isPlaying
                ? PlayerState.playing
                : _currentUrl != null && !_completed
                    ? PlayerState.paused
                    : PlayerState.stopped);
  }

  void _publish() {
    _publishPosition();
    _publishDuration();
    _publishState();
  }

  void _emitCompletion() {
    if (_disposed || _completed) return;
    _completed = true;
    _completions.add(null);
  }

  Duration _clampPosition(Duration value, Duration length) => Duration(
      milliseconds: value.inMilliseconds
          .clamp(0, length > Duration.zero ? length.inMilliseconds : 86400000));

  Future<void> setVolume(double value) async {
    _volume = value.isFinite ? value.clamp(0.0, 1.0) : 1.0;
    if (!_disposed) _volumes.add(_volume);
    if (_usingScheduled) await _scheduled!.setVolume(_volume);
    await _applyDeckVolumes();
  }

  double get _fadeFraction => _fadeClock == null || _fadeLength <= Duration.zero
      ? 1
      : (_fadeClock!.elapsedMicroseconds / _fadeLength.inMicroseconds)
          .clamp(0.0, 1.0);
  Future<void> _applyDeckVolumes() async {
    if (_disposed) return;
    final outgoing = _outgoing;
    final fraction = _fadeFraction;
    await _active.setVolume(_volume * (outgoing == null ? 1 : fraction));
    if (!_disposed && outgoing != null) {
      await outgoing.setVolume(_volume * (1 - fraction));
    }
  }

  /// Display only: no fetch, decoding, authorization, or listen is started.
  void restorePaused(String? url,
      {Duration position = Duration.zero, Duration duration = Duration.zero}) {
    ++_playRequest;
    _restored = true;
    _currentUrl = url == null ? null : ApiService.canonicalMediaUrl(url);
    _restoredDuration = duration.isNegative ? Duration.zero : duration;
    _restoredPosition = _clampPosition(position, _restoredDuration);
    _completed = false;
    _restoreStop = _stopTransports();
    _publish();
  }

  void cancelPendingPlayback() {
    ++_playRequest;
    _loadingRequest = null;
    unawaited(clearPreload());
    unawaited(_cancelFade());
  }

  Future<void> _mutate(Future<void> Function() action) {
    final result = _nativeMutations.then((_) async {
      _mutatingPlaylist = true;
      try {
        await action();
      } finally {
        _mutatingPlaylist = false;
        if (!_disposed &&
            !_usingScheduled &&
            !_restored &&
            _loadingRequest == null) {
          final before = _handoffRevision;
          _detectNativeHandoff(_active);
          final completed = _completionDuringMutation;
          _completionDuringMutation = null;
          if (identical(completed, _active) &&
              before == _handoffRevision &&
              _active.processingState == ProcessingState.completed) {
            _emitCompletion();
          }
        }
      }
    });
    _nativeMutations = result.catchError((_) {});
    return result;
  }

  Future<Duration?> _loadNative(
      AudioPlayer deck, String url, Duration at) async {
    final source = ConcatenatingAudioSource(
        useLazyPreparation: false,
        children: [AudioSource.uri(Uri.parse(url), tag: Object())]);
    _playlists[deck] = source;
    return deck.setAudioSource(source, initialPosition: at);
  }

  Future<void> _load(
      String canonical, String playable, Duration at, int request) async {
    final engine = _scheduled;
    if (engine != null && !_progressiveSources.contains(canonical)) {
      try {
        await engine.load(playable, position: at);
        if (_disposed || request != _playRequest) return;
        _usingScheduled = true;
        await _first.stop();
        if (_disposed || request != _playRequest) return;
        await _second.stop();
        if (_disposed || request != _playRequest) return;
        await engine.setVolume(_volume);
        return;
      } on ScheduledAudioFallbackException catch (error) {
        if (_disposed || request != _playRequest) return;
        if (error.reason != ScheduledAudioFallbackReason.network) {
          if (_progressiveSources.length >= 32) {
            _progressiveSources.remove(_progressiveSources.first);
          }
          _progressiveSources.add(canonical);
        }
        await engine.stop();
      }
    }
    if (_disposed || request != _playRequest) return;
    if (_usingScheduled) await engine?.stop();
    if (_disposed || request != _playRequest) return;
    _usingScheduled = false;
    await _loadNative(_active, playable, at);
    if (!_disposed && request == _playRequest) await _active.setVolume(_volume);
  }

  void _startPlayback() {
    final request = _playRequest;
    final future = _usingScheduled ? _scheduled!.play() : _active.play();
    // Native play futures last until playback stops, so never await them.
    unawaited(future.catchError((Object error) {
      if (!_disposed && request == _playRequest) {
        _errors.add(
            _currentUrl != null && ApiService.isProtectedMediaUrl(_currentUrl!)
                ? 'Could not play this track. Please try again.'
                : 'Could not play audio: $error');
      }
    }));
  }

  Future<void> playFromUrl(String url) async {
    synchronizeTransitions();
    final request = ++_playRequest;
    _loadingRequest = request;
    final canonical = ApiService.canonicalMediaUrl(url);
    final cleared = clearPreload();
    try {
      await _restoreStop;
      await cleared;
      await _cancelFade();
      final playable = await _resolveMediaUrl(canonical);
      if (_disposed || request != _playRequest) return;
      await _load(canonical, playable, Duration.zero, request);
      if (_disposed || request != _playRequest) return;
      _currentUrl = canonical;
      _restored = false;
      _completed = false;
      _loadingRequest = null;
      _startPlayback();
      _publish();
    } on DownloadUnavailableException {
      rethrow;
    } catch (_) {
      throw Exception('Could not load this track. Please try again.');
    } finally {
      if (_loadingRequest == request) {
        _loadingRequest = null;
        _publishState();
      }
    }
  }

  /// Authorize and prepare one occurrence. A request's identity survives equal
  /// URLs, repeated entries, and asynchronous queue edits.
  Future<void> prepareNext(String canonical,
      {required Object token, Duration crossfade = Duration.zero}) async {
    final handoffs = _handoffRevision;
    synchronizeTransitions();
    if (_handoffRevision != handoffs) return;
    final clearing = _clearPreload();
    if (_handoffRevision != handoffs) return;
    final request = _preloadRequest;
    final next = _PreparedNext(ApiService.canonicalMediaUrl(canonical), token,
        Duration(milliseconds: crossfade.inMilliseconds.clamp(0, 12000)));
    _next = next;
    try {
      await clearing;
      await _fadeFinished?.future;
      if (!_validNext(next, request) || _restored) return;
      if (!_usingScheduled && _scheduled != null) {
        return; // progressive web fallback
      }
      final playable = await _resolveMediaUrl(next.canonical);
      if (!_validNext(next, request)) return;
      if (_usingScheduled) {
        await _scheduled!
            .stageNext(playable, token: next, crossfade: next.crossfade);
      } else if (next.crossfade > Duration.zero) {
        final idle = _idle;
        next.deck = idle;
        await idle.stop();
        if (!_validNext(next, request)) return;
        await _loadNative(idle, playable, Duration.zero);
        if (!_validNext(next, request)) return;
        await idle.setVolume(0);
      } else {
        final deck = _active;
        final playlist = _playlists[deck];
        if (playlist == null) return;
        await _mutate(() async {
          if (!_validNext(next, request) || !identical(deck, _active)) return;
          await playlist
              .add(AudioSource.uri(Uri.parse(playable), tag: next.sourceTag));
        });
      }
      if (!_validNext(next, request)) return;
      next.ready = true;
      _preloadedUrl = next.canonical;
      if (next.deck != null) {
        _ensureTransitionTimer();
        _checkTransition();
      }
    } on DownloadUnavailableException {
      final current = _validNext(next, request);
      if (current) await clearPreload();
      if (current) rethrow;
    } catch (_) {
      // Normal playback can retry when opportunistic preparation fails.
      if (_validNext(next, request)) await clearPreload();
    }
  }

  bool _validNext(_PreparedNext next, int request) =>
      !_disposed && request == _preloadRequest && identical(_next, next);

  /// Legacy warm-up API, without an automatic queue handoff.
  Future<void> preloadUrl(String url) async {
    final clearing = clearPreload();
    final request = _preloadRequest;
    final canonical = ApiService.canonicalMediaUrl(url);
    try {
      await clearing;
      if (canonical == _currentUrl) return;
      final playable = await _resolveMediaUrl(canonical);
      if (_disposed || request != _preloadRequest) return;
      await _idle.setUrl(playable);
      if (!_disposed && request == _preloadRequest) _preloadedUrl = canonical;
    } catch (_) {
      if (request == _preloadRequest) _preloadedUrl = null;
    }
  }

  Future<void> clearPreload() {
    synchronizeTransitions();
    return _clearPreload();
  }

  Future<void> _clearPreload() {
    ++_preloadRequest;
    final old = _next;
    final deck = _active;
    final playlist = _playlists[deck];
    // clearNext synchronizes/cancels scheduled nodes before its first await.
    // Do that now, while its handoff token is still valid, not after a previous
    // asynchronous native cleanup or decoder operation has finished.
    final engineCleanup = _disposed ? null : _scheduled?.clearNext();
    if (identical(_next, old)) {
      _next = null;
      _preloadedUrl = null;
    }
    if (_outgoing == null) {
      _transitionTimer?.cancel();
      _transitionTimer = null;
    }
    // Serialize cleanup as well as loading: an older asynchronous clear cannot
    // remove a newly prepared source after it finishes.
    _stageCleanup = _stageCleanup.then((_) async {
      if (_disposed) return;
      try {
        await engineCleanup;
        if (_disposed) return;
        if (old?.deck != null && !identical(old!.deck, _active)) {
          await old.deck!.stop();
        }
        if (old != null && old.deck == null && playlist != null) {
          await _mutate(() async {
            final index = playlist.children.indexWhere((source) =>
                source is IndexedAudioSource &&
                identical(source.tag, old.sourceTag));
            if (index >= 0) await playlist.removeAt(index);
          });
        }
      } catch (_) {/* Obsolete preparation must not interrupt active audio. */}
    });
    return _stageCleanup;
  }

  void _detectNativeHandoff(AudioPlayer deck) {
    if (_mutatingPlaylist || _restored || _disposed) return;
    final next = _next;
    if (next == null || next.deck != null) return;
    if (!identical(deck.sequenceState?.currentSource?.tag, next.sourceTag)) {
      return;
    }
    _adopt(next);
    final playlist = _playlists[deck];
    if (playlist != null) {
      unawaited(_mutate(() async {
        if (_disposed || !identical(_playlists[deck], playlist)) return;
        final index = playlist.children.indexWhere((source) =>
            source is IndexedAudioSource &&
            identical(source.tag, next.sourceTag));
        if (index > 0) await playlist.removeRange(0, index);
      }).catchError((_) {}));
    }
  }

  void _adopt(_PreparedNext next) {
    if (_disposed || !identical(next, _next)) return;
    _next = null;
    _preloadedUrl = null;
    _currentUrl = next.canonical;
    _completed = false;
    ++_handoffRevision;
    _handoffs
        .add(next.token); // Queue and metadata synchronize before UI events.
    _publish();
  }

  void _ensureTransitionTimer() {
    _transitionTimer ??= Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (_outgoing != null) {
        unawaited(_applyDeckVolumes().catchError((_) {}));
        if (_fadeFraction >= 1) unawaited(_cancelFade());
      } else {
        _checkTransition();
      }
    });
  }

  void _checkTransition() {
    final next = _next;
    if (_outgoing != null ||
        _restored ||
        !isPlaying ||
        next == null ||
        !next.ready ||
        next.deck == null ||
        duration <= Duration.zero) {
      return;
    }
    final remaining = duration - position;
    final incomingLength = next.deck!.duration ?? Duration.zero;
    final threshold =
        math.min(next.crossfade.inMicroseconds, duration.inMicroseconds ~/ 2);
    final boundedThreshold = incomingLength > Duration.zero
        ? math.min(threshold, incomingLength.inMicroseconds ~/ 2)
        : threshold;
    if (remaining.inMicroseconds <= boundedThreshold) {
      final bounded =
          math.min(math.max(remaining.inMicroseconds, 0), boundedThreshold);
      unawaited(_beginCrossfade(next, Duration(microseconds: bounded)));
    }
  }

  Future<void> _beginCrossfade(_PreparedNext next, Duration length) async {
    if (_disposed ||
        !identical(_next, next) ||
        next.deck == null ||
        _outgoing != null) {
      return;
    }
    _outgoing = _active;
    _fadeLength = length;
    _fadeClock = Stopwatch()..start();
    _fadeFinished = Completer<void>();
    _active = next.deck!;
    _startPlayback();
    _adopt(next);
    _ensureTransitionTimer();
    await _applyDeckVolumes();
    if (length <= Duration.zero) await _cancelFade();
  }

  Future<void> _cancelFade() async {
    final outgoing = _outgoing;
    _outgoing = null;
    _fadeClock?.stop();
    _fadeClock = null;
    final finished = _fadeFinished;
    _fadeFinished = null;
    if (_next?.deck == null) {
      _transitionTimer?.cancel();
      _transitionTimer = null;
    }
    if (!_disposed && outgoing != null) await outgoing.stop();
    if (!_disposed) await _active.setVolume(_volume);
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  Future<void> playFromFile(String path) =>
      path.startsWith('http://') || path.startsWith('https://')
          ? playFromUrl(path)
          : playFromBackend(path);
  Future<void> playFromBackend(String filename) => playFromUrl(
      '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(filename)}');
  Future<void> pause() async {
    synchronizeTransitions();
    ++_playRequest;
    _loadingRequest = null;
    await clearPreload();
    await _cancelFade();
    if (_restored) return;
    if (_usingScheduled) {
      await _scheduled!.pause();
    } else {
      await _active.pause();
    }
    _publish();
  }

  Future<void> resume() async {
    synchronizeTransitions();
    final request = ++_playRequest;
    final canonical = _currentUrl;
    if (_restored && canonical == null) {
      throw StateError('No audio source is available.');
    }
    _loadingRequest = request;
    try {
      await clearPreload();
      await _cancelFade();
      if (canonical != null &&
          (_restored ||
              _usingScheduled ||
              ApiService.isProtectedMediaUrl(canonical))) {
        if (_restored &&
            _restoredDuration > Duration.zero &&
            _restoredPosition >= _restoredDuration) {
          _restoredPosition = Duration.zero;
        }
        final saved = _restored
            ? _restoredPosition
            : _completed ||
                    (!_usingScheduled &&
                        _active.processingState == ProcessingState.completed)
                ? Duration.zero
                : position;
        await _restoreStop;
        final playable = await _resolveMediaUrl(canonical);
        if (_disposed || request != _playRequest) return;
        final requested = _restored ? _restoredPosition : saved;
        await _load(canonical, playable, requested, request);
        if (_disposed || request != _playRequest) return;
        final actualDuration = _usingScheduled
            ? _scheduled!.duration
            : _active.duration ?? Duration.zero;
        final target = _clampPosition(
            _restored ? _restoredPosition : requested, actualDuration);
        if (target != requested) {
          if (_usingScheduled) {
            await _scheduled!.seek(target);
          } else {
            await _active.seek(target);
          }
        }
        if (_disposed || request != _playRequest) return;
      } else if (_active.processingState == ProcessingState.completed) {
        await _active.seek(Duration.zero);
      }
      if (_disposed || request != _playRequest) return;
      _restored = false;
      _completed = false;
      _loadingRequest = null;
      _startPlayback();
      _publish();
    } on DownloadUnavailableException {
      rethrow;
    } catch (_) {
      throw Exception('Could not resume this track. Please try again.');
    } finally {
      if (_loadingRequest == request) {
        _loadingRequest = null;
        _publishState();
      }
    }
  }

  Future<void> _stopTransports() async {
    await clearPreload();
    if (_disposed) return;
    await _cancelFade();
    if (_disposed) return;
    await _scheduled?.stop();
    if (_disposed) return;
    await _first.stop();
    if (_disposed) return;
    await _second.stop();
  }

  Future<void> stop() async {
    ++_playRequest;
    _loadingRequest = null;
    _restored = false;
    await _stopTransports();
    _currentUrl = null;
    _completed = false;
    _publish();
  }

  Future<void> seek(Duration value) async {
    synchronizeTransitions();
    if (_restored) {
      _restoredPosition = _clampPosition(value, _restoredDuration);
      _publish();
      return;
    }
    final next = _next;
    final request = _playRequest;
    final clearing = clearPreload();
    final preparationRequest = _preloadRequest;
    await clearing;
    await _cancelFade();
    try {
      if (_usingScheduled) {
        await _scheduled!.seek(value);
      } else {
        await _active.seek(value);
      }
      _publish();
      if (next != null &&
          !_disposed &&
          request == _playRequest &&
          preparationRequest == _preloadRequest) {
        await prepareNext(next.canonical,
            token: next.token, crossfade: next.crossfade);
      }
    } catch (_) {/* Seeking is recoverable; keep the current track. */}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_playRequest;
    ++_preloadRequest;
    _next = null;
    _transitionTimer?.cancel();
    if (_fadeFinished != null && !_fadeFinished!.isCompleted) {
      _fadeFinished!.complete();
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_scheduled?.dispose());
    unawaited(_first.dispose());
    unawaited(_second.dispose());
    _errors.close();
    _positions.close();
    _durations.close();
    _states.close();
    _volumes.close();
    _completions.close();
    _handoffs.close();
  }
}
