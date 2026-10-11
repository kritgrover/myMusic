import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'scheduled_audio_backend.dart';
import 'scheduled_audio_core.dart';
import 'scheduled_audio_engine.dart';
import 'scheduled_audio_limits.dart';

ScheduledAudioEngine? createScheduledAudioEngine() {
  try {
    return ClockScheduledAudioEngine(_WebAudioBackend());
  } catch (_) {
    return null;
  }
}

class _WebClip implements ScheduledAudioClip {
  final web.AudioBuffer buffer;
  _WebClip(this.buffer);
  @override
  double get seconds => buffer.duration;
  @override
  int get decodedBytes => buffer.length * buffer.numberOfChannels * 4;
}

class _WebVoice implements ScheduledAudioVoice {
  final web.AudioBufferSourceNode source;
  final web.GainNode gain;
  bool _stopped = false;
  _WebVoice(this.source, this.gain);
  @override
  void fadeOut(double start, double seconds) {
    gain.gain.setValueAtTime(1, start);
    gain.gain.linearRampToValueAtTime(0, start + seconds);
  }

  @override
  void resetGain(double now) {
    if (_stopped) return;
    gain.gain.cancelScheduledValues(now);
    gain.gain.setValueAtTime(1, now);
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    source.onended = null;
    source.stop();
    source.disconnect();
    gain.disconnect();
  }
}

class _WebDecode implements ScheduledAudioDecode {
  final Completer<ScheduledAudioClip> completer = Completer();
  final web.AbortController abort = web.AbortController();
  bool cancelled = false;
  void Function()? cancelProbe;
  @override
  Future<ScheduledAudioClip> get result => completer.future;
  @override
  void cancel() {
    cancelled = true;
    abort.abort();
    cancelProbe?.call();
  }
}

class _WebAudioBackend implements ScheduledAudioBackend {
  final web.AudioContext _context = web.AudioContext();
  late final web.GainNode _master;
  final Set<_WebDecode> _requests = {};
  Future<void> _decodeTail = Future.value();
  bool _disposed = false;
  late final JSFunction _unlockListener;
  bool _listeningForGesture = true;
  _WebAudioBackend() {
    _master = _context.createGain();
    _master.connect(_context.destination);
    // Source lookup and authorization may await network work before play().
    // Unlock an empty context within the original trusted user gesture so
    // browsers requiring transient activation can still start the later audio.
    _unlockListener = ((web.Event event) {
      if (event.isTrusted && !_disposed) {
        unawaited(resume().catchError((_) {}));
      }
    }).toJS;
    web.document.addEventListener('pointerdown', _unlockListener,
        web.AddEventListenerOptions(capture: true));
    web.document.addEventListener(
        'keydown', _unlockListener, web.AddEventListenerOptions(capture: true));
  }
  @override
  double get now => _context.currentTime;
  @override
  Future<void> resume() async {
    if (_disposed || _context.state == 'closed') return;
    await _context.resume().toDart;
    if (_context.state == 'running') _removeGestureListeners();
  }

  void _removeGestureListeners() {
    if (!_listeningForGesture) return;
    _listeningForGesture = false;
    web.document.removeEventListener('pointerdown', _unlockListener, true.toJS);
    web.document.removeEventListener('keydown', _unlockListener, true.toJS);
  }

  @override
  void setVolume(double value) => _master.gain.setValueAtTime(value, now);

  @override
  ScheduledAudioVoice schedule(ScheduledAudioClip clip,
      {required double when,
      required double offset,
      required double fadeIn,
      required void Function() onEnded}) {
    final source = _context.createBufferSource();
    final gain = _context.createGain();
    source.buffer = (clip as _WebClip).buffer;
    source.connect(gain);
    gain.connect(_master);
    gain.gain.setValueAtTime(fadeIn > 0 ? 0 : 1, when);
    if (fadeIn > 0) gain.gain.linearRampToValueAtTime(1, when + fadeIn);
    source.onended = ((web.Event _) => onEnded()).toJS;
    source.start(when, offset);
    return _WebVoice(source, gain);
  }

