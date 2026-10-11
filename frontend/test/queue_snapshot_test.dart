import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/queue_service.dart';

QueueItem _item(String id) => QueueItem(id: id, title: id, filename: '$id.m4a');

void main() {
  test(
      'queue round trip preserves duplicate occurrences, selection, shuffle and original order',
      () {
    final queue = QueueService(random: Random(4));
    final restored = QueueService();
    addTearDown(queue.dispose);
    addTearDown(restored.dispose);
    final duplicate = _item('same');
    queue.addAllToQueue(
        [duplicate, _item('b'), duplicate, _item('c'), _item('d')],
        isPlaylistQueue: true);
    queue.setCurrentIndex(1);
    queue.toggleShuffle();
    queue.toggleLoopMode();
    final snapshot =
        jsonDecode(jsonEncode(queue.exportSnapshot())) as Map<String, dynamic>;
    expect(restored.restoreSnapshot(snapshot), isTrue);
    expect(restored.exportSnapshot(), snapshot);
    expect(restored.queue.where((item) => item.id == 'same').length, 2);
    final duplicateIndexes = [
      for (var i = 0; i < restored.queueLength; i++)
        if (restored.queue[i].id == 'same') i
    ];
    expect(
        identical(restored.entryKeyAt(duplicateIndexes.first),
            restored.entryKeyAt(duplicateIndexes.last)),
        isFalse);
    queue.toggleShuffle();
    restored.toggleShuffle();
    expect(restored.queue.map((item) => item.id),
        queue.queue.map((item) => item.id));
    expect(restored.currentIndex, 1);
    expect(restored.loopMode, LoopMode.queue);
  });

  test(
      'malformed individual rows remap selection and original shuffle occurrence indexes',
      () {
    final queue = QueueService();
    final restored = QueueService();
    addTearDown(queue.dispose);
    addTearDown(restored.dispose);
    queue.addAllToQueue([_item('a'), _item('b'), _item('c')]);
    final snapshot = queue.exportSnapshot();
    (snapshot['entries'] as List)[1] = {
      'item': {'id': 123, 'title': 'invalid'}
    };
    snapshot['currentIndex'] = 2;
    snapshot['originalOrder'] = [2, 0, 1];
    snapshot['isShuffled'] = true;
    expect(restored.restoreSnapshot(snapshot), isTrue);
    expect(restored.queue.map((item) => item.id), ['a', 'c']);
    expect(restored.currentIndex, 1);
    expect(restored.exportSnapshot()['originalOrder'], [1, 0]);
  });

  test('invalid permutation, selection and repeat mode fall back safely', () {
    final queue = QueueService()..addAllToQueue([_item('a'), _item('b')]);
    addTearDown(queue.dispose);
    final snapshot = queue.exportSnapshot()
      ..['originalOrder'] = [0, 0]
      ..['currentIndex'] = 400
      ..['isShuffled'] = true
      ..['loopMode'] = 'invalid';
    expect(queue.restoreSnapshot(snapshot), isTrue);
    expect(queue.currentIndex, -1);
    expect(queue.isShuffled, isFalse);
    expect(queue.loopMode, LoopMode.none);
    expect(queue.exportSnapshot()['originalOrder'], [0, 1]);
  });

  test('unsupported or oversized snapshots leave the live queue intact', () {
    final queue = QueueService()..addToQueue(_item('live'));
    addTearDown(queue.dispose);
    expect(queue.restoreSnapshot({'version': 200, 'entries': []}), isFalse);
    expect(
        queue.restoreSnapshot({
          'version': 1,
          'entries': List.filled(QueueService.maxSnapshotEntries + 1, {})
        }),
        isFalse);
    expect(queue.queue.single.id, 'live');
  });

  test(
      'signed URLs, embedded media IDs and private image cache keys are never stored',
      () {
    const url = '${AppConfig.apiBaseUrl}/downloads/song.m4a?media_token=secret';
    final item = QueueItem(
        id: 'video_$url',
        title: 'Song',
        url: url,
        originalUrl:
            'https://www.youtube.com/watch?v=abcdefghijk&access_token=secret',
        thumbnail:
            '${AppConfig.apiBaseUrl}/downloads/song.m4a/artwork?media_token=secret&_session=account-secret');
    final snapshot = QueueService.itemToSnapshot(item);
    expect(jsonEncode(snapshot), isNot(contains('secret')));
    expect(snapshot['url'], '${AppConfig.apiBaseUrl}/downloads/song.m4a');
    expect(snapshot['id'], 'video_${AppConfig.apiBaseUrl}/downloads/song.m4a');
    expect(
        snapshot['originalUrl'], 'https://www.youtube.com/watch?v=abcdefghijk');
  });

  test(
      'restoring metadata-only songs keeps a lazy searchable entry without running resolver',
      () {
    final queue = QueueService();
    addTearDown(queue.dispose);
    var loads = 0;
    final snapshot = {
      'version': 1,
      'entries': [
        {
          'item': {'id': 'spotify', 'title': 'A song', 'artist': 'An artist'}
        }
      ],
      'currentIndex': 0,
      'originalOrder': [0],
      'isShuffled': false,
      'loopMode': 'single'
    };
    expect(
        queue.restoreSnapshot(snapshot, loadStreamingUrl: (_) async {
          loads++;
          return 'audio/test';
        }),
        isTrue);
    expect(loads, 0);
    expect(queue.currentItem?.originalUrl, '');
    expect(queue.loopMode, LoopMode.single);
  });

  test(
      'invalid field types and unsafe local paths do not become playable file references',
      () {
    expect(QueueService.itemFromSnapshot({'id': 'bad', 'url': 123}), isNull);
    final item = QueueService.itemFromSnapshot({
      'id': 'recoverable',
      'title': 'Song',
      'filename': '../../private.mp3',
      'url': 'javascript:alert(1)',
      'thumbnail': 'file:///private.jpg'
    });
    expect(item?.filename, isNull);
    expect(item?.url, isNull);
    expect(item?.thumbnail, isNull);
    expect(item?.originalUrl, '');
  });
}
