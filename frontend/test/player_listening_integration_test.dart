import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/listening_session_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/recommendation_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final errors = StreamController<String>.broadcast(sync: true);
  final completions = StreamController<void>.broadcast(sync: true);
  bool playing = false;
  bool buffering = false;
  bool failNext = false;
  bool keepOldOnFailure = true;
  String? url;
  Duration elapsed = Duration.zero;
  Duration length = const Duration(seconds: 60);
  int playCalls = 0;
  int resumeCalls = 0;
  @override
  String? get currentUrl => url;
  @override
  bool get isPlaying => playing;
  @override
  bool get isBuffering => buffering;
  @override
  Duration get position => elapsed;
  @override
  Duration get duration => length;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<void> get completionStream => completions.stream;
  @override
  Future<void> playFromUrl(String value) async {
    playCalls++;
    if (failNext) {
      failNext = false;
      if (!keepOldOnFailure) {
        playing = false;
        states.add(PlayerState.stopped);
      }
      throw StateError('Source unavailable');
    }
    url = value;
    elapsed = Duration.zero;
    playing = true;
    states.add(PlayerState.playing);
  }

  @override
  Future<void> playFromBackend(String filename) => playFromUrl(
      '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(filename)}');
  @override
  Future<void> pause() async {
    playing = false;
    states.add(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    playing = true;
    states.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    playing = false;
    states.add(PlayerState.stopped);
    url = null;
  }

  @override
  void restorePaused(String? value,
      {Duration position = Duration.zero, Duration duration = Duration.zero}) {
    url = value;
    elapsed = position;
    length = duration;
    playing = false;
    states.add(PlayerState.paused);
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> preloadUrl(String value) async {}
  void complete() {
    elapsed = length;
    playing = false;
    states.add(PlayerState.stopped);
    completions.add(null);
  }

  @override
  void dispose() {
    states.close();
    errors.close();
    completions.close();
  }
}

class _Recommendations extends Fake implements RecommendationService {
  @override
  String get sessionScope => 'test';
}

Future<void> _settle() async => await Future<void>.delayed(Duration.zero);

void main() {
  late _Audio audio;
  late PlayerStateService player;
  late ListeningSessionService tracker;
  late List<Map<String, dynamic>> sent;
  late Duration now;
  late bool currentSession;
  late int ids;
  Completer<void>? deliveryGate;
  setUp(() {
    audio = _Audio();
    sent = [];
    now = Duration.zero;
    currentSession = true;
    ids = 0;
    deliveryGate = null;
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        isSessionCurrent: () => currentSession,
        eventIdFactory: () => 'occurrence_${++ids}',
        sendEvent: (event) async {
          sent.add(Map.of(event));
          await deliveryGate?.future;
        });
    player = PlayerStateService(
        audioPlayerService: audio,
        recommendationService: _Recommendations(),
        listeningSessionService: tracker);
  });
  tearDown(() async {
    if (deliveryGate != null && !deliveryGate!.isCompleted) {
      deliveryGate!.complete();
    }
    player.dispose();
    await tracker.dispose();
  });

  Future<void> play(String title) =>
      player.playTrack('$title.mp3', trackName: title, trackArtist: 'Artist');

  test(
      'manual skip finalizes prior occurrence; scheduled adoption completes it',
      () async {
    await play('A');
    now = const Duration(seconds: 4);
    await play('B');
    await _settle();
    expect(sent.single['song_title'], 'A');
    expect(sent.single['end_reason'], 'skipped');
    expect(sent.single['listened_seconds'], 4);
    now = const Duration(seconds: 10);
    audio.url = '${AppConfig.apiBaseUrl}/downloads/C.mp3';
    player.adoptScheduledTrack(
        QueueItem(id: 'C', title: 'C', artist: 'Artist', filename: 'C.mp3'));
    await _settle();
    expect(sent.last['song_title'], 'B');
    expect(sent.last['end_reason'], 'completed');
    expect(sent.last['listened_seconds'], 6);
    expect(audio.playCalls, 2); // Adoption neither reloads nor starts again.
    now = const Duration(seconds: 13);
    await player.flushListeningHistory();
    expect(sent.last['song_title'], 'C');
    expect(sent.last['listened_seconds'], 3);
  });

  test('terminal completion then explicit resume creates a new occurrence',
      () async {
    await play('A');
    now = const Duration(seconds: 60);
    audio.complete();
    await _settle();
    final priorId = sent.single['event_id'];
    expect(sent.single['end_reason'], 'completed');
    expect(tracker.hasActiveEvent, false);
    await player.resume();
    now = const Duration(seconds: 65);
    await player.flushListeningHistory();
    expect(sent.last['event_id'], isNot(priorId));
    expect(sent.last['listened_seconds'], 5);
    expect(tracker.hasActiveEvent, true);
  });

  test('skipping the recent-items UI still records actual listening', () async {
    await player.playTrack('A.mp3',
        trackName: 'A', trackArtist: 'Artist', skipRecentlyPlayed: true);
    now = const Duration(seconds: 5);
    await player.flushListeningHistory();
    expect(sent.single['song_title'], 'A');
    expect(sent.single['listened_seconds'], 5);
    expect(sent.single['end_reason'], 'ongoing');
  });

  test('normal pause and resume retain identity and exclude paused time',
      () async {
    await play('A');
    now = const Duration(seconds: 4);
    await player.pause();
    await _settle();
    final id = sent.single['event_id'];
    expect(sent.single['end_reason'], 'paused');
    now = const Duration(seconds: 20);
    await player.resume();
    now = const Duration(seconds: 25);
    await player.flushListeningHistory();
    expect(sent.last['event_id'], id);
    expect(sent.last['listened_seconds'], 9);
  });

  test('paused restoration cannot send history before explicit resume',
      () async {
    await player.preparePaused(
        QueueItem(id: 'A', title: 'A', artist: 'Artist', filename: 'A.mp3'),
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 60));
    now = const Duration(minutes: 1);
    await player.flushListeningHistory();
    expect(sent, isEmpty);
    expect(audio.playCalls, 0);
    expect(tracker.hasActiveEvent, false);
    await player.resume();
    now += const Duration(seconds: 5);
    await player.flushListeningHistory();
    expect(sent.single['song_title'], 'A');
    expect(sent.single['listened_seconds'], 5);
    expect(audio.resumeCalls, 1);
  });

  test('failed replacement keeps prior event if its audio continues playing',
      () async {
    await play('A');
    now = const Duration(seconds: 4);
    audio.failNext = true;
    await expectLater(play('B'), throwsStateError);
    expect(player.currentTrackName, 'A');
    expect(tracker.hasActiveEvent, true);
    now = const Duration(seconds: 10);
    await player.flushListeningHistory();
    expect(sent.single['song_title'], 'A');
    expect(sent.single['end_reason'], 'ongoing');
    expect(sent.single['listened_seconds'], 10);
  });

  test('failed replacement that stops audio ends prior event neutrally',
      () async {
    await play('A');
    now = const Duration(seconds: 4);
    audio.failNext = true;
    audio.keepOldOnFailure = false;
    await expectLater(play('B'), throwsStateError);
    await _settle();
    expect(sent.single['song_title'], 'A');
    expect(sent.single['end_reason'], 'error');
    expect(sent.single['listened_seconds'], 4);
    expect(tracker.hasActiveEvent, false);
  });

  test(
      'logout awaits final checkpoint before account switch and guards disposal',
      () async {
    await play('A');
    now = const Duration(seconds: 5);
    deliveryGate = Completer();
    var finished = false;
    final logoutFlush =
        player.finishListeningSession().then((_) => finished = true);
    await _settle();
    expect(audio.isPlaying, false);
    expect(finished, false);
    deliveryGate!.complete();
    await logoutFlush;
    expect(sent.last['end_reason'], 'stopped');
    expect(sent.last['listened_seconds'], 5);
    currentSession = false;
    final count = sent.length;
    await player.flushListeningHistory();
    await tracker.dispose();
    expect(sent.length, count);
  });
}
