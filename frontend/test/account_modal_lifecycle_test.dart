import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/main.dart' as app;
import 'package:music_downloader/screens/home_screen.dart';
import 'package:music_downloader/screens/login_screen.dart';
import 'package:music_downloader/widgets/playback_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const audioMethods = MethodChannel('com.ryanheise.just_audio.methods');
  const sessionMethods = MethodChannel('com.ryanheise.audio_session');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'fixture-token',
      'auth_user_id': 1,
      'auth_username': 'Listener',
      'auth_api_base_url': AppConfig.defaultApiBaseUrl,
    });
    // These checks exercise account routing, not native audio hardware. No
    // source is loaded, but the real account-owned players are disposed.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audioMethods, (_) async => <String, dynamic>{});
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionMethods, (_) async => null);
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(audioMethods, null);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionMethods, null);
  });

  testWidgets('home saves discovery choices and refreshes its recommendations',
      (tester) async {
    var preferences = <String, dynamic>{
      'mode': 'balanced',
      'autoplay': false,
      'onboarding_completed': false,
      'seed_artists': <dynamic>[],
    };
    var recommendationLoads = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(const app.MyApp());
      await tester.pumpAndSettle();
      expect(find.text('Make it yours'), findsOneWidget);
      expect(find.text('Choose artists'), findsOneWidget);
      final before = recommendationLoads;
      await tester.tap(find.widgetWithText(ChoiceChip, 'Discover'));
      await tester.pumpAndSettle();
      expect(preferences['mode'], 'discover');
      expect(recommendationLoads, greaterThan(before));
      expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Discover'))
              .selected,
          isTrue);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(preferences['autoplay'], isTrue);
      expect(preferences['mode'], 'discover');
      await tester.tap(find.text('Choose artists'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final auth =
          tester.widget<HomeScreen>(find.byType(HomeScreen)).authService;
      await auth.logout();
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              if (request.url.path == '/auth/me') {
                return http.Response(
                    '{"id":1,"username":"Listener","tagline":""}', 200);
              }
              if (request.url.path == '/discovery/preferences') {
                if (request.method == 'PATCH') {
                  preferences = {
                    ...preferences,
                    ...jsonDecode(request.body) as Map<String, dynamic>
                  };
                }
                return http.Response(jsonEncode(preferences), 200);
              }
              if (request.url.path == '/discovery/feedback') {
                return http.Response('{"feedback":[]}', 200);
              }
              if (request.url.path == '/recommendations/daily') {
                recommendationLoads++;
              }
              return http.Response('{"detail":"Offline fixture"}', 503);
            }));
  });

  for (final invalidated in [false, true]) {
    testWidgets(
        'account playback sheet is removed after ${invalidated ? 'auth invalidation' : 'logout'}',
        (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const app.MyApp());
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        final auth =
            tester.widget<HomeScreen>(find.byType(HomeScreen)).authService;
        final initialNavigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);

        await tester.tap(find.byTooltip('More player options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Playback settings'));
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackSettingsSheet), findsOneWidget);
        final oldQueue = tester
            .widget<PlaybackSettingsSheet>(find.byType(PlaybackSettingsSheet))
            .queue;

        // These are the same paths used by explicit sign-out and an expired
        // backend token, including persisted credential removal.
        if (invalidated) {
          await auth.handleUnauthorized();
        } else {
          await auth.logout();
        }
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(HomeScreen), findsNothing);
        expect(find.byType(PlaybackSettingsSheet), findsNothing);
        expect(initialNavigator.mounted, isFalse);
        expect(() => ChangeNotifier.debugAssertNotDisposed(oldQueue),
            throwsFlutterError);
        expect(tester.takeException(), isNull);

        // A late rebuild must not reveal the old route or reattach its listener
        // to the disposed playback queue.
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(PlaybackSettingsSheet), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async {
                if (request.url.path == '/auth/me') {
                  return http.Response(
                      jsonEncode({
                        'id': 1,
                        'username': 'Listener',
                        'tagline': '',
                      }),
                      200);
                }
                return http.Response('{"detail":"Offline fixture"}', 503);
              }));
    });
  }
}
