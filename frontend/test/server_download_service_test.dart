import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/server_download_service.dart';
import 'package:music_downloader/widgets/server_download_panel.dart';

DownloadProgress _job(String id,
        {String state = 'running', bool retry = false, String? status}) =>
    DownloadProgress(
      downloadId: id,
      title: 'Song $id',
      state: state,
      canRetry: retry,
      current: state == 'completed' ? 2 : 1,
      total: 2,
      status: status ?? state,
      processed: 1,
      failed: retry ? 1 : 0,
      downloads: [
        {'index': 0, 'success': true, 'filename': 'one.m4a'},
        if (retry) {'index': 1, 'success': false, 'title': 'Missing song'},
      ],
    );

class _Api extends ApiService {
  String scope = 'account-one';
  List<DownloadProgress> restored = [];
  Object? error;
  Completer<List<DownloadProgress>>? pending;
  int loads = 0;
  final cancelled = <String>[];
  final retried = <String>[];

  @override
  String get sessionScope => scope;
  @override
  Future<List<DownloadProgress>> getDownloadJobs() async {
    loads++;
    if (error != null) throw error!;
    if (pending != null) return pending!.future;
    return restored;
  }

  @override
  Future<DownloadProgress> cancelDownloadJob(String id) async {
    cancelled.add(id);
    if (error != null) throw error!;
    return _job(id, state: 'cancelled', retry: true);
  }

  @override
  Future<DownloadProgress> retryDownloadJob(String id) async {
    retried.add(id);
    if (error != null) throw error!;
    return _job(id, state: 'queued');
  }
}

