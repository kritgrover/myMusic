import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/listening_session_service.dart';

class _Audio extends Fake implements AudioPlayerService {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  bool playing = true;
  bool buffering = false;
  Duration length = const Duration(minutes: 3);
  Duration mediaPosition = Duration.zero;
  String? url = 'https://www.youtube.com/watch?v=abcdefghijk';
  @override
  bool get isPlaying => playing;
  @override
  bool get isBuffering => buffering;
  @override
  Duration get duration => length;
  @override
  Duration get position => mediaPosition;
  @override
  String? get currentUrl => url;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  void state(PlayerState value) {
    playing = value == PlayerState.playing;
    buffering = value == PlayerState.buffering;
    states.add(value);
  }
}

Future<void> _settle() async => await Future<void>.delayed(Duration.zero);

void main() {
  late _Audio audio;
  late ListeningSessionService tracker;
  late Duration now;
  late List<Map<String, dynamic>> sent;
  late bool sessionCurrent;
  late int counter;
  setUp(() {
    audio = _Audio();
    now = Duration.zero;
    sent = [];
    sessionCurrent = true;
    counter = 0;
    tracker = ListeningSessionService(
      audio: audio,
      sendEvent: (event) async => sent.add(Map.of(event)),
      isSessionCurrent: () => sessionCurrent,
      now: () => now,
      eventIdFactory: () => 'event_${++counter}_id',
    );
  });
  tearDown(() async {
    await tracker.dispose();
    await audio.states.close();
  });

  test(
      'start and preload produce no zero-time event; actual time ignores seeks',
      () async {
    tracker.start(title: 'One', artist: 'Artist');
    await tracker.flush();
    expect(sent, isEmpty);
    now = const Duration(seconds: 5);
    audio.mediaPosition = const Duration(seconds: 170);
    await tracker.flush();
    expect(sent.single['listened_seconds'], 5);
    audio.mediaPosition = Duration.zero;
    now = const Duration(seconds: 7);
    await tracker.finish('skipped');
    expect(sent.last['listened_seconds'], 7);
    expect(sent.last['sequence'], 2);
    expect(sent.last['event_id'], sent.first['event_id']);
  });

  test('pause and buffering are excluded while resume retains occurrence',
      () async {
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 3);
    audio.state(PlayerState.paused);
    await _settle();
    expect(sent.single['end_reason'], 'paused');
    expect(sent.single['listened_seconds'], 3);
    now = const Duration(seconds: 20);
    audio.state(PlayerState.buffering);
    now = const Duration(seconds: 30);
    audio.state(PlayerState.playing);
    now = const Duration(seconds: 35);
    await tracker.flush();
    expect(sent.last['listened_seconds'], 8);
    expect(sent.last['event_id'], sent.first['event_id']);
    expect(sent.last['end_reason'], 'ongoing');
  });

  test('restored paused state and paused volume changes cannot create a listen',
      () async {
    audio.state(PlayerState.paused);
    now = const Duration(minutes: 1);
    await tracker.flush();
    expect(sent, isEmpty);
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(minutes: 2);
    audio.state(PlayerState.paused);
    await tracker.flush();
    expect(sent, isEmpty);
    audio.state(PlayerState.playing);
    now += const Duration(seconds: 5);
    await tracker.flush();
    expect(sent.single['listened_seconds'], 5);
  });

  test(
      'duplicate track occurrences use new IDs and requested previous final reason',
      () async {
    tracker.start(title: 'Same', artist: 'Artist');
    now = const Duration(seconds: 6);
    tracker.start(
        title: 'Same', artist: 'Artist', previousEndReason: 'completed');
    now = const Duration(seconds: 9);
    await tracker.finish('stopped');
    expect(sent.length, 2);
    expect(sent.first['end_reason'], 'completed');
    expect(sent.first['listened_seconds'], 6);
    expect(sent.last['end_reason'], 'stopped');
    expect(sent.last['listened_seconds'], 3);
    expect(sent.first['event_id'], isNot(sent.last['event_id']));
  });

  test('source is canonical and capabilities never enter event payloads',
      () async {
    const video = 'https://youtu.be/abcdefghijk?si=tracking';
    tracker.start(
        title: ' One\n',
        artist: '\tArtist',
        sourceUrl:
            '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(video)}?media_token=secret');
    now = const Duration(seconds: 5);
    await tracker.finish('completed');
    expect(sent.single['source_url'],
        'https://www.youtube.com/watch?v=abcdefghijk');
    expect(sent.single.toString(), isNot(contains('secret')));
    expect(sent.single['song_title'], 'One');
    expect(
        ListeningSessionService.canonicalSourceUrl(
            'https://youtube.com.evil.test/watch?v=abcdefghijk'),
        isNull);
    expect(
        ListeningSessionService.canonicalSourceUrl(
            'https://user:secret@youtube.com/watch?v=abcdefghijk'),
        isNull);
    expect(
        ListeningSessionService.canonicalSourceUrl(
            'https://youtube.com:444/watch?v=abcdefghijk'),
        isNull);
    expect(
        ListeningSessionService.canonicalSourceUrl(
            '${AppConfig.apiBaseUrl}/downloads/a.mp3?media_token=secret'),
        isNull);
    expect(
        ListeningSessionService.canonicalSourceUrl(
            '${AppConfig.apiBaseUrl}/stream/%xx?media_token=secret'),
        isNull);
  });

  test(
      'failed send retries same immutable event and newest cumulative sequence',
      () async {
    await tracker.dispose();
    final attempts = <Map<String, dynamic>>[];
    var fail = true;
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        eventIdFactory: () => 'retry_event',
        sendEvent: (event) async {
          attempts.add(event);
          if (fail) throw StateError('Offline');
        });
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    await tracker.flush();
    expect(tracker.pendingEventCount, 1);
    expect(tracker.lastError, isNotNull);
    expect(
        () => attempts.first['listened_seconds'] = 99, throwsUnsupportedError);
    now = const Duration(seconds: 8);
    fail = false;
    await tracker.flush();
    expect(attempts.last['event_id'], attempts.first['event_id']);
    expect(attempts.last['sequence'], 2);
    expect(attempts.last['listened_seconds'], 8);
    expect(tracker.pendingEventCount, 0);
    expect(tracker.lastError, isNull);
  });

  test(
      'serial delivery cannot send a newer checkpoint before an older in-flight request',
      () async {
    await tracker.dispose();
    final gate = Completer<void>();
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        eventIdFactory: () => 'serial_event',
        sendEvent: (event) async {
          sent.add(Map.of(event));
          if (sent.length == 1) await gate.future;
        });
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    final first = tracker.flush();
    await _settle();
    now = const Duration(seconds: 10);
    final second = tracker.flush();
    now = const Duration(seconds: 12);
    final finalSend = tracker.finish('completed');
    expect(sent.length, 1);
    gate.complete();
    await Future.wait([first, second, finalSend]);
    expect(sent.length, 2);
    expect(sent.last['sequence'], 3);
    expect(sent.last['listened_seconds'], 12);
    expect(sent.last['end_reason'], 'completed');
  });

  test(
      'failed in-flight checkpoint cannot overwrite pending terminal checkpoint',
      () async {
    await tracker.dispose();
    final gate = Completer<void>();
    var failing = true;
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        eventIdFactory: () => 'terminal_event',
        sendEvent: (event) async {
          sent.add(Map.of(event));
          if (failing) {
            await gate.future;
            throw StateError('Offline');
          }
        });
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    final first = tracker.flush();
    await _settle();
    now = const Duration(seconds: 8);
    final last = tracker.finish('skipped');
    gate.complete();
    await Future.wait([first, last]);
    failing = false;
    await tracker.flush();
    expect(sent.last['end_reason'], 'skipped');
    expect(sent.last['sequence'], 2);
    expect(sent.last['listened_seconds'], 8);
  });

  test('switching account before delivery prevents queued writes', () async {
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    final flushing = tracker.flush();
    sessionCurrent = false;
    await flushing;
    await tracker.dispose();
    expect(sent, isEmpty);
  });

  test(
      'switching account during delivery drops later pending events permanently',
      () async {
    await tracker.dispose();
    final gate = Completer<void>();
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        isSessionCurrent: () => sessionCurrent,
        eventIdFactory: () => 'account_${++counter}',
        sendEvent: (event) async {
          sent.add(Map.of(event));
          await gate.future;
        });
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    final first = tracker.flush();
    await _settle();
    tracker.start(title: 'Two', artist: 'Artist');
    sessionCurrent = false;
    gate.complete();
    await first;
    sessionCurrent = true;
    await tracker.flush();
    expect(sent.length, 1);
    expect(tracker.pendingEventCount, 0);
  });

  test('pending retry queue stays bounded during a long outage', () async {
    await tracker.dispose();
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        eventIdFactory: () => 'bounded_${++counter}',
        sendEvent: (_) async => throw StateError('Offline'));
    for (var i = 0; i < 50; i++) {
      tracker.start(title: 'Song $i', artist: 'Artist');
      now += const Duration(seconds: 1);
      await tracker.finish('skipped');
    }
    expect(tracker.pendingEventCount, ListeningSessionService.maxPendingEvents);
  });

  test(
      'dispose captures a final immutable checkpoint and stops further counting',
      () async {
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 4);
    await tracker.dispose();
    expect(sent.single['end_reason'], 'stopped');
    expect(sent.single['listened_seconds'], 4);
    now = const Duration(minutes: 2);
    audio.state(PlayerState.playing);
    await tracker.flush();
    await tracker.dispose();
    expect(sent.length, 1);
  });

  test(
      'monotonic regressions do not subtract listens and long durations stay bounded',
      () async {
    audio.length = const Duration(days: 2);
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    await tracker.flush();
    now = const Duration(seconds: 2);
    await tracker.flush();
    now = const Duration(days: 3);
    await tracker.finish('completed');
    expect(sent.last['listened_seconds'], 86400);
    expect(sent.last['duration_seconds'], 86400);
    expect(sent.first['listened_seconds'], 5);
  });

  test(
      'provider metadata falls back to actual media source and rejects invalid Spotify IDs',
      () async {
    const source = 'https://www.youtube.com/watch?v=abcdefghijk';
    audio.url =
        '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(source)}?media_token=secret';
    tracker.start(
        title: 'One',
        artist: 'Artist',
        sourceUrl: 'https://open.spotify.com/track/provider_id',
        spotifyId: 'https://open.spotify.com/track/provider_id');
    now = const Duration(seconds: 5);
    await tracker.finish('completed');
    expect(sent.single['source_url'], source);
    expect(sent.single.containsKey('spotify_id'), false);
    tracker.start(title: 'Two', artist: 'Artist', spotifyId: ' valid-id_2 ');
    await tracker.finish('skipped');
    expect(sent.last['spotify_id'], 'valid-id_2');
  });

  test('periodic checkpoints capture cumulative actual time', () async {
    await tracker.dispose();
    tracker = ListeningSessionService(
        audio: audio,
        now: () => now,
        eventIdFactory: () => 'periodic_event',
        checkpointInterval: const Duration(milliseconds: 10),
        sendEvent: (event) async => sent.add(Map.of(event)));
    tracker.start(title: 'One', artist: 'Artist');
    now = const Duration(seconds: 5);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sent.single['listened_seconds'], 5);
    now = const Duration(seconds: 10);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sent.last['listened_seconds'], 10);
    await tracker.finish('completed');
    await tracker.dispose();
  });
}