  @override
  ScheduledAudioDecode decode(String url, {required int maxDecodedBytes}) {
    final request = _WebDecode();
    _requests.add(request);
    // Browser decodeAudioData cannot be aborted. Serialize decodes, and drop
    // cancelled results before starting another, to bound retained buffers.
    _decodeTail = _decodeTail.then((_) async {
      try {
        _checkLive(request);
        final bytes = await _fetch(url, request);
        _checkLive(request);
        final channels = ScheduledAudioLimits.channelBound(bytes);
        if (channels == null) {
          throw const ScheduledAudioFallbackException(
              ScheduledAudioFallbackReason.unsupported,
              'This audio format needs standard playback.');
        }
        final seconds = await _probeDuration(bytes, request);
        _checkLive(request);
        // Allow a small decoder padding margin. The exact decoded size is
        // checked again before the buffer is retained by the scheduler.
        if (!seconds.isFinite ||
            seconds <= 0 ||
            (seconds + 1) * _context.sampleRate * channels * 4 >
                maxDecodedBytes) {
          throw const ScheduledAudioFallbackException(
              ScheduledAudioFallbackReason.oversized,
              'This track needs standard playback because it exceeds the audio memory limit.');
        }
        web.AudioBuffer buffer;
        try {
          buffer = await _context.decodeAudioData(bytes.buffer.toJS).toDart;
        } catch (_) {
          throw const ScheduledAudioFallbackException(
              ScheduledAudioFallbackReason.unsupported,
              'This audio format needs standard playback.');
        }
        _checkLive(request);
        final clip = _WebClip(buffer);
        if (clip.decodedBytes > maxDecodedBytes) {
          throw const ScheduledAudioFallbackException(
              ScheduledAudioFallbackReason.oversized,
              'This track needs standard playback because it exceeds the audio memory limit.');
        }
        request.completer.complete(clip);
      } catch (error) {
        request.completer.completeError(error is ScheduledAudioFallbackException
            ? error
            : const ScheduledAudioFallbackException(
                ScheduledAudioFallbackReason.network,
                'Could not prepare this track for seamless playback.'));
      } finally {
        _requests.remove(request);
      }
    });
    return request;
  }

  void _checkLive(_WebDecode request) {
    if (_disposed || request.cancelled) throw StateError('Cancelled');
  }

  Future<Uint8List> _fetch(String url, _WebDecode request) async {
    final timeout = Timer(const Duration(seconds: 90), request.cancel);
    web.ReadableStreamDefaultReader? reader;
    try {
      final response = await web.window
          .fetch(
              url.toJS,
              web.RequestInit(
                  signal: request.abort.signal, credentials: 'omit'))
          .toDart;
      _checkLive(request);
      if (!response.ok || response.body == null) {
        throw StateError('Fetch failed');
      }
      final length = int.tryParse(response.headers.get('content-length') ?? '');
      if (length != null && length > ScheduledAudioLimits.maxEncodedBytes) {
        _tooLarge(request);
      }
      reader = web.ReadableStreamDefaultReader(response.body!);
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final chunk = await reader.read().toDart;
        _checkLive(request);
        if (chunk.done) break;
        final data = (chunk.value as JSUint8Array).toDart;
        if (bytes.length + data.length > ScheduledAudioLimits.maxEncodedBytes) {
          _tooLarge(request);
        }
        bytes.add(data);
      }
      return bytes.takeBytes();
    } finally {
      timeout.cancel();
      reader?.releaseLock();
    }
  }

  Never _tooLarge(_WebDecode request) {
    request.cancel();
    throw const ScheduledAudioFallbackException(
        ScheduledAudioFallbackReason.oversized,
        'This track needs standard playback because it exceeds the download memory limit.');
  }

  Future<double> _probeDuration(Uint8List bytes, _WebDecode request) async {
    final blob = web.Blob([bytes.toJS].toJS);
    final objectUrl = web.URL.createObjectURL(blob);
    final media = web.HTMLAudioElement()..preload = 'metadata';
    final done = Completer<double>();
    void fail() {
      if (!done.isCompleted) {
        done.completeError(StateError('Metadata unavailable'));
      }
    }

    final timeout = Timer(const Duration(seconds: 15), fail);
    request.cancelProbe = fail;
    media.onloadedmetadata = ((web.Event _) {
      if (!done.isCompleted) done.complete(media.duration);
    }).toJS;
    media.onerror = ((web.Event _) => fail()).toJS;
    media.src = objectUrl;
    try {
      return await done.future;
    } finally {
      request.cancelProbe = null;
      timeout.cancel();
      media.onloadedmetadata = null;
      media.onerror = null;
      media.removeAttribute('src');
      media.load();
      web.URL.revokeObjectURL(objectUrl);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _removeGestureListeners();
    for (final request in _requests) {
      request.cancel();
    }
    await _context.close().toDart;
  }
}
