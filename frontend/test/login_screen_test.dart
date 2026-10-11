import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/main.dart' as app;
import 'package:music_downloader/screens/login_screen.dart';
import 'package:music_downloader/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> showLogin(WidgetTester tester, AuthService service) async {
    await tester
        .pumpWidget(MaterialApp(home: LoginScreen(authService: service)));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'), 'krizzy');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'krizzy');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
  }

  testWidgets(
      'unreachable backend displays a connection error, not bad credentials',
      (tester) async {
    final service = AuthService(
        client: MockClient(
            (_) async => throw http.ClientException('private details')));
    addTearDown(service.dispose);
    await showLogin(tester, service);
    await tester.pumpAndSettle();
    expect(find.textContaining('Check that the backend is running'),
        findsOneWidget);
    expect(find.text('Invalid username or password'), findsNothing);
    expect(find.textContaining('private details'), findsNothing);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull);
  });

  testWidgets('invalid credentials display the specific credentials error',
      (tester) async {
    final service =
        AuthService(client: MockClient((_) async => http.Response('', 401)));
    addTearDown(service.dispose);
    await showLogin(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('Invalid username or password'), findsOneWidget);
  });

  testWidgets('keyboard submission while waiting cannot start a second login',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final service = AuthService(client: MockClient((_) {
      requests++;
      return pending.future;
    }));
    addTearDown(service.dispose);
    await showLogin(tester, service);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(requests, 1);
    pending.complete(http.Response('', 503));
    await tester.pumpAndSettle();
    expect(find.textContaining('server could not sign you in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('app keeps login form mounted and shows a failed request error',
      (tester) async {
    final pending = Completer<http.Response>();
    await http.runWithClient(() async {
      await tester.pumpWidget(const app.MyApp());
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), 'krizzy');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'), 'krizzy');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
      await tester.pump();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      pending.completeError(http.ClientException('Connection refused'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Check that the backend is running'),
          findsOneWidget);
      final fields =
          tester.widgetList<TextFormField>(find.byType(TextFormField));
      expect(fields.first.controller!.text, 'krizzy');
      expect(fields.last.controller!.text, 'krizzy');
    }, () => MockClient((_) => pending.future));
  });
}
