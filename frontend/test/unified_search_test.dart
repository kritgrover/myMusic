import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_downloader/models/search_results.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/unified_search_controller.dart';
import 'package:music_downloader/services/unified_search_service.dart';
import 'package:music_downloader/widgets/unified_search_results.dart';

SearchResults result(String title) => SearchResults(songs: [
      SearchEntry(
          {'id': title, 'title': title, 'artist': 'Artist', 'kind': 'track'}),
    ], suggestions: [
      '$title song'
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved library search preserves original catalog recording identity',
      () {
    const saved = SearchEntry({
      'id': 'track_library_hash',
      'source_id': '1234567890123456789012',
      'title': 'Song',
      'artist': 'A, B'
    });
    expect(saved.track.id, '1234567890123456789012');
    const canonical = SearchEntry({
      'id': 'track_library_hash',
      'spotify_id': '9876543210987654321098',
      'source_id': 'video',
      'title': 'Song'
    });
    expect(canonical.track.id, '9876543210987654321098');
  });

  testWidgets('typing debounces across categories and does not pollute history',
      (tester) async {
    final calls = <String>[];
    final state = UnifiedSearchController(
        userId: 1,
        search: (q) async {
          calls.add(q);
          return result(q);
        });
    addTearDown(state.dispose);
    state.updateQuery('first');
    await tester.pump(const Duration(milliseconds: 300));
    state.updateQuery(' final ');
    await tester.pump(const Duration(milliseconds: 349));
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, ['final']);
    expect(state.results.songs.single.title, 'final');
    expect(state.recent, isEmpty);
  });

  test('stale results and autocomplete cannot replace a newer query', () async {
    final pending = Completer<SearchResults>();
    final state = UnifiedSearchController(
        userId: 1,
        search: (q) => q == 'old' ? pending.future : Future.value(result(q)));
    addTearDown(state.dispose);
    final old = state.searchNow('old');
    await state.searchNow('new');
    pending.complete(result('old'));
    await old;
    expect(state.results.songs.single.title, 'new');
    expect(state.suggestions, ['new song']);
  });

  test(
      'library appears before providers and survives a catalog request failure',
      () async {
    final provider = Completer<SearchResults>();
    final state = UnifiedSearchController(
        userId: 1,
        search: (_) => provider.future,
        librarySearch: (_) async => const SearchResults(library: [
              SearchEntry(
                  {'id': 'saved', 'title': 'Saved song', 'kind': 'track'}),
            ]));
    addTearDown(state.dispose);
    final searching = state.searchNow('Saved');
    await Future<void>.delayed(Duration.zero);
    expect(state.isSearching, isTrue);
    expect(state.results.library.single.title, 'Saved song');
    provider.completeError(StateError('provider offline'));
    await searching;
    expect(state.error, isNull);
    expect(state.isSearching, isFalse);
    expect(state.results.library.single.title, 'Saved song');
    expect(state.results.warnings, isNotEmpty);
  });

  test('a late local response cannot overwrite complete catalog results',
      () async {
    final local = Completer<SearchResults>();
    final state = UnifiedSearchController(
        userId: 1,
        search: (q) async => result(q),
        librarySearch: (_) => local.future);
    addTearDown(state.dispose);
    await state.searchNow('music');
    local.complete(const SearchResults(library: [
      SearchEntry({'title': 'late'})
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(state.results.songs.single.title, 'music');
    expect(state.results.library, isEmpty);
  });

  testWidgets('clear cancels debounce and suppresses in-flight failures',
      (tester) async {
    final pending = Completer<SearchResults>();
    var calls = 0;
    final state = UnifiedSearchController(
        userId: 1,
        search: (_) {
          calls++;
          return pending.future;
        });
    addTearDown(state.dispose);
    state.updateQuery('pending');
    state.updateQuery('');
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
    final searching = state.searchNow('running');
    state.updateQuery('');
    pending.completeError(StateError('offline'));
    await searching;
    expect(state.error, isNull);
    expect(state.isSearching, isFalse);
    expect(state.results.isEmpty, isTrue);
  });

  test(
      'retry recovers and history persists, deduplicates, removes, isolates accounts',
      () async {
    var tries = 0;
    final state = UnifiedSearchController(
        userId: 1,
        baseUrl: 'https://music.test',
        search: (q) async {
          if (++tries == 1) throw StateError('offline');
          return result(q);
        });
    addTearDown(state.dispose);
    await state.searchNow('Song');
    expect(state.error, isNotNull);
    await state.retry();
    expect(state.error, isNull);
    await state.remember('song');
    expect(state.recent, ['song']);
    final same =
        UnifiedSearchController(userId: 1, baseUrl: 'https://music.test/');
    final other =
        UnifiedSearchController(userId: 2, baseUrl: 'https://music.test');
    final server =
        UnifiedSearchController(userId: 1, baseUrl: 'https://another.test');
    addTearDown(same.dispose);
    addTearDown(other.dispose);
    addTearDown(server.dispose);
    await Future.wait(
        [same.loadHistory(), other.loadHistory(), server.loadHistory()]);
    expect(same.recent, ['song']);
    expect(other.recent, isEmpty);
    expect(server.recent, isEmpty);
    await same.removeRecent('song');
    await state.loadHistory();
    expect(state.recent, isEmpty);
    await state.remember('another');
    await state.clearHistory();
    await same.loadHistory();
    expect(same.recent, isEmpty);
  });

  test(
      'recent search history stays bounded and completion after disposal is silent',
      () async {
    final pending = Completer<SearchResults>();
    final state =
        UnifiedSearchController(userId: 1, search: (_) => pending.future);
    for (var i = 0; i < 15; i++) {
      await state.remember('query $i');
    }
    expect(state.recent.length, 12);
    expect(state.recent.first, 'query 14');
    final search = state.searchNow('last');
    var changes = 0;
    state.addListener(() => changes++);
    state.dispose();
    pending.complete(result('last'));
    await search;
    expect(changes, 0);
  });

  test('service encodes query and refuses a response from the previous account',
      () async {
    final pending = Completer<http.Response>();
    String? token = 'first';
    late Uri requested;
    final client = AuthHttpClient(
        baseUrl: 'https://music.test',
        client: MockClient((request) {
          requested = request.url;
          expect(request.headers['Authorization'], 'Bearer first');
          return pending.future;
        }))
      ..configure(tokenProvider: () => token, onUnauthorized: () async {});
    final service =
        UnifiedSearchService(baseUrl: 'https://music.test', client: client);
    final searching = service.search('a & b');
    token = 'second';
    pending.complete(http.Response(jsonEncode({'songs': []}), 200));
    await expectLater(searching, throwsStateError);
    expect(requested.queryParameters['q'], 'a & b');
  });

  testWidgets(
      'all five categories, filters and retryable partial results at narrow width',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = UnifiedSearchController(
        userId: 1,
        search: (_) async => const SearchResults(
              songs: [
                SearchEntry({
                  'id': 's',
                  'title': 'Studio song',
                  'kind': 'track',
                  'recording_label': 'Original'
                })
              ],
              artists: [
                SearchEntry(
                    {'id': 'a', 'name': 'Named artist', 'kind': 'artist'})
              ],
              albums: [
                SearchEntry({'id': 'b', 'name': 'Named album', 'kind': 'album'})
              ],
              playlists: [
                SearchEntry({
                  'id': 'p',
                  'name': 'Named playlist',
                  'kind': 'playlist',
                  'provider': 'local'
                })
              ],
              library: [
                SearchEntry({
                  'id': 'l',
                  'title': 'Saved song',
                  'kind': 'track',
                  'library_origin': 'saved'
                })
              ],
              warnings: ['Some catalog results are unavailable.'],
              suggestions: ['Example artist'],
            ));
    addTearDown(state.dispose);
    await state.searchNow('Example');
    String? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UnifiedSearchResults(
      controller: state,
      onSearch: (q) => selected = q,
      onOpen: (_) {},
      trackBuilder: (entry) => ListTile(title: Text(entry.title)),
      browse: const Text('Browse all'),
    ))));
    expect(find.text('Studio song'), findsOneWidget);
    expect(find.text('Some catalog results are unavailable.'), findsOneWidget);
    await tester.tap(find.text('Example artist'));
    expect(selected, 'Example artist');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
    await tester.pump();
    expect(find.text('Named artist'), findsOneWidget);
    expect(find.text('Studio song'), findsNothing);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Your Library'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Your Library'));
    await tester.pump();
    expect(find.text('Saved song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
