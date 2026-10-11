import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/scheduled_audio_backend.dart';
import 'package:music_downloader/services/scheduled_audio_core.dart';
import 'package:music_downloader/services/scheduled_audio_engine.dart';

class _Clip implements ScheduledAudioClip {
  @override
  final double seconds;
  @override
  final int decodedBytes;
  _Clip(this.seconds, [this.decodedBytes = 1024]);
}

class _Decode implements ScheduledAudioDecode {
  final Completer<ScheduledAudioClip> completer = Completer();
  bool cancelled = false;
  @override
  Future<ScheduledAudioClip> get result => completer.future;
  @override
  void cancel() => cancelled = true;
}

class _Voice implements ScheduledAudioVoice {
  final double when;
  final double offset;
  final double fadeIn;
  final void Function() onEnded;
  double? fadeStart;
  double? fadeLength;
  int resets = 0;
  bool stopped = false;
  _Voice(this.when, this.offset, this.fadeIn, this.onEnded);
  @override
  void fadeOut(double start, double seconds) {
    fadeStart = start;
    fadeLength = seconds;
  }

  @override
  void resetGain(double now) => resets++;
  @override
  void stop() => stopped = true;
}

class _Backend implements ScheduledAudioBackend {
  @override
  double now = 0;
  final clips = <String, _Clip>{};
  final requests = <String, _Decode>{};
  final budgets = <int>[];
  final voices = <_Voice>[];
  bool delayDecodes = false;
  bool disposed = false;
  double volume = 1;
  Completer<void>? resumeGate;
  bool failSchedule = false;
  @override
  ScheduledAudioDecode decode(String url, {required int maxDecodedBytes}) {
    final request = _Decode();
    requests[url] = request;
    budgets.add(maxDecodedBytes);
    if (!delayDecodes) request.completer.complete(clips[url] ?? _Clip(10));
    return request;
  }

  @override
  Future<void> resume() async => await resumeGate?.future;
  @override
  ScheduledAudioVoice schedule(ScheduledAudioClip clip,
      {required double when,
      required double offset,
      required double fadeIn,
      required void Function() onEnded}) {
    if (failSchedule) throw StateError('Schedule failed');
    final voice = _Voice(when, offset, fadeIn, onEnded);
    voices.add(voice);
    return voice;
  }

  @override
  void setVolume(double value) => volume = value;
  @override
  Future<void> dispose() async => disposed = true;
}

Future<void> _settle() async => await Future<void>.delayed(Duration.zero);

