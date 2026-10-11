import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/widgets/source_selection_dialog.dart';

const originalUrl = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';
const liveUrl = 'https://www.youtube.com/watch?v=bbbbbbbbbbb';
const pastedUrl = 'https://www.youtube.com/watch?v=ccccccccccc';
const spotifyId = '0123456789abcdefghijkl';

class _Api extends ApiService {
  String account = 'a';
  String? savedUrl;
  String? savedAlbum;
  String? savedSpotifyId;
  bool reset = false;
  bool failSave = false;
  Completer<SourceCandidates>? pending;

  @override
  String get sessionScope => account;

  @override
  Future<SourceCandidates> sourceCandidates({
    required String title,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
    String? url,
  }) async =>
      pending != null
          ? await pending!.future
          : SourceCandidates(
              candidates: [
                VideoInfo(
                    id: 'aaaaaaaaaaa',
                    title: 'Song (Studio)',
                    uploader: 'Artist - Topic',
                    duration: 180,
                    url: originalUrl,
                    thumbnail: '',
                    recordingType: 'studio'),
                VideoInfo(
                    id: 'bbbbbbbbbbb',
                    title: 'Song (Live at the Arena)',
                    uploader: 'Concert archive',
                    duration: 245,
                    url: liveUrl,
                    thumbnail: '',
                    recordingType: 'live'),
              ],
              selectedUrl: originalUrl,
              remembered: true,
            );

  @override
  Future<void> rememberSource({
    required String title,
    required String url,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
  }) async {
    if (failSave)
      throw const SourceMatchException('Could not save this choice');
    savedUrl = url;
    savedAlbum = album;
    savedSpotifyId = spotifyId;
  }

  @override
  Future<void> resetSource({
    required String title,
    String? artist,
    String? album,
    double? duration,
    String? spotifyId,
  }) async {
    reset = true;
    savedSpotifyId = spotifyId;
  }
}

void main() {
  final track = PlaylistTrack(
    id: spotifyId,
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    filename: '',
    duration: 180,
    url: originalUrl,
  );
  Future<void> mount(WidgetTester tester, _Api api) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => SourceSelectionDialog(
                            track: track, apiService: api)),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
      'compares labels, uploaders and lengths and remembers the selected source',
      (tester) async {
    final api = _Api();
    await mount(tester, api);
    expect(find.textContaining('Studio · 3:00'), findsOneWidget);
    expect(
        find.textContaining('Concert archive · Live · 4:05'), findsOneWidget);
    await tester.ensureVisible(find.text('Song (Live at the Arena)'));
    await tester.tap(find.text('Song (Live at the Arena)'));
    await tester.pump();
    await tester.tap(find.text('Use and remember'));
    await tester.pumpAndSettle();
    expect(api.savedUrl, liveUrl);
    expect(api.savedAlbum, 'Album');
    expect(api.savedSpotifyId, spotifyId);
    expect(find.byType(SourceSelectionDialog), findsNothing);
  });

  testWidgets(
      'a supplied recording can be saved when it is outside the candidates',
      (tester) async {
    final api = _Api();
    await mount(tester, api);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField),
        'https://youtube.com.evil.test/watch?v=ccccccccccc');
    await tester.pump();
    expect(find.text('Enter a valid YouTube video link.'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Use and remember'))
            .onPressed,
        isNull);
    await tester.enterText(
        find.byType(TextField), 'https://youtu.be/ccccccccccc?si=tracking');
    await tester.pump();
    expect(find.text('Selected link: $pastedUrl'), findsOneWidget);
    await tester.tap(find.text('Use and remember'));
    await tester.pumpAndSettle();
    expect(api.savedUrl, pastedUrl);
  });

  testWidgets('automatic matching removes the remembered identity',
      (tester) async {
    final api = _Api();
    await mount(tester, api);
    await tester.tap(find.text('Use automatic match'));
    await tester.pumpAndSettle();
    expect(api.reset, isTrue);
    expect(api.savedSpotifyId, spotifyId);
    expect(find.byType(SourceSelectionDialog), findsNothing);
  });

  testWidgets('a failed save keeps the comparison open for retry',
      (tester) async {
    final api = _Api()..failSave = true;
    await mount(tester, api);
    await tester.tap(find.text('Use and remember'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save this choice'), findsOneWidget);
    expect(find.byType(SourceSelectionDialog), findsOneWidget);
    expect(api.savedUrl, isNull);
  });

  testWidgets('an account switch cannot save the previous account choice',
      (tester) async {
    final api = _Api();
    await mount(tester, api);
    api.account = 'b';
    await tester.tap(find.text('Use and remember'));
    await tester.pumpAndSettle();
    expect(api.savedUrl, isNull);
    expect(find.textContaining('Your account changed.'), findsOneWidget);
    expect(find.text('Song (Studio)'), findsNothing);
  });

  testWidgets(
      'late candidate responses cannot reveal a previous account selection',
      (tester) async {
    final api = _Api()..pending = Completer<SourceCandidates>();
    await mount(tester, api);
    api.account = 'b';
    api.pending!.complete(SourceCandidates(candidates: [
      VideoInfo(
          id: 'private',
          title: 'Previous account choice',
          uploader: '',
          duration: 0,
          url: originalUrl,
          thumbnail: ''),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Previous account choice'), findsNothing);
    expect(find.textContaining('Your account changed.'), findsOneWidget);
  });
}