void main() {
  test('restores multiple server jobs and keeps them during an outage',
      () async {
    final api = _Api()..restored = [_job('one'), _job('two', state: 'queued')];
    final service = ServerDownloadService(api: api);
    addTearDown(service.dispose);
    await service.refresh();
    expect(service.jobs.map((job) => job.downloadId), ['one', 'two']);
    api.error = StateError('backend restarting');
    await service.refresh();
    expect(service.jobs.map((job) => job.downloadId), ['one', 'two']);
    expect(service.hasPendingJob, isTrue);
    expect(service.message, contains('reconnect automatically'));
    api.error = null;
    api.restored = [_job('one', state: 'completed'), _job('two')];
    await service.refresh();
    expect(service.featuredJob!.downloadId, 'two');
    expect(service.message, isNull);
  });

  test('never overlaps list requests and ignores old account results',
      () async {
    final api = _Api()..pending = Completer<List<DownloadProgress>>();
    final service = ServerDownloadService(api: api);
    addTearDown(service.dispose);
    final first = service.refresh();
    final second = service.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(api.loads, 1);
    api.scope = 'account-two';
    api.pending!.complete([_job('private-old-account')]);
    await Future.wait([first, second]);
    expect(service.jobs, isEmpty);
    await service.refresh();
    expect(api.loads, 1);
  });

  test('cancel and retry survive an older in-flight status response', () async {
    final api = _Api()..restored = [_job('one')];
    final service = ServerDownloadService(api: api);
    addTearDown(service.dispose);
    await service.refresh();
    api.pending = Completer<List<DownloadProgress>>();
    final stalePoll = service.refresh();
    await Future<void>.delayed(Duration.zero);
    await service.cancel('one');
    api.pending!.complete([_job('one')]);
    await stalePoll;
    expect(service.jobs.single.isCancelled, isTrue);
    expect(service.jobs.single.canRetry, isTrue);
    await service.retry('one');
    expect(service.jobs.single.state, 'queued');
    expect(api.cancelled, ['one']);
    expect(api.retried, ['one']);
    expect(service.jobs.single.processed, 1);
  });

  test('failed actions keep the job available for another attempt', () async {
    final api = _Api()
      ..restored = [_job('one', state: 'completed', retry: true)];
    final service = ServerDownloadService(api: api);
    addTearDown(service.dispose);
    await service.refresh();
    api.error = StateError('private backend diagnostic');
    await service.retry('one');
    expect(service.featuredJob!.downloadId, 'one');
    expect(service.isUpdating('one'), isFalse);
    expect(service.message, contains('Please reconnect and try again'));
    expect(service.message, isNot(contains('private')));
  });

  test('disposing while a poll is pending does not notify a closed view',
      () async {
    final api = _Api()..pending = Completer<List<DownloadProgress>>();
    final service = ServerDownloadService(api: api);
    var notifications = 0;
    service.addListener(() => notifications++);
    final load = service.refresh();
    await Future<void>.delayed(Duration.zero);
    service.dispose();
    api.pending!.complete([_job('one')]);
    await load;
    expect(notifications, 0);
  });

  test('a cancelling process is still tracked until it settles', () {
    final job = _job('one', state: 'cancelled', status: 'Cancelling...');
    expect(job.isActive, isTrue);
    expect(ServerDownloadPanel.label(job), 'Cancelling');
    expect(_job('one', state: 'cancelled', retry: true).isActive, isFalse);
  });

  testWidgets('startup restores jobs and reconnects without user intervention',
      (tester) async {
    final api = _Api()..restored = [_job('restored')];
    final service = ServerDownloadService(
        api: api, pollInterval: const Duration(milliseconds: 100));
    service.start();
    await tester.pump();
    expect(service.jobs.single.downloadId, 'restored');
    api.error = StateError('connection lost');
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.message, contains('reconnect automatically'));
    expect(service.jobs.single.downloadId, 'restored');
    api.error = null;
    api.restored = [_job('restored', state: 'completed')];
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.jobs.single.isCompleted, isTrue);
    expect(service.message, isNull);
    service.dispose();
  });

  testWidgets(
      'restored job dialog exposes queued cancellation and failed retry',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api()
      ..restored = [
        _job('one', state: 'queued'),
        _job('two', state: 'completed', retry: true),
      ];
    final service = ServerDownloadService(api: api);
    addTearDown(service.dispose);
    await service.refresh();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      ServerDownloadPanel(service: service),
    ]))));
    await tester.tap(find.byTooltip('View server downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Song one'), findsOneWidget);
    expect(find.text('Could not download: Missing song'), findsOneWidget);
    await tester.tap(find.text('Cancel download'));
    await tester.pumpAndSettle();
    expect(api.cancelled, ['one']);
    expect(find.text('Cancelled · 2 tracks'), findsOneWidget);
    await tester.tap(find.text('Retry unfinished').first);
    await tester.pumpAndSettle();
    expect(api.retried, ['two']);
    expect(find.text('Queued · 2 tracks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('API restores and controls authenticated jobs with encoded ids',
      () async {
    final requests = <http.Request>[];
    final client = AuthHttpClient(
        baseUrl: 'http://server.test',
        client: MockClient((request) async {
          requests.add(request);
          final job = {
            'download_id': 'one',
            'title': 'Song one',
            'state': 'completed',
            'status': 'completed',
            'can_retry': true,
            'total': 2,
            'current': 2,
            'processed': 1,
            'failed': 1,
            'downloads': []
          };
          return http.Response(
              jsonEncode(request.url.path == '/downloads/jobs'
                  ? {
                      'jobs': [job]
                    }
                  : job),
              200);
        }))
      ..configure(
          tokenProvider: () => 'session-one', onUnauthorized: () async {});
    final api = ApiService(baseUrl: 'http://server.test', client: client);
    final restored = await api.getDownloadJobs();
    expect(restored.single.canRetry, isTrue);
    expect(restored.single.title, 'Song one');
    await api.cancelDownloadJob('batch/one');
    await api.retryDownloadJob('batch/one');
    expect(requests.map((request) => request.method), ['GET', 'POST', 'POST']);
    expect(requests[1].url.toString(),
        'http://server.test/downloads/jobs/batch%2Fone/cancel');
    expect(
        requests.every((request) =>
            request.headers['Authorization'] == 'Bearer session-one'),
        isTrue);
  });

  test('API rejects results returned after the account changes', () async {
    final pending = Completer<http.Response>();
    var token = 'account-one';
    final client = AuthHttpClient(
        baseUrl: 'http://server.test',
        client: MockClient((_) => pending.future))
      ..configure(tokenProvider: () => token, onUnauthorized: () async {});
    final api = ApiService(baseUrl: 'http://server.test', client: client);
    final response = api.getDownloadJobs();
    final rejected = expectLater(response, throwsStateError);
    token = 'account-two';
    pending.complete(http.Response('{"jobs":[]}', 200));
    await rejected;
  });

  test('metadata and job requests have bounded client waits', () async {
    final pending = Completer<http.Response>();
    final client = AuthHttpClient(
        baseUrl: 'http://server.test',
        client: MockClient((_) => pending.future));
    final api = ApiService(
        baseUrl: 'http://server.test',
        client: client,
        metadataTimeout: const Duration(milliseconds: 10),
        jobRequestTimeout: const Duration(milliseconds: 10));
    final metadata = await api.cleanMetadata(
        title: 'Original title', uploader: 'Original artist');
    expect(metadata, {'title': 'Original title', 'artist': 'Original artist'});
    await expectLater(api.getDownloadJobs(), throwsA(isA<TimeoutException>()));
    pending.complete(http.Response('{"jobs":[]}', 200));
  });
}
