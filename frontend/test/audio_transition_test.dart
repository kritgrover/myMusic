import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:music_downloader/config.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/scheduled_audio_engine.dart';

class _Deck extends Fake implements native.AudioPlayer {
  final states = StreamController<native.PlayerState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final sequences =
      StreamController<native.SequenceState?>.broadcast(sync: true);
  native.ConcatenatingAudioSource? playlist;
  native.IndexedAudioSource? current;
  final loaded = <String>[];
  final levels = <double>[];
  Duration elapsed = Duration.zero;
  Duration length = const Duration(seconds: 60);
  double level = 1;
  bool running = false;
  int starts = 0;
  native.ProcessingState processing = native.ProcessingState.idle;
  Completer<void>? seekGate;
  Completer<void>? loadGate;
  @override
  Duration get position => elapsed;
  @override
  Duration? get duration => length;
  @override
  bool get playing => running;
  @override
  double get volume => level;
  @override
  native.ProcessingState get processingState => processing;
  @override
  Stream<native.PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<native.SequenceState?> get sequenceStateStream => sequences.stream;
  @override
  native.SequenceState? get sequenceState {
    final sources =
        playlist?.children.cast<native.IndexedAudioSource>().toList();
    if (sources == null || sources.isEmpty) return null;
    return native.SequenceState(
        sources,
        sources.indexOf(current!).clamp(0, sources.length - 1),
        List.generate(sources.length, (i) => i),
        false,
        native.LoopMode.off);
  }

  void advance() {
    current = playlist!.children.last as native.IndexedAudioSource;
    elapsed = Duration.zero;
    sequences.add(sequenceState);
  }

  void tick(Duration value) {
    elapsed = value;
    positions.add(value);
  }

  void complete() {
    processing = native.ProcessingState.completed;
    states.add(native.PlayerState(running, processing));
  }

  @override
  Future<Duration?> setAudioSource(native.AudioSource source,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition}) async {
    playlist = source as native.ConcatenatingAudioSource;
    current = playlist!.children.first as native.IndexedAudioSource;
    loaded.add((current as native.UriAudioSource).uri.toString());
    await loadGate?.future;
    elapsed = initialPosition ?? Duration.zero;
    processing = native.ProcessingState.ready;
    durations.add(length);
    return length;
  }

  @override
  Future<void> play() async {
    running = true;
    starts++;
    states.add(native.PlayerState(true, processing));
  }

  @override
  Future<void> pause() async {
    running = false;
    states.add(native.PlayerState(false, processing));
  }

  @override
  Future<void> stop() async {
    running = false;
    processing = native.ProcessingState.idle;
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async {
    await seekGate?.future;
    elapsed = value ?? Duration.zero;
    positions.add(elapsed);
  }

  @override
  Future<void> setVolume(double value) async {
    level = value;
    levels.add(value);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await positions.close();
    await durations.close();
    await sequences.close();
  }
}

class _Engine extends Fake implements ScheduledAudioEngine {
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  final states = StreamController<EngineState>.broadcast();
  final errors = StreamController<String>.broadcast();
  final completions = StreamController<void>.broadcast();
  final handoffs = StreamController<Object>.broadcast(sync: true);
  Duration elapsed = Duration.zero;
  bool running = false;
  double level = 1;
  bool fallback = false;
  bool due = false;
  Object? staged;
  String? stagedUrl;
  final loaded = <String>[];
  final stagedUrls = <String>[];
  Completer<void>? clearGate;
  Completer<void>? loadGate;
  @override
  Duration get position => elapsed;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get isPlaying => running;
  @override
  bool get isBuffering => false;
  @override
  double get volume => level;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<EngineState> get stateStream => states.stream;
  @override
  Stream<double> get volumeStream => const Stream.empty();
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<void> get completionStream => completions.stream;
  @override
  Stream<Object> get handoffStream => handoffs.stream;
  @override
  void synchronize() {
    if (due && staged != null) {
      due = false;
      final token = staged!;
      staged = null;
      elapsed = const Duration(milliseconds: 200);
      handoffs.add(token);
    }
  }

  @override
  Future<void> load(String url, {Duration position = Duration.zero}) async {
    loaded.add(url);
    if (fallback) {
      throw const ScheduledAudioFallbackException(
          ScheduledAudioFallbackReason.oversized, 'Too large');
    }
    await loadGate?.future;
    elapsed = position;
  }

  @override
  Future<void> play() async {
    running = true;
  }

