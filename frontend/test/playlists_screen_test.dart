import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/screens/playlists_screen.dart';
import 'package:music_downloader/screens/playlist_detail_screen.dart';
import 'package:music_downloader/services/playlist_service.dart';

class FakePlaylistService extends PlaylistService {
  FakePlaylistService(this.load);

  Future<List<Playlist>> Function() load;
  Future<Playlist?> Function(String)? loadOne;

  @override
  Future<List<Playlist>> getAllPlaylists() => load();

  @override
  Future<Playlist?> getPlaylist(String id) async => loadOne?.call(id);
}

Playlist playlist(String name, int day, List<PlaylistTrack> tracks) => Playlist(
      id: name,
      name: name,
      tracks: tracks,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, day),
    );

Widget app(PlaylistService service) => MaterialApp(
      home: Scaffold(body: PlaylistsScreen(playlistService: service)),
    );

void main() {
  testWidgets('library sorts by recent update, name, and track count',
      (tester) async {
    final service = FakePlaylistService(() async => [
          playlist('Alpha mix', 1, [
            PlaylistTrack(id: 'a', title: 'A song', filename: 'a.m4a'),
          ]),
          playlist('Zebra mix', 2, []),
        ]);
    await tester.pumpWidget(app(service));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Zebra mix')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha mix')).dy));

    await tester.tap(find.byTooltip('Sort playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alphabetical').last);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Alpha mix')).dy,
        lessThan(tester.getTopLeft(find.text('Zebra mix')).dy));

    await tester.tap(find.byTooltip('Sort playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most tracks').last);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Alpha mix')).dy,
        lessThan(tester.getTopLeft(find.text('Zebra mix')).dy));
  });

  testWidgets('library search matches songs and artists as well as names',
      (tester) async {
    final service = FakePlaylistService(() async => [
          playlist('Evening mix', 1, [
            PlaylistTrack(
                id: 'a', title: 'Moonlight', artist: 'Luna', filename: ''),
          ]),
          playlist('Morning mix', 2, []),
        ]);
    await tester.pumpWidget(app(service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), ' LUNA ');
    await tester.pump();
    expect(find.text('Evening mix'), findsOneWidget);
    expect(find.text('Morning mix'), findsNothing);

    await tester.enterText(find.byType(TextField), 'moonlight');
    await tester.pump();
    expect(find.text('Evening mix'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear playlist search'));
    await tester.pump();
    expect(find.text('Morning mix'), findsOneWidget);
  });

  testWidgets('failed library load displays retry instead of empty library',
      (tester) async {
    final service =
        FakePlaylistService(() async => throw StateError('offline'));
    await tester.pumpWidget(app(service));
    await tester.pumpAndSettle();
    expect(find.text('No playlists yet'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    service.load = () async => [playlist('Recovered playlist', 1, [])];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered playlist'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('loading completion after leaving library is safe',
      (tester) async {
    final result = Completer<List<Playlist>>();
    final service = FakePlaylistService(() => result.future);
    await tester.pumpWidget(app(service));
    await tester.pumpWidget(const SizedBox.shrink());
    result.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the requested playlist updates the detail view',
      (tester) async {
    final first = playlist('First playlist', 1, []);
    final second = playlist('Second playlist', 2, []);
    final service = FakePlaylistService(() async => [first, second]);
    service.loadOne = (id) async => id == first.id ? first : second;
    Widget selected(String id) => MaterialApp(
          home: Scaffold(
            body: PlaylistsScreen(
              playlistService: service,
              initialPlaylistId: id,
            ),
          ),
        );
    await tester.pumpWidget(selected(first.id));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<PlaylistDetailScreen>(find.byType(PlaylistDetailScreen))
            .playlist
            .id,
        first.id);
    await tester.pumpWidget(selected(second.id));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<PlaylistDetailScreen>(find.byType(PlaylistDetailScreen))
            .playlist
            .id,
        second.id);
    expect(find.text(second.name), findsOneWidget);
    expect(find.text(first.name), findsNothing);
  });

  testWidgets('clearing a one-shot navigation request does not cancel its load',
      (tester) async {
    final target = playlist('Requested playlist', 1, []);
    final result = Completer<Playlist?>();
    final service = FakePlaylistService(() async => [target]);
    service.loadOne = (_) => result.future;
    Widget selected(String? id) => MaterialApp(
          home: Scaffold(
            body: PlaylistsScreen(
              playlistService: service,
              initialPlaylistId: id,
            ),
          ),
        );
    await tester.pumpWidget(selected(target.id));
    await tester.pumpWidget(selected(null));
    result.complete(target);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    expect(find.text(target.name), findsOneWidget);
  });

  testWidgets('loading failure after leaving library is safe', (tester) async {
    final result = Completer<List<Playlist>>();
    final service = FakePlaylistService(() => result.future);
    await tester.pumpWidget(app(service));
    await tester.pumpWidget(const SizedBox.shrink());
    result.completeError(StateError('offline'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
