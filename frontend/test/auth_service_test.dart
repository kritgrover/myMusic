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

Map<String, Object> cachedSession() => {
      'auth_token': 'old-token',
      'auth_user_id': 2,
      'auth_username': 'krizzy',
      'auth_tagline': 'Music time',
    };

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
    expect(service.isOfflineSession, isFalse);
    expect(service.userId, 2);
    expect(service.username, 'krizzy');
    expect(service.tagline, 'Music time');
    expect(service.lastLoginError, isNull);
    expect(service.isLoading, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), 'test-token');
    expect(prefs.getInt('auth_user_id'), 2);
    expect(prefs.getString('auth_username'), 'krizzy');
    expect(prefs.getString('auth_api_base_url'), 'http://localhost:8123');
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

  test('offline cold start retains a previously signed-in account', () async {
    const baseUrl = 'http://localhost:8123';
    final online = AuthService(
      apiBaseUrl: baseUrl,
      client: MockClient((_) async => signedIn()),
    );
    expect(await online.login('krizzy', 'krizzy'), isTrue);
    online.dispose();

    final offline = AuthService(
      apiBaseUrl: baseUrl,
      client: MockClient((_) async => throw http.ClientException('No network')),
    );
    addTearDown(offline.dispose);
    await offline.initialize();

    expect(offline.isInitialized, isTrue);
    expect(offline.isLoading, isFalse);
    expect(offline.isAuthenticated, isTrue);
    expect(offline.isOfflineSession, isTrue);
    expect(offline.token, 'test-token');
    expect(offline.userId, 2);
    expect(offline.username, 'krizzy');
    expect(offline.tagline, 'Music time');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), 'test-token');
    expect(prefs.getString('auth_api_base_url'), baseUrl);
  });

  test('stored-session timeout allows offline startup and ignores late success',
      () async {
    SharedPreferences.setMockInitialValues(cachedSession());
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
    expect(service.isAuthenticated, isTrue);
    expect(service.isOfflineSession, isTrue);
    pending.complete(http.Response('{"id":3,"username":"other"}', 200));
    await Future<void>.delayed(Duration.zero);
    expect(service.isAuthenticated, isTrue);
    expect(service.isOfflineSession, isTrue);
    expect(service.userId, 2);
    expect(service.username, 'krizzy');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), 'old-token');
    expect(prefs.getInt('auth_user_id'), 2);
  });

  for (final status in [500, 503]) {
    test('server $status preserves the cached account for offline use',
        () async {
      SharedPreferences.setMockInitialValues(cachedSession());
      final service = AuthService(
        client: MockClient((_) async => http.Response('Unavailable', status)),
      );
      addTearDown(service.dispose);
      await service.initialize();

      expect(service.isAuthenticated, isTrue);
      expect(service.isOfflineSession, isTrue);
      expect(service.userId, 2);
      expect(service.tagline, 'Music time');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), 'old-token');
    });
  }

  for (final status in [401, 403]) {
    test(
        'server $status revokes the cached session instead of allowing offline',
        () async {
      SharedPreferences.setMockInitialValues({
        ...cachedSession(),
        'auth_api_base_url': 'http://localhost:8123',
      });
      final service = AuthService(
        apiBaseUrl: 'http://localhost:8123',
        client: MockClient((_) async => http.Response('Unauthorized', status)),
      );
      addTearDown(service.dispose);
      await service.initialize();

      expect(service.isInitialized, isTrue);
      expect(service.isAuthenticated, isFalse);
      expect(service.isOfflineSession, isFalse);
      expect(service.token, isNull);
      expect(service.userId, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
      expect(prefs.getInt('auth_user_id'), isNull);
      expect(prefs.getString('auth_username'), isNull);
      expect(prefs.getString('auth_tagline'), isNull);
      expect(prefs.getString('auth_api_base_url'), isNull);
    });
  }

  for (final malformed in [
    'not json',
    '[]',
    '{"username":"krizzy"}',
    '{"id":0,"username":"krizzy"}',
    '{"id":"2","username":"krizzy"}',
    '{"id":2,"username":" "}',
    '{"id":2,"username":"krizzy","tagline":42}',
  ]) {
    test('invalid session validation cannot authenticate: $malformed',
        () async {
      SharedPreferences.setMockInitialValues(cachedSession());
      final service = AuthService(
        client: MockClient((_) async => http.Response(malformed, 200)),
      );
      addTearDown(service.dispose);
      await service.initialize();

      expect(service.isInitialized, isTrue);
      expect(service.isLoading, isFalse);
      expect(service.isAuthenticated, isFalse);
      expect(service.isOfflineSession, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
    });
  }

  for (final invalidField in <String, Object?>{
    'auth_token': ' ',
    'auth_user_id': 0,
    'auth_username': '',
    'auth_tagline': 42,
  }.entries) {
    test('invalid cached ${invalidField.key} cannot open offline', () async {
      SharedPreferences.setMockInitialValues({
        ...cachedSession(),
        invalidField.key: invalidField.value!,
      });
      var requests = 0;
      final service = AuthService(client: MockClient((_) async {
        requests++;
        throw http.ClientException('No network');
      }));
      addTearDown(service.dispose);
      await service.initialize();

      expect(requests, 0);
      expect(service.isInitialized, isTrue);
      expect(service.isAuthenticated, isFalse);
      expect(service.isOfflineSession, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
    });
  }

  for (final missingField in ['auth_token', 'auth_user_id', 'auth_username']) {
    test('cached session missing $missingField cannot open offline', () async {
      SharedPreferences.setMockInitialValues(
          cachedSession()..remove(missingField));
      final service = AuthService(
        client:
            MockClient((_) async => throw http.ClientException('No network')),
      );
      addTearDown(service.dispose);
      await service.initialize();

      expect(service.isInitialized, isTrue);
      expect(service.isAuthenticated, isFalse);
      expect(service.isOfflineSession, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_token'), isNull);
    });
  }

  test('a valid online session refreshes profile and binds a legacy server',
      () async {
    SharedPreferences.setMockInitialValues(cachedSession());
    final service = AuthService(
      apiBaseUrl: 'http://localhost:8123/',
      client: MockClient((_) async => http.Response(
          '{"id":2,"username":"updated","tagline":"New tagline"}', 200)),
    );
    addTearDown(service.dispose);
    await service.initialize();

    expect(service.isAuthenticated, isTrue);
    expect(service.isOfflineSession, isFalse);
    expect(service.username, 'updated');
    expect(service.tagline, 'New tagline');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_username'), 'updated');
    expect(prefs.getString('auth_api_base_url'), 'http://localhost:8123');
  });

  test('a cached session is never sent to or opened for a different server',
      () async {
    SharedPreferences.setMockInitialValues({
      ...cachedSession(),
      'auth_api_base_url': 'https://original.example',
    });
    var requests = 0;
    final service = AuthService(
      apiBaseUrl: 'https://different.example',
      client: MockClient((_) async {
        requests++;
        return http.Response('{"id":2,"username":"krizzy"}', 200);
      }),
    );
    addTearDown(service.dispose);
    await service.initialize();

    expect(requests, 0);
    expect(service.isAuthenticated, isFalse);
    expect(service.isOfflineSession, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull);
  });

  for (final action in ['logout', 'unauthorized']) {
    test('$action clears an offline session and prevents another offline start',
        () async {
      SharedPreferences.setMockInitialValues(cachedSession());
      final client =
          MockClient((_) async => throw http.ClientException('No network'));
      final service = AuthService(client: client);
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.isOfflineSession, isTrue);

      if (action == 'logout') {
        await service.logout();
      } else {
        await service.handleUnauthorized();
      }
      expect(service.isAuthenticated, isFalse);
      expect(service.isOfflineSession, isFalse);

      final restarted = AuthService(client: client);
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.isInitialized, isTrue);
      expect(restarted.isAuthenticated, isFalse);
      expect(restarted.isOfflineSession, isFalse);
    });
  }

  test('signing in online replaces an offline session', () async {
    SharedPreferences.setMockInitialValues(cachedSession());
    final service = AuthService(client: MockClient((request) async {
      if (request.url.path == '/auth/me') {
        throw http.ClientException('No network');
      }
      return signedIn(id: 3, username: 'other');
    }));
    addTearDown(service.dispose);
    await service.initialize();
    expect(service.isOfflineSession, isTrue);
    expect(await service.login('other', 'password'), isTrue);
    expect(service.isOfflineSession, isFalse);
    expect(service.userId, 3);
    expect(service.username, 'other');
  });
}
