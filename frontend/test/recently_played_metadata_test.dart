import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/recently_played_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const spotifyId = '0123456789abcdefghijkl';

  test(
      'Jump Back In restores only six newest items and stays capped after plays',
      () async {
    SharedPreferences.setMockInitialValues({
      'recently_played_cap': jsonEncode(List.generate(
          8,
          (index) => {
                'type': 'song',
                'id': 'song-$index',
                'title': 'Song $index',
                'playedAt': DateTime.utc(2026, 1, index + 1).toIso8601String(),
              })),
    });
    final service = RecentlyPlayedService(userNamespace: 'cap');
    addTearDown(service.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(service.items.map((item) => item.id),
        ['song-7', 'song-6', 'song-5', 'song-4', 'song-3', 'song-2']);
    await service.addPlaylist(playlistId: 'playlist', title: 'Playlist');
    await service.addSong(id: 'song-5', title: 'Song 5');
    expect(service.items.map((item) => item.id),
        ['song-5', 'playlist', 'song-7', 'song-6', 'song-4', 'song-3']);
    final restored = RecentlyPlayedService(userNamespace: 'cap');
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(restored.items, hasLength(6));
    expect(restored.items.map((item) => item.id).toSet(),
        service.items.map((item) => item.id).toSet());
  });

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
