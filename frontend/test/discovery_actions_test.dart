import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/screens/made_for_you_screen.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/widgets/discovery_actions.dart';
import 'package:music_downloader/widgets/horizontal_song_list.dart';
import 'package:music_downloader/widgets/track_tile.dart';

class _Player extends Fake implements PlayerStateService {}

class _Queue extends Fake implements QueueService {}

void main() {
  final song = VideoInfo(
    id: '1234567890123456789012',
    title: 'A favourite song',
    uploader: 'The artist',
    duration: 170,
    url: 'https://open.spotify.com/track/1234567890123456789012',
    thumbnail: '',
    filename: 'listener/favourite.mp3',
    album: 'The album',
  );
  final track = PlaylistTrack.fromVideoInfo(song);

  test(
      'discovery actions retain catalogue identity and owned playback metadata',
      () {
    final item = discoveryTrack(track);
    expect(item.spotifyId, song.id);
    expect(item.originalUrl, song.url);
    expect(item.filename, song.filename);
    expect(item.album, song.album);
    expect(item.duration, 170);
  });

  testWidgets('player menu keeps the active queue recording identity',
      (tester) async {
    const identity = '9876543210987654321098';
    final active = QueueItem(
      id: 'playback-1',
      title: track.title,
      artist: track.artist,
      spotifyId: identity,
      originalUrl: 'https://www.youtube.com/watch?v=abcdefghijk',
    );
    final received = <QueueItem>[];
    await tester.pumpWidget(MaterialApp(
        home: DiscoveryActionScope(
      onStartRadio: received.add,
      onLessLikeThis: received.add,
      child:
          Scaffold(body: DiscoveryTrackMenu(track: track, queueItem: active)),
    )));
    await tester.tap(find.byTooltip('Song discovery options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Less like this'));
    await tester.pumpAndSettle();
    expect(received.single, same(active));
    expect(received.single.spotifyId, identity);
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets('song radio and feedback are reachable on cards at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final radio = <QueueItem>[];
      final hidden = <QueueItem>[];
      var plays = 0;
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, 900), textScaler: const TextScaler.linear(1.5)),
        child: DiscoveryActionScope(
          onStartRadio: radio.add,
          onLessLikeThis: hidden.add,
          child: Scaffold(
              body: HorizontalSongList(
            title: 'Songs for You',
            songs: [song],
            onPlay: (_) => plays++,
            onAddToQueue: (_) {},
            onDownload: (_) {},
            onAddToPlaylist: (_) {},
          )),
        ),
      )));
      await tester.tap(find.byTooltip('Song discovery options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start song radio'));
      await tester.pumpAndSettle();
      expect(radio.single.filename, song.filename);
      expect(radio.single.spotifyId, song.id);
      await tester.tap(find.byTooltip('Song discovery options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Less like this'));
      await tester.pumpAndSettle();
      expect(hidden.single.originalUrl, song.url);
      expect(plays, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'feedback hides cached recommendations but preserves album tracks',
      (tester) async {
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: hidden,
      builder: (_, hide, child) => DiscoveryActionScope(
        onStartRadio: (_) {},
        onLessLikeThis: (_) => hidden.value = true,
        isHidden: (item) => hide && item.id == song.id,
        child: child!,
      ),
      child: Scaffold(
          body: Column(children: [
        HorizontalSongList(
            title: 'Songs for You',
            songs: [song],
            onPlay: (_) {},
            onAddToQueue: (_) {}),
        TrackTile(
            track: track,
            onPlay: () {},
            onAddToQueue: () {},
            onDownload: () {},
            onAddToPlaylist: () {}),
      ])),
    )));
    expect(find.text(song.title), findsNWidgets(2));
    hidden.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Songs for You'), findsNothing);
    expect(find.text(song.title), findsOneWidget);
    hidden.value = false;
    await tester.pumpAndSettle();
    expect(find.text(song.title), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open recommendation list reacts to hide and undo',
      (tester) async {
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: hidden,
      builder: (_, hide, child) => DiscoveryActionScope(
        onStartRadio: (_) {},
        onLessLikeThis: (_) => hidden.value = true,
        isHidden: (_) => hide,
        child: child!,
      ),
      child: Scaffold(
          body: MadeForYouScreen(
        songs: [song],
        playerStateService: _Player(),
        queueService: _Queue(),
      )),
    )));
    expect(find.text(song.title), findsOneWidget);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Less like this'));
    await tester.pumpAndSettle();
    expect(find.text(song.title), findsNothing);
    hidden.value = false;
    await tester.pumpAndSettle();
    expect(find.text(song.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