  @override
  Future<void> pause() async {
    running = false;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<void> seek(Duration value) async {
    elapsed = value;
  }

  @override
  Future<void> setVolume(double value) async {
    level = value;
  }

  @override
  Future<void> stageNext(String url,
      {required Object token, Duration crossfade = Duration.zero}) async {
    staged = token;
    stagedUrl = url;
    stagedUrls.add(url);
  }

  @override
  Future<void> clearNext() async {
    staged = null;
    await clearGate?.future;
  }

  @override
  Future<void> dispose() async {
    await positions.close();
    await durations.close();
    await states.close();
    await errors.close();
    await completions.close();
    await handoffs.close();
  }
}

void main() {
  const first = '${AppConfig.apiBaseUrl}/downloads/first.mp3';
  const second = '${AppConfig.apiBaseUrl}/downloads/second.mp3';
  const third = '${AppConfig.apiBaseUrl}/downloads/third.mp3';
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
      'native gapless handoff is occurrence-based and never restarts the next source',
      () async {
    final deck = _Deck();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        mediaUrlResolver: (url) async => '$url?media_token=fresh');
    addTearDown(service.dispose);
    final token = Object();
    final events = <Object>[];
    var completions = 0;
    service.handoffStream.listen((value) {
      expect(service.currentUrl, second);
      events.add(value);
    });
    service.completionStream.listen((_) => completions++);
    await service.playFromUrl(first);
    await service.prepareNext(second, token: token);
    expect(deck.playlist!.children, hasLength(2));
    deck.advance();
    await settle();
    expect(events, [token]);
    expect(deck.starts, 1);
    expect(deck.loaded, hasLength(1));
    expect(deck.playlist!.children, hasLength(1));
    deck.sequences.add(deck.sequenceState); // pruning renumbers 1 -> 0
    await settle();
    expect(events, [token]);
    expect(completions, 0);
    deck.complete();
    await settle();
    expect(completions, 1);
  });

  test(
      'manual web decode suppresses terminal completion from old progressive audio',
      () async {
    final engine = _Engine()..fallback = true;
    final deck = _Deck();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        scheduledEngine: engine,
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    var completions = 0;
    service.completionStream.listen((_) => completions++);
    await service.playFromUrl(first);
    engine.fallback = false;
    engine.loadGate = Completer<void>();
    final changing = service.playFromUrl(second);
    await settle();
    expect(service.isBuffering, isTrue);
    deck.complete();
    await settle();
    expect(completions, 0);
    engine.loadGate!.complete();
    await changing;
    expect(service.currentUrl, second);
    expect(service.isPlaying, isTrue);
    expect(deck.running, isFalse);
  });

  test(
      'same URL and same queue token may hand off repeatedly without false early events',
      () async {
    final deck = _Deck();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    final token = Object();
    final events = <Object>[];
    service.handoffStream.listen(events.add);
    await service.playFromUrl(first);
    for (var i = 0; i < 2; i++) {
      await service.prepareNext(first, token: token);
      deck.sequences.add(deck.sequenceState);
      expect(events.length, i);
      deck.advance();
      await settle();
      expect(events.length, i + 1);
    }
    expect(deck.starts, 1);
  });

  test('clearing delayed authorization cannot install an obsolete next source',
      () async {
    final deck = _Deck();
    final gate = Completer<String>();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        mediaUrlResolver: (url) =>
            url == second ? gate.future : Future.value(url));
    addTearDown(service.dispose);
    await service.playFromUrl(first);
    final preparing = service.prepareNext(second, token: Object());
    await settle();
    await service.clearPreload();
    gate.complete(second);
    await preparing;
    expect(deck.playlist!.children, hasLength(1));
    expect(service.preloadedUrl, isNull);
  });

  test(
      'crossfade swaps stable streams, keeps master volume, and ignores outgoing completion',
      () async {
    final outgoing = _Deck();
    final incoming = _Deck();
    final service = AudioPlayerService(
        player: outgoing,
        preloadPlayer: incoming,
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    final positions = <Duration>[];
    final volumes = <double>[];
    final events = <Object>[];
    var completions = 0;
    service.positionStream.listen(positions.add);
    service.volumeStream.listen(volumes.add);
    service.handoffStream.listen(events.add);
    service.completionStream.listen((_) => completions++);
    await service.playFromUrl(first);
    await service.setVolume(.4);
    final token = Object();
    await service.prepareNext(second,
        token: token, crossfade: const Duration(seconds: 5));
    outgoing.tick(const Duration(seconds: 56));
    await settle();
    expect(events, [token]);
    expect(service.currentUrl, second);
    expect(incoming.starts, 1);
    incoming.tick(const Duration(seconds: 2));
    outgoing.tick(const Duration(seconds: 58));
    outgoing.complete();
    await settle();
    expect(positions.last, const Duration(seconds: 2));
    expect(completions, 0);
    expect(service.volume, .4);
    expect(volumes, [.4]);
    await service.setVolume(.7);
    expect(outgoing.level + incoming.level, closeTo(.7, .01));
    await service.pause();
    expect(outgoing.running, isFalse);
    expect(incoming.running, isFalse);
    expect(incoming.level, .7);
    expect(service.volume, .7);
  });

  test('short track fade begins at no more than half of either track',
      () async {
    final outgoing = _Deck()..length = const Duration(seconds: 10);
    final incoming = _Deck()..length = const Duration(seconds: 4);
    final service = AudioPlayerService(
        player: outgoing,
        preloadPlayer: incoming,
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    await service.playFromUrl(first);
    await service.prepareNext(second,
        token: Object(), crossfade: const Duration(seconds: 12));
    outgoing.tick(const Duration(seconds: 7));
    await settle();
    expect(incoming.starts, 0);
    outgoing.tick(const Duration(seconds: 8));
    await settle();
    expect(incoming.starts, 1);
  });

  test(
      'seeking preserves the pending occurrence and rejects an older restage after queue edits',
      () async {
    final deck = _Deck();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    await service.playFromUrl(first);
    final secondToken = Object();
    final thirdToken = Object();
    final events = <Object>[];
    service.handoffStream.listen(events.add);
    await service.prepareNext(second, token: secondToken);
    await service.seek(const Duration(seconds: 5));
    expect(service.preloadedUrl, second);
    deck.seekGate = Completer<void>();
    final seeking = service.seek(const Duration(seconds: 10));
    await settle();
    await service.prepareNext(third, token: thirdToken);
    deck.seekGate!.complete();
    await seeking;
    expect(service.preloadedUrl, third);
    deck.advance();
    await settle();
    expect(events, [thirdToken]);
    expect(service.currentUrl, third);
  });

  for (final operation in ['pause', 'seek']) {
    test('$operation commits a due web handoff before canceling preparation',
        () async {
      final engine = _Engine();
      final service = AudioPlayerService(
          player: _Deck(),
          preloadPlayer: _Deck(),
          scheduledEngine: engine,
          mediaUrlResolver: (url) async => url);
      addTearDown(service.dispose);
      final token = Object();
      final events = <Object>[];
      service.handoffStream.listen(events.add);
      await service.playFromUrl(first);
      await service.prepareNext(second, token: token);
      engine.due = true;
      if (operation == 'pause') {
        await service.pause();
      } else {
        await service.seek(const Duration(seconds: 8));
      }
      expect(events, [token]);
      expect(service.currentUrl, second);
      expect(
          engine.elapsed,
          operation == 'pause'
              ? const Duration(milliseconds: 200)
              : const Duration(seconds: 8));
    });
  }

  test('delayed web cleanup cannot clear a newer prepared successor', () async {
    final engine = _Engine();
    final service = AudioPlayerService(
        player: _Deck(),
        preloadPlayer: _Deck(),
        scheduledEngine: engine,
        mediaUrlResolver: (url) async => url);
    addTearDown(service.dispose);
    await service.playFromUrl(first);
    await service.prepareNext(second, token: Object());
    engine.clearGate = Completer<void>();
    final clearing = service.clearPreload();
    final preparing = service.prepareNext(third, token: Object());
    await settle();
    expect(engine.stagedUrls, [second]);
    engine.clearGate!.complete();
    await clearing;
    await preparing;
    expect(engine.stagedUrl, third);
    expect(engine.staged, isNotNull);
  });

  test(
      'web decode limits fall back to progressive playback and ordinary completion',
      () async {
    final engine = _Engine()..fallback = true;
    final deck = _Deck();
    final service = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        scheduledEngine: engine,
        mediaUrlResolver: (url) async => '$url?media_token=fresh');
    addTearDown(service.dispose);
    var completions = 0;
    service.completionStream.listen((_) => completions++);
    await service.playFromUrl(first);
    expect(deck.loaded.single, '$first?media_token=fresh');
    expect(service.currentUrl, first);
    await service.prepareNext(second,
        token: Object(), crossfade: const Duration(seconds: 5));
    expect(deck.playlist!.children, hasLength(1));
    expect(engine.stagedUrls, isEmpty);
    deck.complete();
    await settle();
    expect(completions, 1);
    await service.pause();
    await service.resume();
    expect(engine.loaded, hasLength(1));
    expect(deck.loaded, hasLength(2));
  });
}
