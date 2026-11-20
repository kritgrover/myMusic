import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/listening_event_store.dart';
import 'package:music_downloader/services/listening_event_store_native.dart';
import 'package:music_downloader/services/listening_event_store_preferences.dart';
import 'package:music_downloader/services/listening_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Audio extends Fake implements AudioPlayerService {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  @override
  bool get isPlaying => true;
  @override
  bool get isBuffering => false;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  String? get currentUrl => 'https://www.youtube.com/watch?v=abcdefghijk';
  @override
  Stream<PlayerState> get stateStream => states.stream;
}

class _ControlledStore implements ListeningEventStore {
  final delegate = MemoryListeningEventStore();
  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool failRead = false;
  bool failWrite = false;
  bool failAck = false;
  @override
  Future<List<Map<String, dynamic>>> read() async {
    if (failRead) throw StateError('Unreadable');
    if (readGate != null) await readGate!.future;
    return delegate.read();
  }

  @override
  Future<void> put(Map<String, dynamic> event) async {
    if (failWrite) throw StateError('Disk full');
    if (writeGate != null) await writeGate!.future;
    return delegate.put(event);
  }

  @override
  Future<void> acknowledge(String eventId, int sequence) async {
    if (failAck) throw StateError('Disk unavailable');
    return delegate.acknowledge(eventId, sequence);
  }
}

