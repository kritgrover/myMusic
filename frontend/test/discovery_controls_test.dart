import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/discovery_service.dart';
import 'package:music_downloader/widgets/discovery_controls.dart';

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

class _Backend {
  final preferences = <String, dynamic>{
    'mode': 'balanced',
    'autoplay': false,
    'onboarding_completed': false,
    'seed_artists': [],
  };
  final patches = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> feedback = [];
  Future<http.Response> Function(http.Request)? search;
  late final DiscoveryService service;
  int refreshes = 0;
  _Backend() {
    final client = AuthHttpClient(
        baseUrl: 'https://music.test',
        client: MockClient((request) async {
          if (request.url.path == '/discovery/artists') {
            return search == null
                ? _json({'artists': []})
                : await search!(request);
          }
          if (request.url.path == '/discovery/feedback') {
            return _json({'feedback': feedback});
          }
          if (request.method == 'DELETE') {
            feedback = [];
            return http.Response('', 204);
          }
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            patches.add(body);
            preferences.addAll(body);
          }
          return _json(preferences);
        }));
    client.configure(
        tokenProvider: () => 'account', onUnauthorized: () async {});
    service = DiscoveryService(client: client);
  }
  Future<void> refresh() async => refreshes++;
}

Future<void> _show(WidgetTester tester, _Backend backend,
    {double textScale = 1}) async {
  await backend.service.load();
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: SingleChildScrollView(
              child: DiscoveryControls(
                  service: backend.service, onChanged: backend.refresh)))));
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Choose artists'));
  await tester.tap(find.text('Choose artists'));
  await tester.pumpAndSettle();
}

void main() {
  late _Backend backend;
  tearDown(() => backend.service.dispose());

  testWidgets('controls save each choice, autoplay is opt in, skip is explicit',
      (tester) async {
    backend = _Backend();
    await _show(tester, backend);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
    expect(find.text('Start with artists you love'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    expect(backend.preferences['mode'], 'discover');
    expect(backend.refreshes, 1);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(backend.preferences['autoplay'], isTrue);
    expect(backend.refreshes, 1);
    await tester.ensureVisible(find.text('Skip for now'));
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(backend.preferences['onboarding_completed'], isTrue);
    expect(find.text('Start with artists you love'), findsNothing);
    expect(backend.refreshes, 2);
    expect(backend.patches, [
      {'mode': 'discover'},
      {'autoplay': true},
      {'onboarding_completed': true}
    ]);
  });

  testWidgets(
      'compact controls and dialog support larger text without overflow',
      (tester) async {
    backend = _Backend();
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _show(tester, backend, textScale: 1.8);
    expect(tester.takeException(), isNull);
    await _openPicker(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Skip for now').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(backend.preferences['onboarding_completed'], isTrue);
    expect(backend.preferences['seed_artists'], isEmpty);
  });

  testWidgets('artist search debounces typing and discards stale results',
      (tester) async {
    backend = _Backend();
    final old = Completer<http.Response>();
    final fresh = Completer<http.Response>();
    final queries = <String>[];
    backend.search = (request) {
      final query = request.url.queryParameters['q']!;
      queries.add(query);
      return query == 'old' ? old.future : fresh.future;
    };
    await _show(tester, backend);
    await _openPicker(tester);
    await tester.enterText(find.byType(TextField), 'o');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 300));
    expect(queries, ['old']);
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 300));
    fresh.complete(_json({
      'artists': [
        {'id': 'new', 'name': 'New artist'}
      ]
    }));
    await tester.pumpAndSettle();
    old.complete(_json({
      'artists': [
        {'id': 'old', 'name': 'Old artist'}
      ]
    }));
    await tester.pumpAndSettle();
    expect(find.text('New artist'), findsOneWidget);
    expect(find.text('Old artist'), findsNothing);
  });

  testWidgets(
      'unavailable artist search has a working retry and does not close',
      (tester) async {
    backend = _Backend();
    var attempts = 0;
    backend.search = (request) async {
      attempts++;
      return attempts == 1
          ? _json({'detail': 'private upstream detail'}, 503)
          : _json({
              'artists': [
                {'id': 'a', 'name': 'Recovered artist'}
              ]
            });
    };
    await _show(tester, backend);
    await _openPicker(tester);
    await tester.enterText(find.byType(TextField), 'Artist');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Artist search is unavailable. Please retry.'),
        findsOneWidget);
    expect(find.textContaining('private upstream'), findsNothing);
    await tester.ensureVisible(find.text('Retry search'));
    await tester.tap(find.text('Retry search'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered artist'), findsOneWidget);
    expect(attempts, 2);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('artist picker allows five selections and persists them together',
      (tester) async {
    backend = _Backend();
    backend.search = (request) async => _json({
          'artists': [
            for (var index = 0; index < 6; index++)
              {'id': '$index', 'name': 'Artist $index'}
          ]
        });
    await _show(tester, backend);
    await _openPicker(tester);
    await tester.enterText(find.byType(TextField), 'Artist');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      final choice = find.byType(CheckboxListTile).at(index);
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
    }
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).last)
            .onChanged,
        isNull);
    expect(find.text('5 of 5 selected'), findsOneWidget);
    await tester.tap(find.text('Save artists'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect((backend.preferences['seed_artists'] as List).length, 5);
    expect(backend.preferences['onboarding_completed'], isTrue);
    expect(backend.refreshes, 1);
  });

  testWidgets('saved hidden recommendations can be undone after loading',
      (tester) async {
    backend = _Backend();
    backend.feedback = [
      {
        'feedback_id': 'saved-feedback',
        'track': {'title': 'Hidden song', 'artist': 'An artist'}
      }
    ];
    await _show(tester, backend);
    final song = QueueItem(id: '1', title: 'Hidden song', artist: 'An artist');
    expect(backend.service.isHidden(song), isTrue);
    await tester.ensureVisible(find.text('Hidden recommendations'));
    await tester.tap(find.text('Hidden recommendations'));
    await tester.pumpAndSettle();
    expect(find.text('Hidden song'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('No hidden recommendations.'), findsOneWidget);
    expect(backend.service.isHidden(song), isFalse);
    expect(backend.refreshes, 1);
  });
}
