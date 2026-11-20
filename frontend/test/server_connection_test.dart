import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/config.dart';
import 'package:music_downloader/main.dart' as app;
import 'package:music_downloader/screens/login_screen.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/auth_service.dart';
import 'package:music_downloader/services/backend_connection_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.initialize();
  });
  tearDown(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.initialize();
  });

  test('server addresses normalize private LAN and public HTTPS origins', () {
    expect(AppConfig.normalizeServerUrl(' 192.168.1.20:8000/ '),
        'http://192.168.1.20:8000');
    expect(AppConfig.normalizeServerUrl('music.example.com'),
        'https://music.example.com');
    expect(AppConfig.normalizeServerUrl('http://MY-PC.local:8000/'),
        'http://my-pc.local:8000');
    expect(AppConfig.normalizeServerUrl('http://10.0.2.2:8000'),
        'http://10.0.2.2:8000');
    expect(AppConfig.normalizeServerUrl('http://172.31.0.1:8000'),
        'http://172.31.0.1:8000');
  });

  test('server settings reject embedded secrets, paths and public cleartext',
      () {
    for (final value in [
      '',
      'ftp://192.168.1.20',
      'http://user:secret@192.168.1.20',
      'http://192.168.1.20/api',
      'http://192.168.1.20/?token=secret',
      'http://192.168.1.20/#fragment',
      'http://192.168.1.20:0',
      'http://192.168.1.20:65536',
      'http://172.32.0.1',
      'http://10.999.1.1',
      'http://music.example.com',
      'https://bad host'
    ]) {
      expect(() => AppConfig.normalizeServerUrl(value), throwsFormatException,
          reason: value);
    }
  });

  test('server selection persists and invalid stored settings fall back safely',
      () async {
    await AppConfig.saveServer('192.168.1.20:8000');
    await AppConfig.initialize();
    expect(AppConfig.apiBaseUrl, 'http://192.168.1.20:8000');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'music_server_url_v1', 'https://user:secret@example.com');
    await AppConfig.initialize();
    expect(AppConfig.apiBaseUrl, AppConfig.defaultApiBaseUrl);
    expect(prefs.getString('music_server_url_v1'), isNull);
  });

  test('connection probe uses no credentials and requires the myMusic response',
      () async {
    final probe = BackendConnectionService();
    final client = MockClient((request) async {
      expect(request.url.toString(), 'http://192.168.1.20:8000/');
      expect(request.headers['authorization'], isNull);
      expect(request.followRedirects, isFalse);
      return http.Response(
          jsonEncode({'message': 'Music Download API', 'status': 'running'}),
          200);
    });
    expect(await probe.check('192.168.1.20:8000', client: client),
        'http://192.168.1.20:8000');
    client.close();
    for (final response in [
      http.Response('{}', 200),
      http.Response('no', 200),
      http.Response('', 302),
      http.Response('', 503)
    ]) {
      final wrongServer = MockClient((_) async => response);
      await expectLater(probe.check('192.168.1.20:8000', client: wrongServer),
          throwsA(isA<BackendConnectionException>()));
      wrongServer.close();
    }
  });

  test('connection failures hide internal exception details', () async {
    final client =
        MockClient((_) async => throw http.ClientException('private detail'));
    await expectLater(
        BackendConnectionService().check('192.168.1.20:8000', client: client),
        throwsA(isA<BackendConnectionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('same Wi-Fi'), isNot(contains('private detail'))))));
    client.close();
  });

  test('Android release transport rejects HTTP before reporting a connection',
      () async {
    var requested = false;
    final client = MockClient((_) async {
      requested = true;
      return http.Response(
          '{"message":"Music Download API","status":"running"}', 200);
    });
    final probe = BackendConnectionService(requireSecureTransport: true);
    await expectLater(
        probe.check('192.168.1.20:8000', client: client),
        throwsA(isA<BackendConnectionException>().having(
            (e) => e.message, 'transport explanation', contains('HTTPS'))));
    expect(requested, isFalse);
    expect(await probe.check('https://music.example.com', client: client),
        'https://music.example.com');
    client.close();
  });

  test(
      'changing backend binds credentials only to the new origin and ignores old 401',
      () async {
    final pending = Completer<http.Response>();
    final requests = <http.Request>[];
    final client = AuthHttpClient(
        baseUrl: 'https://first.example',
        client: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) return pending.future;
          return http.Response('{}', 200);
        }));
    var unauthorized = 0;
    client.configure(
        tokenProvider: () => 'first-token',
        onUnauthorized: () async {
          unauthorized++;
        });
    final firstScope = client.cacheScope;
    final oldRequest = client.get(Uri.parse('https://first.example/tracks'));
    await Future<void>.delayed(Duration.zero);
    client.configure(
        baseUrl: 'https://second.example',
        tokenProvider: () => 'second-token',
        onUnauthorized: () async {
          unauthorized++;
        });
    expect(client.cacheScope, isNot(firstScope));
    await client.get(Uri.parse('https://first.example/artwork'));
    await client.get(Uri.parse('https://second.example/tracks'));
    pending.complete(http.Response('', 401));
    await oldRequest;
    expect(requests[0].headers['authorization'], 'Bearer first-token');
    expect(requests[1].headers['authorization'], isNull);
    expect(requests[2].headers['authorization'], 'Bearer second-token');
    expect(unauthorized, 0);
  });

  testWidgets('phone login stays scrollable above keyboard at larger text size',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service =
        AuthService(client: MockClient((_) async => http.Response('', 401)));
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                viewInsets: const EdgeInsets.only(bottom: 260),
                textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home: LoginScreen(
            authService: service,
            serverAddress: 'http://192.168.1.20:8000',
            onChangeServer: () {})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Change server'));
    await tester.pumpAndSettle();
    expect(find.text('Change server').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'saved server switch recreates login and sends its request to new server',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(const app.MyApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change server'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Server address'),
          '192.168.1.20:8000');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('http://192.168.1.20:8000'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), 'listener');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'), 'password');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
      await tester.pumpAndSettle();
      final login = requests.singleWhere((r) => r.url.path == '/auth/login');
      expect(login.url.host, '192.168.1.20');
      expect(login.headers['authorization'], isNull);
      expect(AuthHttpClient.shared.baseUrl, AppConfig.apiBaseUrl);
      expect(find.text('Invalid username or password'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path == '/') {
                return http.Response(
                    '{"message":"Music Download API","status":"running"}', 200);
              }
              return http.Response('', 401);
            }));
  });
}
