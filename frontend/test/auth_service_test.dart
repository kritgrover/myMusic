import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response signedIn({String username = 'krizzy', int id = 2}) =>
    http.Response(
        jsonEncode({
          'access_token': 'test-token',
          'user': {'id': id, 'username': username, 'tagline': 'Music time'},
        }),
        200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'successful login sends credentials to configured server and persists session',
      () async {
    final service = AuthService(
      apiBaseUrl: 'http://localhost:8123/',
      client: MockClient((request) async {
        expect(request.url.toString(), 'http://localhost:8123/auth/login');
        expect(request.method, 'POST');
        expect(request.headers['content-type'], 'application/json');
        expect(jsonDecode(request.body),
            {'username': 'krizzy', 'password': 'krizzy'});
        return signedIn();
      }),
    );
    addTearDown(service.dispose);

    expect(await service.login('krizzy', 'krizzy'), isTrue);
    expect(service.isAuthenticated, isTrue);
    expect(service.userId, 2);
    expect(service.username, 'krizzy');
    expect(service.tagline, 'Music time');
    expect(service.lastLoginError, isNull);
    expect(service.isLoading, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), 'test-token');
    expect(prefs.getInt('auth_user_id'), 2);
    expect(prefs.getString('auth_username'), 'krizzy');
  });

  test('401 reports bad credentials without exposing backend details',
      () async {
    final service = AuthService(
        client: MockClient((_) async =>
            http.Response('{"detail":"private database information"}', 401)));
    addTearDown(service.dispose);
    expect(await service.login('krizzy', 'wrong'), isFalse);
    expect(service.lastLoginError, 'Invalid username or password');
    expect(service.isAuthenticated, isFalse);
    expect(service.isLoading, isFalse);
  });

  test('connection failure explains that the backend is unreachable', () async {
    final service = AuthService(
        client: MockClient((_) async =>
            throw http.ClientException('sensitive connection details')));
    addTearDown(service.dispose);
    expect(await service.login('krizzy', 'krizzy'), isFalse);
    expect(
        service.lastLoginError, contains('Check that the backend is running'));
    expect(service.lastLoginError, isNot(contains('sensitive')));
    expect(service.lastLoginError, isNot(contains('Invalid username')));
    expect(service.isLoading, isFalse);
  });

  test('timeout releases login and ignores a late success response', () async {
    final pending = Completer<http.Response>();
    final service = AuthService(
      client: MockClient((_) => pending.future),
      requestTimeout: const Duration(milliseconds: 5),
    );
    addTearDown(service.dispose);
    expect(await service.login('krizzy', 'krizzy'), isFalse);
    expect(service.lastLoginError, contains('too long to respond'));
    expect(service.isLoading, isFalse);
    pending.complete(signedIn());
    await Future<void>.delayed(Duration.zero);
    expect(service.isAuthenticated, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull);
  });

  test(
      'server errors do not claim credentials are incorrect or expose response',
      () async {
    final service = AuthService(
        client: MockClient(
            (_) async => http.Response('private internal exception', 503)));
    addTearDown(service.dispose);
    expect(await service.login('krizzy', 'krizzy'), isFalse);
    expect(service.lastLoginError, contains('server could not sign you in'));
    expect(service.lastLoginError, isNot(contains('private')));
    expect(service.lastLoginError, isNot(contains('Invalid username')));
  });

  for (final malformed in <String>[
    'not json',
    '[]',
    '{"access_token":"token","user":{"username":"krizzy"}}',
    '{"access_token":"","user":{"id":2,"username":"krizzy"}}',
    '{"access_token":"token","user":{"id":"2","username":"krizzy"}}',
  ]) {
    test('malformed success cannot overwrite a valid session: $malformed',
        () async {
      var requests = 0;
      final service = AuthService(
          client: MockClient((_) async =>
              requests++ == 0 ? signedIn() : http.Response(malformed, 200)));
      addTearDown(service.dispose);
      expect(await service.login('krizzy', 'krizzy'), isTrue);
      expect(await service.login('other', 'password'), isFalse);
      expect(service.lastLoginError, contains('invalid sign-in response'));
      expect(service.token, 'test-token');
      expect(service.userId, 2);
      expect(service.username, 'krizzy');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), 'test-token');
      expect(prefs.getInt('auth_user_id'), 2);
      expect(prefs.getString('auth_username'), 'krizzy');
    });
  }

  test('a retry clears the previous error and can sign in', () async {
    var requests = 0;
    final service = AuthService(
        client: MockClient((_) async =>
            requests++ == 0 ? http.Response('', 401) : signedIn()));
    addTearDown(service.dispose);
    expect(await service.login('krizzy', 'wrong'), isFalse);
    expect(service.lastLoginError, isNotNull);
    expect(await service.login('krizzy', 'krizzy'), isTrue);
    expect(service.lastLoginError, isNull);
  });

  test(
      'concurrent submission cannot send a second request or replace its result',
      () async {
    var requests = 0;
    final pending = Completer<http.Response>();
    final service = AuthService(client: MockClient((_) {
      requests++;
      return pending.future;
    }));
    addTearDown(service.dispose);
    final first = service.login('krizzy', 'krizzy');
    expect(service.isLoading, isTrue);
    expect(await service.login('other', 'other'), isFalse);
    pending.complete(signedIn());
    expect(await first, isTrue);
    expect(requests, 1);
    expect(service.username, 'krizzy');
    expect(service.lastLoginError, isNull);
  });

  test('stored-session validation times out instead of blocking startup',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth_token': 'old-token',
      'auth_user_id': 2,
      'auth_username': 'krizzy',
    });
    final pending = Completer<http.Response>();
    final service = AuthService(
      apiBaseUrl: 'http://localhost:8123',
      requestTimeout: const Duration(milliseconds: 5),
      client: MockClient((request) {
        expect(request.url.path, '/auth/me');
        expect(request.headers['authorization'], 'Bearer old-token');
        return pending.future;
      }),
    );
    addTearDown(service.dispose);
    await service.initialize();
    expect(service.isInitialized, isTrue);
    expect(service.isLoading, isFalse);
    expect(service.isAuthenticated, isFalse);
    pending.complete(http.Response('{"id":2,"username":"krizzy"}', 200));
    await Future<void>.delayed(Duration.zero);
    expect(service.isAuthenticated, isFalse);
  });
}