Map<String, dynamic> _event(String id, {int sequence = 1, String? startedAt}) =>
    {
      'event_id': id,
      'sequence': sequence,
      'song_title': 'Saved song',
      'artist': 'Artist',
      'listened_seconds': 30.0,
      'duration_seconds': 180.0,
      'end_reason': 'completed',
      if (startedAt != null) 'started_at': startedAt,
    };

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory root;
  late _Audio audio;
  late Duration now;
  late List<ListeningSessionService> services;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mymusic-listening-');
    audio = _Audio();
    now = Duration.zero;
    services = [];
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    for (final service in services) {
      await service.dispose();
    }
    await audio.states.close();
    await root.delete(recursive: true);
  });

  ListeningSessionService tracker(ListeningEventStore store,
      {Future<void> Function(Map<String, dynamic>)? send,
      bool Function()? current,
      String Function()? id,
      Duration timeout = const Duration(seconds: 1)}) {
    final service = ListeningSessionService(
        audio: audio,
        now: () => now,
        wallNow: () => DateTime.utc(2026, 11, 19, 8),
        store: Future.value(store),
        sendEvent: send ?? (_) async => throw StateError('Offline'),
        isSessionCurrent: current,
        eventIdFactory: id,
        sendTimeout: timeout);
    services.add(service);
    return service;
  }

  test('fifty offline listens survive reopening and retain original timestamps',
      () async {
    var id = 0;
    final first = tracker(NativeListeningEventStore.inDirectory(root),
        id: () => 'offline_${++id}');
    await first.ready;
    for (var i = 0; i < 50; i++) {
      first.start(title: 'Song $i', artist: 'Artist');
      now += const Duration(seconds: 30);
      await first.finish('completed');
    }
    await first.dispose();
    final reopened = NativeListeningEventStore.inDirectory(root);
    expect(await reopened.read(), hasLength(50));
    final sent = <Map<String, dynamic>>[];
    final next = tracker(reopened, send: (event) async => sent.add(event));
    await next.ready;
    await next.flush();
    expect(sent, hasLength(50));
    expect(sent.map((event) => event['event_id']).toSet(), hasLength(50));
    expect(
        sent.every(
            (event) => event['started_at'] == '2026-11-19T08:00:00.000Z'),
        isTrue);
    expect(await reopened.read(), isEmpty);
  });

  test(
      'checkpoint is durable before send and newer writes survive older acknowledgement',
      () async {
    final store = _ControlledStore();
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final sent = <Map<String, dynamic>>[];
    final service = tracker(store,
        id: () => 'checkpoint_id',
        send: (event) async {
          sent.add(event);
          expect((await store.read()).single['sequence'], event['sequence']);
          await (sent.length == 1 ? firstGate.future : secondGate.future);
        });
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 5);
    final sending = service.flush();
    await _settle();
    expect(sent, hasLength(1));
    now = const Duration(seconds: 9);
    await service.persistPending();
    expect((await store.read()).single['sequence'], 2);
    firstGate.complete();
    await _settle();
    expect(sent, hasLength(2));
    expect((await store.read()).single['sequence'], 2);
    secondGate.complete();
    await sending;
    expect(await store.read(), isEmpty);
  });

  test(
      'lost server acknowledgement retries the exact same persisted occurrence',
      () async {
    final store = NativeListeningEventStore.inDirectory(root);
    final attempts = <Map<String, dynamic>>[];
    final first = tracker(store,
        id: () => 'lost_ack_id',
        send: (event) async {
          attempts.add(event);
          throw StateError('Response lost after server commit');
        });
    first.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 40);
    await first.finish('completed');
    await first.dispose();
    final saved = (await store.read()).single;
    final recovered = tracker(NativeListeningEventStore.inDirectory(root),
        send: (event) async => attempts.add(event));
    await recovered.flush();
    expect(attempts.last, saved);
    expect(
        attempts.every((event) => event['event_id'] == 'lost_ack_id'), isTrue);
    expect(await store.read(), isEmpty);
  });

  test(
      'storage failures prevent sending and retry without forgetting the event',
      () async {
    final store = _ControlledStore()..failWrite = true;
    final sent = <Map<String, dynamic>>[];
    final service = tracker(store,
        id: () => 'storage_error', send: (event) async => sent.add(event));
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 12);
    await service.finish('completed');
    expect(sent, isEmpty);
    expect(service.pendingEventCount, 1);
    expect(service.lastError, contains('save'));
    store.failWrite = false;
    await service.flush();
    expect(sent.single['listened_seconds'], 12);
    expect(await store.read(), isEmpty);
  });

  test(
      'unreadable storage is not overwritten and loaded history merges after recovery',
      () async {
    final store = _ControlledStore()..failRead = true;
    await store.delegate.put(_event('older_event'));
    final sent = <Map<String, dynamic>>[];
    final service = tracker(store,
        id: () => 'newer_event', send: (event) async => sent.add(event));
    service.start(title: 'New', artist: 'Artist');
    now = const Duration(seconds: 10);
    await service.finish('completed');
    expect(sent, isEmpty);
    expect((await store.delegate.read()).single['event_id'], 'older_event');
    store.failRead = false;
    await service.flush();
    expect(sent.map((event) => event['event_id']).toSet(),
        {'older_event', 'newer_event'});
    expect(await store.read(), isEmpty);
  });

  test(
      'checkpoints created during storage load are merged with recovered history',
      () async {
    final gate = Completer<void>();
    final store = _ControlledStore()..readGate = gate;
    await store.delegate.put(_event('prior_event'));
    final service = tracker(store, id: () => 'current_event');
    service.start(title: 'Current', artist: 'Artist');
    now = const Duration(seconds: 10);
    final finished = service.finish('completed', send: false);
    gate.complete();
    await finished;
    expect((await store.read()).map((event) => event['event_id']).toSet(),
        {'prior_event', 'current_event'});
  });

  test(
      'checkpoint updates while a storage write is blocked all finish at newest sequence',
      () async {
    final gate = Completer<void>();
    final store = _ControlledStore()..writeGate = gate;
    final service = tracker(store, id: () => 'write_race_id');
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 5);
    final first = service.persistPending();
    await _settle();
    now = const Duration(seconds: 12);
    final finalWrite = service.finish('completed', send: false);
    gate.complete();
    await Future.wait([first, finalWrite]);
    final saved = (await store.read()).single;
    expect(saved['sequence'], 2);
    expect(saved['listened_seconds'], 12);
    expect(saved['end_reason'], 'completed');
  });

  test(
      'logout saves a terminal checkpoint without waiting for an in-flight request',
      () async {
    final gate = Completer<void>();
    final store = _ControlledStore();
    var current = true;
    final service = tracker(store,
        current: () => current,
        id: () => 'logout_event',
        send: (_) => gate.future);
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 5);
    final sending = service.flush();
    await _settle();
    now = const Duration(seconds: 7);
    await service
        .finish('stopped', send: false)
        .timeout(const Duration(milliseconds: 250));
    current = false;
    final saved = (await store.read()).single;
    expect(saved['listened_seconds'], 7);
    expect(saved['end_reason'], 'stopped');
    gate.complete();
    await sending;
    expect((await store.read()).single, saved);
  });

  test(
      'credential invalidation captures latest progress in the original account store',
      () async {
    final store = _ControlledStore();
    var current = true;
    final sent = <Map<String, dynamic>>[];
    final service = tracker(store,
        current: () => current,
        id: () => 'invalidation_id',
        send: (event) async => sent.add(event));
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 9);
    current = false;
    await service.persistPending();
    expect(sent, isEmpty);
    final saved = (await store.read()).single;
    expect(saved['listened_seconds'], 9);
    expect(saved['end_reason'], 'stopped');
    current = true;
    await service.flush();
    expect(sent, isEmpty);
  });

  test('send deadline keeps durable data and allows a later successful replay',
      () async {
    final never = Completer<void>();
    final store = _ControlledStore();
    var online = false;
    final service = tracker(store,
        id: () => 'timeout_event',
        timeout: const Duration(milliseconds: 10),
        send: (_) => online ? Future.value() : never.future);
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 35);
    await service.finish('completed');
    expect(await store.read(), hasLength(1));
    online = true;
    await service.flush();
    expect(await store.read(), isEmpty);
    never.complete();
  });

  test('failed local acknowledgement retains data for idempotent replay',
      () async {
    final store = _ControlledStore()..failAck = true;
    final sent = <Map<String, dynamic>>[];
    final service = tracker(store,
        id: () => 'ack_disk_error', send: (event) async => sent.add(event));
    service.start(title: 'Song', artist: 'Artist');
    now = const Duration(seconds: 20);
    await service.finish('completed');
    expect(await store.read(), hasLength(1));
    store.failAck = false;
    await service.flush();
    expect(sent.last, sent.first);
    expect(await store.read(), isEmpty);
  });

  test(
      'native storage ignores incomplete and corrupt files without losing valid entries',
      () async {
    final store = NativeListeningEventStore.inDirectory(root);
    await store.put(_event('valid_event'));
    await File('${root.path}/invalid_event.json').writeAsString('{broken');
    await File('${root.path}/staged_event.json.part').writeAsString(
        jsonEncode({'version': 1, 'event': _event('staged_event')}));
    await File('${root.path}/ancient_event.json').writeAsString(jsonEncode({
      'version': 1,
      'event': _event('ancient_event', startedAt: '0001-01-01T00:00:00Z')
    }));
    expect((await store.read()).single['event_id'], 'valid_event');
    expect(await File('${root.path}/staged_event.json.part').exists(), isTrue);
  });

  test(
      'a relogged-in tracker discovers checkpoints written late by the old session',
      () async {
    final oldStore = NativeListeningEventStore.inDirectory(root);
    final newStore = NativeListeningEventStore.inDirectory(root);
    await oldStore.put(_event('relogin_event'));
    final sent = <Map<String, dynamic>>[];
    final current = tracker(newStore, send: (event) async => sent.add(event));
    await current.flush();
    expect(sent.single['sequence'], 1);
    expect(await newStore.read(), isEmpty);
    // The old session's final local save can outlive logout/network delivery.
    await oldStore.put(_event('relogin_event', sequence: 2));
    await current.flush();
    expect(sent.map((event) => event['sequence']), [1, 2]);
    expect(await newStore.read(), isEmpty);
  });

  for (final native in [true, false]) {
    test(
        '${native ? 'native' : 'browser'} store rejects stale writes and stale acknowledgements across instances',
        () async {
      final ListeningEventStore first = native
          ? NativeListeningEventStore.inDirectory(root)
          : PreferencesListeningEventStore('account_one');
      final ListeningEventStore second = native
          ? NativeListeningEventStore.inDirectory(root)
          : PreferencesListeningEventStore('account_one');
      await first.put(_event('shared_event', sequence: 2));
      await Future.wait([
        second.put(_event('shared_event', sequence: 1)),
        first.acknowledge('shared_event', 1),
      ]);
      expect((await second.read()).single['sequence'], 2);
      await second.acknowledge('shared_event', 2);
      expect(await first.read(), isEmpty);
    });
  }

  test(
      'storage scope is stable across sessions and isolated by backend and account',
      () async {
    final a = listeningEventScope(userId: 1, baseUrl: 'https://music.example');
    expect(
        a, listeningEventScope(userId: 1, baseUrl: 'https://music.example/'));
    final b = listeningEventScope(userId: 2, baseUrl: 'https://music.example');
    final c = listeningEventScope(userId: 1, baseUrl: 'https://other.example');
    final first = PreferencesListeningEventStore(a);
    await first.put(_event('account_event'));
    expect(await PreferencesListeningEventStore(a).read(), hasLength(1));
    expect(await PreferencesListeningEventStore(b).read(), isEmpty);
    expect(await PreferencesListeningEventStore(c).read(), isEmpty);
  });
}
