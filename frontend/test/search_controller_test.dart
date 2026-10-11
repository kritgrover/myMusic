import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/search_controller.dart';

VideoInfo video(String title) => VideoInfo(
      id: title,
      title: title,
      uploader: 'Artist',
      duration: 180,
      url: 'https://example.com/$title',
      thumbnail: '',
    );

void main() {
  testWidgets('typing is debounced and only searches the latest query',
      (tester) async {
    final queries = <String>[];
    final controller = MusicSearchController(search: (query) async {
      queries.add(query);
      return [video(query)];
    });
    addTearDown(controller.dispose);

    controller.updateQuery('first');
    await tester.pump(const Duration(milliseconds: 250));
    controller.updateQuery(' final ');
    await tester.pump(const Duration(milliseconds: 399));
    expect(queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));

    expect(queries, ['final']);
    expect(controller.results.single.title, 'final');
    expect(controller.hasSearched, isTrue);
    expect(controller.isSearching, isFalse);
  });

  testWidgets('submitting runs immediately without a duplicate debounced call',
      (tester) async {
    var searches = 0;
    final controller = MusicSearchController(search: (_) async {
      searches++;
      return [];
    });
    addTearDown(controller.dispose);
    controller.updateQuery('song');
    await controller.searchNow();
    expect(searches, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(searches, 1);
  });

  test('an older response cannot replace newer results', () async {
    final requests = <String, Completer<List<VideoInfo>>>{};
    final controller = MusicSearchController(search: (query) {
      return (requests[query] = Completer<List<VideoInfo>>()).future;
    });
    addTearDown(controller.dispose);

    final first = controller.searchNow('first');
    final second = controller.searchNow('second');
    requests['second']!.complete([video('new result')]);
    await second;
    requests['first']!.complete([video('stale result')]);
    await first;

    expect(controller.results.single.title, 'new result');
    expect(controller.query, 'second');
  });

  testWidgets('clearing cancels a pending search', (tester) async {
    var searches = 0;
    final controller = MusicSearchController(search: (_) async {
      searches++;
      return [];
    });
    addTearDown(controller.dispose);

    controller.updateQuery('unsubmitted');
    controller.clear();
    await tester.pump(const Duration(seconds: 1));

    expect(searches, 0);
    expect(controller.isSearching, isFalse);
    expect(controller.hasSearched, isFalse);
    expect(controller.query, isEmpty);
  });

  test('clearing suppresses an already running response', () async {
    final result = Completer<List<VideoInfo>>();
    final controller = MusicSearchController(search: (_) => result.future);
    addTearDown(controller.dispose);

    final search = controller.searchNow('song');
    controller.clear();
    result.complete([video('song')]);
    await search;

    expect(controller.results, isEmpty);
    expect(controller.hasSearched, isFalse);
    expect(controller.isSearching, isFalse);
  });

  test('an older failure does not replace newer results with an error',
      () async {
    final oldResult = Completer<List<VideoInfo>>();
    final controller = MusicSearchController(
        search: (query) =>
            query == 'old' ? oldResult.future : Future.value([video('new')]));
    addTearDown(controller.dispose);

    final oldSearch = controller.searchNow('old');
    await controller.searchNow('new');
    oldResult.completeError(StateError('offline'));
    await oldSearch;

    expect(controller.error, isNull);
    expect(controller.results.single.title, 'new');
  });

  test('failed searches offer retry and recover without changing the query',
      () async {
    var attempts = 0;
    final controller = MusicSearchController(search: (query) async {
      if (++attempts == 1) throw StateError('offline');
      return [video(query)];
    });
    addTearDown(controller.dispose);

    await controller.searchNow('song');
    expect(controller.error, isNotNull);
    expect(controller.isSearching, isFalse);
    await controller.retry();
    expect(controller.error, isNull);
    expect(controller.results.single.title, 'song');
    expect(attempts, 2);
  });

  test('completion after disposal does not notify listeners', () async {
    final result = Completer<List<VideoInfo>>();
    final controller = MusicSearchController(search: (_) => result.future);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final search = controller.searchNow('song');
    controller.dispose();
    result.complete([video('song')]);
    await search;
    expect(notifications, 1);
  });
}
