import 'dart:async';
import 'dart:math' as math;
import 'scheduled_audio_backend.dart';
import 'scheduled_audio_engine.dart';

class _StagedTrack {
  final ScheduledAudioClip clip;
  final Object token;
  final double fade;
  _StagedTrack(this.clip, this.token, this.fade);
}

/// Audio starts are scheduled on the backend clock. The timer publishes UI
/// state only; a delayed UI callback cannot introduce a gap between buffers.
class ClockScheduledAudioEngine implements ScheduledAudioEngine {
  static const maxDecodedBytes = 192 * 1024 * 1024;
  final ScheduledAudioBackend _backend;
  final StreamController<Duration> _positions = StreamController.broadcast();
  final StreamController<Duration?> _durations = StreamController.broadcast();
  final StreamController<double> _volumes = StreamController.broadcast();
  final StreamController<EngineState> _states = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final StreamController<void> _completions =
      StreamController.broadcast(sync: true);
  final StreamController<Object> _handoffs =
      StreamController.broadcast(sync: true);
  Timer? _timer;
  ScheduledAudioClip? _current;
  ScheduledAudioVoice? _voice;
  ScheduledAudioVoice? _tail;
  double? _tailEnd;
  Completer<void>? _tailDone;
  _StagedTrack? _next;
  ScheduledAudioVoice? _nextVoice;
  double? _nextStart;
  ScheduledAudioDecode? _loading;
  ScheduledAudioDecode? _staging;
  int _loadGeneration = 0;
  int _stageGeneration = 0;
  int _transportGeneration = 0;
  bool _disposed = false;
  bool _completionSent = false;
  double _offset = 0;
  double _anchor = 0;
  double _volume = 1;
  EngineState _state = EngineState.stopped;

  ClockScheduledAudioEngine(this._backend,
      {Duration tickInterval = const Duration(milliseconds: 40)}) {
    _timer = Timer.periodic(tickInterval, (_) => tick());
  }

  static Duration _time(double seconds) =>
      Duration(microseconds: (seconds * 1000000).round());
  double get _positionSeconds => _current == null
      ? 0
      : (isPlaying ? _offset + _backend.now - _anchor : _offset)
          .clamp(0, _current!.seconds);
  @override
  Duration get position => _time(_positionSeconds);
  @override
  Duration get duration => _time(_current?.seconds ?? 0);
  @override
  double get volume => _volume;
  @override
  bool get isPlaying => _state == EngineState.playing;
  @override
  bool get isBuffering => _state == EngineState.buffering;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration?> get durationStream => _durations.stream;
  @override
  Stream<double> get volumeStream => _volumes.stream;
  @override
  Stream<EngineState> get stateStream => _states.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Stream<void> get completionStream => _completions.stream;
  @override
  Stream<Object> get handoffStream => _handoffs.stream;

  void _setState(EngineState value) {
    if (_disposed || value == _state) return;
    _state = value;
    _states.add(value);
  }

  void _releaseTail() {
    _tail?.stop();
    _tail = null;
    _tailEnd = null;
    _tailDone?.complete();
    _tailDone = null;
  }

  void _cancelScheduledNext() {
    final hadScheduledNext = _nextVoice != null;
    _nextVoice?.stop();
    _nextVoice = null;
    _nextStart = null;
    if (hadScheduledNext) _voice?.resetGain(_backend.now);
  }

  void _invalidateNext() {
    ++_stageGeneration;
    _staging?.cancel();
    _staging = null;
    _cancelScheduledNext();
    _next = null;
  }

  void _stopVoices() {
    _cancelScheduledNext();
    _voice?.stop();
    _voice = null;
    _releaseTail();
  }

  @override
  Future<void> load(String authorizedUrl,
      {Duration position = Duration.zero}) async {
    if (_disposed) return;
    final generation = ++_loadGeneration;
    ++_transportGeneration;
    _loading?.cancel();
    _invalidateNext();
    _stopVoices();
    _current = null;
    _offset = 0;
    _completionSent = false;
    _setState(EngineState.buffering);
    _durations.add(null);
    _positions.add(Duration.zero);
    final request =
        _backend.decode(authorizedUrl, maxDecodedBytes: maxDecodedBytes);
    _loading = request;
    try {
      final clip = await request.result;
      if (_disposed || generation != _loadGeneration) return;
      _validateClip(clip, 0);
      _current = clip;
      _offset = (position.inMicroseconds / 1000000).clamp(0, clip.seconds);
      _setState(EngineState.paused);
      _durations.add(duration);
      _positions.add(this.position);
    } catch (_) {
      if (_disposed || generation != _loadGeneration) return;
      _setState(EngineState.stopped);
      rethrow;
    } finally {
      if (identical(_loading, request)) _loading = null;
    }
  }

  void _validateClip(ScheduledAudioClip clip, int retainedBytes) {
    if (!clip.seconds.isFinite || clip.seconds <= 0 || clip.decodedBytes < 1) {
      throw const ScheduledAudioFallbackException(
          ScheduledAudioFallbackReason.unsupported,
          'This audio format needs standard playback.');
    }
    if (retainedBytes + clip.decodedBytes > maxDecodedBytes) {
      throw const ScheduledAudioFallbackException(
          ScheduledAudioFallbackReason.oversized,
          'This track needs standard playback because it exceeds the audio memory limit.');
    }
  }