void main() {
  late _Backend backend;
  late ClockScheduledAudioEngine engine;
  setUp(() {
    backend = _Backend();
    engine = ClockScheduledAudioEngine(backend);
  });
  tearDown(() async => await engine.dispose());

  test('load prepares paused metadata and never starts audio', () async {
    await engine.load('a', position: const Duration(seconds: 3));
    expect(engine.duration, const Duration(seconds: 10));
    expect(engine.position, const Duration(seconds: 3));
    expect(engine.isPlaying, false);
    expect(backend.voices, isEmpty);
    await engine.play();
    expect(backend.voices.single.offset, 3);
    expect(engine.isPlaying, true);
  });

  test('gapless successor is clock scheduled before callback, handoff is once',
      () async {
    final handoffs = <Object>[];
    var completions = 0;
    engine.handoffStream.listen(handoffs.add);
    engine.completionStream.listen((_) => completions++);
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b', token: 'b');
    expect(backend.voices[1].when, 10);
    expect(backend.voices[1].fadeIn, 0);
    backend.now =
        12; // A late browser/UI callback does not move the audio start.
    engine.synchronize();
    expect(handoffs, ['b']);
    expect(engine.position, const Duration(seconds: 2));
    expect(completions, 0);
    engine.synchronize();
    expect(handoffs, ['b']);
    backend.now = 20;
    engine.synchronize();
    engine.synchronize();
    expect(completions, 1);
    expect(engine.isPlaying, false);
  });

  test(
      'crossfade shares the exact interval and preserves incoming ramp when staging third',
      () async {
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b',
        token: 'b', crossfade: const Duration(seconds: 2));
    expect(backend.voices[0].fadeStart, 8);
    expect(backend.voices[0].fadeLength, 2);
    expect(backend.voices[1].when, 8);
    expect(backend.voices[1].fadeIn, 2);
    backend.now = 8;
    engine.synchronize();
    final third = engine.stageNext('c', token: 'c');
    await _settle();
    expect(backend.requests.containsKey('c'), false);
    expect(backend.voices[1].resets, 0);
    backend.now = 10;
    engine.synchronize();
    await third;
    expect(backend.voices[0].stopped, true);
    expect(backend.voices[1].resets, 0);
    expect(backend.voices[2].when, 18);
  });

  test(
      'clearing a successor before its start cancels it and restores outgoing gain',
      () async {
    final handoffs = <Object>[];
    engine.handoffStream.listen(handoffs.add);
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b',
        token: 'removed', crossfade: const Duration(seconds: 2));
    backend.now = 7.999;
    await engine.clearNext();
    expect(backend.voices[1].stopped, true);
    expect(backend.voices[0].resets, 1);
    backend.now = 8;
    engine.synchronize();
    expect(handoffs, isEmpty);
  });

  test('synchronize commits exact-boundary handoff before caller mutates queue',
      () async {
    var current = 'a';
    engine.handoffStream.listen((token) => current = token as String);
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b', token: 'b');
    backend.now = 10;
    engine.synchronize();
    expect(current, 'b'); // No microtask or timer required.
    await engine.clearNext();
    expect(backend.voices[1].stopped, false);
    expect(engine.position, Duration.zero);
  });

  test('repeat single may hand off the same opaque token on every occurrence',
      () async {
    final token = Object();
    final handoffs = <Object>[];
    engine.handoffStream.listen(handoffs.add);
    await engine.load('a');
    await engine.play();
    await engine.stageNext('a', token: token);
    backend.now = 10;
    engine.synchronize();
    await engine.stageNext('a', token: token);
    backend.now = 20;
    engine.synchronize();
    expect(handoffs, [token, token]);
    expect(backend.voices[2].when, 20);
  });

  test('handoff listener may synchronously stop playback safely', () async {
    engine.handoffStream.listen((_) => unawaited(engine.stop()));
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b', token: 'b');
    backend.now = 10;
    engine.synchronize();
    expect(engine.isPlaying, false);
    expect(engine.duration, Duration.zero);
  });

  test('pause cancels audible nodes and resume schedules from frozen offset',
      () async {
    await engine.load('a');
    await engine.play();
    await engine.stageNext('b', token: 'b');
    backend.now = 3;
    await engine.pause();
    expect(backend.voices.every((voice) => voice.stopped), true);
    backend.now = 30;
    expect(engine.position, const Duration(seconds: 3));
    await engine.play();
    expect(backend.voices[2].offset, 3);
    expect(backend.voices[3].when, 37);
    await engine.seek(const Duration(seconds: 6));
    expect(backend.voices[4].offset, 6);
    expect(backend.voices[5].when, 34);
  });

  test('seek to end completes once instead of restarting track', () async {
    var completions = 0;
    engine.completionStream.listen((_) => completions++);
    await engine.load('a');
    await engine.play();
    await engine.seek(const Duration(seconds: 10));
    engine.synchronize();
    expect(completions, 1);
    expect(engine.position, const Duration(seconds: 10));
    await engine.play();
    expect(engine.position, Duration.zero);
  });

  test('a superseded source decode cannot replace newer metadata', () async {
    backend.delayDecodes = true;
    final old = engine.load('old');
    final recent = engine.load('new');
    expect(backend.requests['old']!.cancelled, true);
    backend.requests['new']!.completer.complete(_Clip(20));
    await recent;
    backend.requests['old']!.completer.complete(_Clip(5));
    await old;
    expect(engine.duration, const Duration(seconds: 20));
    expect(engine.isPlaying, false);
  });

  test('cancelled pending stage never starts even if decoding later succeeds',
      () async {
    await engine.load('a');
    await engine.play();
    backend.delayDecodes = true;
    final pending = engine.stageNext('b', token: 'b');
    await _settle();
    await engine.clearNext();
    expect(backend.requests['b']!.cancelled, true);
    backend.requests['b']!.completer.complete(_Clip(10));
    await pending;
    expect(backend.voices.length, 1);
  });

  test('pause invalidates pending context resume so it cannot start later',
      () async {
    await engine.load('a');
    backend.resumeGate = Completer();
    final playing = engine.play();
    await engine.pause();
    backend.resumeGate!.complete();
    await playing;
    expect(backend.voices, isEmpty);
    expect(engine.isPlaying, false);
  });

  test('decoded pair limit rejects next without interrupting active playback',
      () async {
    const limit = ClockScheduledAudioEngine.maxDecodedBytes;
    backend.clips['a'] = _Clip(10, limit - 100);
    backend.clips['b'] = _Clip(10, 101);
    await engine.load('a');
    await engine.play();
    await expectLater(
        engine.stageNext('b', token: 'b'),
        throwsA(isA<ScheduledAudioFallbackException>().having((e) => e.reason,
            'reason', ScheduledAudioFallbackReason.oversized)));
    expect(backend.budgets.last, 100);
    expect(engine.isPlaying, true);
    expect(backend.voices.length, 1);
  });

  test('oversized or invalid current decode reports typed fallback', () async {
    backend.clips['large'] =
        _Clip(10, ClockScheduledAudioEngine.maxDecodedBytes + 1);
    await expectLater(
        engine.load('large'), throwsA(isA<ScheduledAudioFallbackException>()));
    expect(engine.isBuffering, false);
    backend.clips['bad'] = _Clip(double.nan);
    await expectLater(
        engine.load('bad'), throwsA(isA<ScheduledAudioFallbackException>()));
    expect(engine.duration, Duration.zero);
  });

  test('failed successor schedule never publishes a ghost handoff', () async {
    final handoffs = <Object>[];
    engine.handoffStream.listen(handoffs.add);
    await engine.load('a');
    await engine.play();
    backend.now = 9;
    backend.failSchedule = true;
    await expectLater(
        engine.stageNext('b',
            token: 'b', crossfade: const Duration(seconds: 2)),
        throwsStateError);
    engine.synchronize();
    await engine.clearNext();
    expect(handoffs, isEmpty);
    expect(engine.isPlaying, true);
    expect(engine.position, const Duration(seconds: 9));
  });

  test('volume is clamped and applies to shared output', () async {
    await engine.setVolume(2);
    expect(backend.volume, 1);
    await engine.setVolume(-1);
    expect(backend.volume, 0);
    await engine.setVolume(double.nan);
    expect(engine.volume, 1);
  });

  test('dispose cancels loads and ignores their eventual result', () async {
    backend.delayDecodes = true;
    final load = engine.load('a');
    await engine.dispose();
    expect(backend.requests['a']!.cancelled, true);
    backend.requests['a']!.completer.complete(_Clip(10));
    await load;
    expect(backend.disposed, true);
    expect(backend.voices, isEmpty);
  });
}
