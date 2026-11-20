import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/screens/lyrics_screen.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/lyrics_service.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    for (final unavailable in [false, true]) {
      testWidgets(
          'phone lyrics fits $size with large text, unavailable=$unavailable',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final lyrics = LyricsService(
            client: AuthHttpClient(
                client: MockClient((_) async => unavailable
                    ? http.Response('{"detail":"Lyrics not found"}', 404)
                    : http.Response(
                        jsonEncode({
                          'trackName':
                              'A very long song name that should never crowd out the words below',
                          'artistName':
                              'An artist with a long name and several featured collaborators',
                          'albumName':
                              'An album with an extended title and edition information',
                          'plainLyrics': 'First line\nSecond line\nThird line',
                          'syncedLyrics':
                              '[00:01.00]First line\n[00:02.00]Second line\n[00:03.00]Third line',
                        }),
                        200))));
        var back = 0;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.8),
              padding: const EdgeInsets.only(top: 47, bottom: 34),
            ),
            child: child!,
          ),
          home: Scaffold(
              body: SafeArea(
                  child: LyricsScreen(
            trackName: 'Test song',
            artistName: 'Test artist',
            embedded: true,
            lyricsService: lyrics,
            onBack: () => back++,
          ))),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (unavailable) {
          await tester.ensureVisible(find.text('Try Again'));
          expect(find.text('Lyrics not found'), findsOneWidget);
        } else {
          expect(find.text('First line'), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Back'));
        expect(back, 1);
        await tester.pumpWidget(const SizedBox());
        lyrics.dispose();
      });
    }
  }
}