  @override
  Future<void> play() async {
    if (_disposed || _current == null || isPlaying) return;
    final generation = ++_transportGeneration;
    await _backend.resume();
    if (_disposed || generation != _transportGeneration || _current == null) {
      return;
    }
    if (_offset >= _current!.seconds && _completionSent) _offset = 0;
    _completionSent = false;
    _anchor = _backend.now;
    _voice = _backend.schedule(_current!,
        when: _anchor, offset: _offset, fadeIn: 0, onEnded: tick);
    _setState(EngineState.playing);
    _scheduleNext();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    ++_transportGeneration;
    tick();
    if (!isPlaying) return;
    _offset = _positionSeconds;
    _stopVoices();
    _setState(EngineState.paused);
    _positions.add(position);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    ++_loadGeneration;
    ++_transportGeneration;
    _loading?.cancel();
    _loading = null;
    _invalidateNext();
    _stopVoices();
    _current = null;
    _offset = 0;
    _setState(EngineState.stopped);
    _positions.add(Duration.zero);
    _durations.add(null);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed || _current == null) return;
    tick();
    final playing = isPlaying;
    ++_transportGeneration;
    _stopVoices();
    _offset = (position.inMicroseconds / 1000000).clamp(0, _current!.seconds);
    _completionSent = false;
    _setState(EngineState.paused);
    _positions.add(this.position);
    if (playing) await play();
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.isFinite ? volume.clamp(0, 1) : 1;
    _backend.setVolume(_volume);
    _volumes.add(_volume);
  }

  @override
  Future<void> stageNext(String authorizedUrl,
      {required Object token, Duration crossfade = Duration.zero}) async {
    if (_disposed || _current == null) return;
    tick();
    _invalidateNext();
    final generation = _stageGeneration;
    // A crossfade temporarily retains the outgoing buffer. Wait for its end
    // before decoding another track so only two buffers can be retained.
    await _tailDone?.future;
    if (_disposed || generation != _stageGeneration || _current == null) return;
    final request = _backend.decode(authorizedUrl,
        maxDecodedBytes: maxDecodedBytes - _current!.decodedBytes);
    _staging = request;
    try {
      final clip = await request.result;
      if (_disposed || generation != _stageGeneration || _current == null) {
        return;
      }
      _validateClip(clip, _current!.decodedBytes);
      _next = _StagedTrack(
          clip, token, (crossfade.inMicroseconds / 1000000).clamp(0, 12));
      _scheduleNext();
    } catch (_) {
      if (_disposed || generation != _stageGeneration) return;
      _cancelScheduledNext();
      _next = null;
      rethrow;
    } finally {
      if (identical(_staging, request)) _staging = null;
    }
  }

  void _scheduleNext() {
    if (!isPlaying || _next == null || _nextVoice != null || _current == null) {
      return;
    }
    final end = _anchor + _current!.seconds - _offset;
    final remaining = math.max(0.0, end - _backend.now);
    if (remaining <= 0) return;
    final fade = math.min(
        _next!.fade,
        math.min(remaining,
            math.min(_current!.seconds / 2, _next!.clip.seconds / 2)));
    final start = math.max(_backend.now, end - fade);
    final voice = _backend.schedule(_next!.clip,
        when: start, offset: 0, fadeIn: fade, onEnded: tick);
    try {
      if (fade > 0) _voice?.fadeOut(start, fade);
    } catch (_) {
      voice.stop();
      _voice?.resetGain(_backend.now);
      rethrow;
    }
    _nextStart = start;
    _nextVoice = voice;
  }

  /// Public for deterministic clock tests; production calls it from audio node
  /// end events and the UI update timer.
  @override
  void synchronize() => tick();

  void tick() {
    if (_disposed) return;
    if (_tailEnd != null && _backend.now >= _tailEnd!) _releaseTail();
    if (!isPlaying || _current == null) return;
    if (_nextStart != null && _backend.now >= _nextStart!) {
      final staged = _next!;
      final start = _nextStart!;
      final oldEnd = _anchor + _current!.seconds - _offset;
      _releaseTail();
      if (oldEnd > _backend.now) {
        _tail = _voice;
        _tailEnd = oldEnd;
        _tailDone = Completer<void>();
      } else {
        _voice?.stop();
      }
      _current = staged.clip;
      _voice = _nextVoice;
      _next = null;
      _nextVoice = null;
      _nextStart = null;
      _offset = 0;
      _anchor = start;
      _completionSent = false;
      _durations.add(duration);
      _handoffs.add(staged.token);
      if (_disposed || !isPlaying || _current == null) return;
    }
    _positions.add(position);
    if (_positionSeconds >= _current!.seconds && !_completionSent) {
      _offset = _current!.seconds;
      _voice?.stop();
      _voice = null;
      _completionSent = true;
      _setState(EngineState.stopped);
      _completions.add(null);
    }
  }

  @override
  Future<void> clearNext() async {
    if (_disposed) return;
    tick();
    _invalidateNext();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    final stopped = stop();
    _disposed = true;
    _timer?.cancel();
    await stopped;
    await _backend.dispose();
    await Future.wait([
      _positions.close(),
      _durations.close(),
      _volumes.close(),
      _states.close(),
      _errors.close(),
      _completions.close(),
      _handoffs.close()
    ]);
  }
}
