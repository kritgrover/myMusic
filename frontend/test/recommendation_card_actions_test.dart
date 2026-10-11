import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/widgets/horizontal_song_list.dart';
import 'package:music_downloader/widgets/video_card.dart';

void main() {
  final owned = VideoInfo(
    id: 'owned-1',
    title: 'Owned recording',
    uploader: 'Local artist',
    duration: 92,
    url: '',
    thumbnail: '',
    filename: 'fixture/owned.mp3',
    album: 'Local album',
  );
  final remote = VideoInfo(
    id: 'remote-1',
    title: 'Remote recording',
    uploader: 'Catalogue artist',
    duration: 180,
    url: 'https://www.youtube.com/watch?v=demo0000001',
    thumbnail: '',
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('horizontal cards queue the complete local track at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final queued = <VideoInfo>[];
      var downloads = 0;
      var plays = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: HorizontalSongList(
        title: 'For you',
        songs: [owned],
        onPlay: (_) => plays++,
        onAddToQueue: queued.add,
        onAddToPlaylist: (_) {},
        onDownload: (_) => downloads++,
      ))));
      await tester.tap(find.byTooltip('Add to queue'));
      await tester.pumpAndSettle();
      expect(queued.single, same(owned));
      expect(queued.single.filename, 'fixture/owned.mp3');
      expect(plays, 0);
      final downloaded = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.download_done));
      expect(downloaded.onPressed, isNull);
      expect(find.byTooltip('Downloaded'), findsOneWidget);
      expect(downloads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('video cards disable owned downloads at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var downloads = 0;
      var queued = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: VideoCard(
        video: owned,
        onAddToQueue: () => queued++,
        onAddToPlaylist: () {},
        onDownload: () => downloads++,
      ))));
      if (width < 600) {
        await tester.tap(find.byTooltip('More song actions'));
        await tester.pumpAndSettle();
        final item = tester.widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, 'Downloaded'));
        expect(item.enabled, isFalse);
        await tester.tap(find.text('Add to queue'));
      } else {
        final button = tester.widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.download_done));
        expect(button.onPressed, isNull);
        await tester.tap(find.byTooltip('Add to queue'));
      }
      await tester.pumpAndSettle();
      expect(downloads, 0);
      expect(queued, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('remote horizontal cards still allow downloading',
      (tester) async {
    final downloaded = <VideoInfo>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: HorizontalSongList(
      title: 'For you',
      songs: [remote],
      onPlay: (_) {},
      onAddToQueue: (_) {},
      onDownload: downloaded.add,
    ))));
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(downloaded.single, same(remote));
  });
}
