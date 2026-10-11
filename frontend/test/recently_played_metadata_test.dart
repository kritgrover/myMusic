import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/recently_played_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const spotifyId = '0123456789abcdefghijkl';

  test('recent recording identity round trips without changing old entries',
      () {
    final old = {
      'type': 'song',
      'id': 'source-a',
      'title': 'Song',
      'artist': 'Artist',
      'url': 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
      'playedAt': '2026-10-11T14:00:00.000',
    };
    final legacy = RecentlyPlayedItem.fromJson(old);
    expect(legacy.album, isNull);
    expect(legacy.duration, isNull);
    expect(legacy.spotifyId, isNull);
    expect(legacy.toJson().containsKey('spotifyId'), isFalse);
    final updated = RecentlyPlayedItem.fromJson({
      ...old,
      'album': 'Album',
      'duration': 181,
      'spotifyId': spotifyId,
    });
    final restored =
        RecentlyPlayedItem.fromJson(jsonDecode(jsonEncode(updated.toJson())));
    expect(restored.album, 'Album');
    expect(restored.duration, 181.0);
    expect(restored.spotifyId, spotifyId);
    expect(restored.url, legacy.url);
  });

  test(
      'recent metadata persists within its account and restores alongside old entries',
      () async {
    SharedPreferences.setMockInitialValues({
      'recently_played_account-a': jsonEncode([
        {
          'type': 'song',
          'id': 'old',
          'title': 'Legacy song',
          'playedAt': '2026-10-10T14:00:00.000',
        }
      ]),
    });
    final service = RecentlyPlayedService(userNamespace: 'account-a');
    await Future<void>.delayed(Duration.zero);
    await service.addSong(
        id: 'new',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: 181.5,
        spotifyId: spotifyId,
        url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
    final restored = RecentlyPlayedService(userNamespace: 'account-a');
    final otherAccount = RecentlyPlayedService(userNamespace: 'account-b');
    await Future<void>.delayed(Duration.zero);
    expect(restored.items, hasLength(2));
    expect(restored.items.first.album, 'Album');
    expect(restored.items.first.duration, 181.5);
    expect(restored.items.first.spotifyId, spotifyId);
    expect(restored.items.last.spotifyId, isNull);
    expect(otherAccount.items, isEmpty);
    service.dispose();
    restored.dispose();
    otherAccount.dispose();
  });
}
