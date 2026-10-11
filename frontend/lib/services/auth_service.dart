import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class AuthService extends ChangeNotifier {
  AuthService({
    http.Client? client,
    String? apiBaseUrl,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _apiBaseUrl = (apiBaseUrl ?? AppConfig.apiBaseUrl)
            .replaceFirst(RegExp(r'/+$'), ''),
        _requestTimeout = requestTimeout;

  static const String _tokenKey = 'auth_token';
  static const String _userIdKey = 'auth_user_id';
  static const String _usernameKey = 'auth_username';
  static const String _taglineKey = 'auth_tagline';
  static const String _invalidResponseError =
      'The music server returned an invalid sign-in response. Please try again.';

  final http.Client _client;
  final bool _ownsClient;
  final String _apiBaseUrl;
  final Duration _requestTimeout;

  String? _token;
  int? _userId;
  String? _username;
  String _tagline = '';
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _lastLoginError;

  String? get token => _token;
  int? get userId => _userId;
  String? get username => _username;
  String get tagline => _tagline;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get lastLoginError => _lastLoginError;
  bool get isAuthenticated =>
      _token != null && _userId != null && _username != null;

  Future<void> initialize() async {
    if (_isInitialized || _isLoading) return;
    _isLoading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(_tokenKey);
      _userId = prefs.getInt(_userIdKey);
      _username = prefs.getString(_usernameKey);
      _tagline = prefs.getString(_taglineKey) ?? '';

      if (_token != null) {
        final isValid = await _validateCurrentToken();
        if (!isValid) {
          await _clearSession();
        }
      }
    } finally {
      _isInitialized = true;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> login(String username, String password) async {
    if (_isLoading) return false;
    _isLoading = true;
    _lastLoginError = null;
    notifyListeners();
    try {
      final response = await _client
          .post(
            Uri.parse('$_apiBaseUrl/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'password': password,
            }),
          )
          .timeout(_requestTimeout);
      if (response.statusCode != 200) {
        _lastLoginError = response.statusCode == 401
            ? 'Invalid username or password'
            : 'The music server could not sign you in. Please try again.';
        return false;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        _lastLoginError = _invalidResponseError;
        return false;
      }
      final token = data['access_token'];
      final user = data['user'];
      if (token is! String ||
          token.trim().isEmpty ||
          user is! Map<String, dynamic>) {
        _lastLoginError = _invalidResponseError;
        return false;
      }
      final userId = user['id'];
      final nextUsername = user['username'];
      final tagline = user['tagline'] ?? '';
      if (userId is! int ||
          userId <= 0 ||
          nextUsername is! String ||
          nextUsername.trim().isEmpty ||
          tagline is! String) {
        _lastLoginError = _invalidResponseError;
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      await prefs.setInt(_userIdKey, userId);
      await prefs.setString(_usernameKey, nextUsername);
      await prefs.setString(_taglineKey, tagline);
      _token = token;
      _userId = userId;
      _username = nextUsername;
      _tagline = tagline;
      return true;
    } on TimeoutException {
      _lastLoginError =
          'The music server took too long to respond. Please try again.';
      return false;
    } on http.ClientException {
      _lastLoginError =
          'Could not connect to the music server. Check that the backend is running and try again.';
      return false;
    } on FormatException {
      _lastLoginError = _invalidResponseError;
      return false;
    } catch (_) {
      _lastLoginError = 'Could not sign you in. Please try again.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _lastLoginError = null;
    await _clearSession();
    notifyListeners();
  }

  Future<void> handleUnauthorized() async {
    if (!isAuthenticated) return;
    await _clearSession();
    notifyListeners();
  }

  Future<void> _clearSession() async {
    _token = null;
    _userId = null;
    _username = null;
    _tagline = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_taglineKey);
  }

  Future<bool> _validateCurrentToken() async {
    try {
      final response = await _client.get(
        Uri.parse('$_apiBaseUrl/auth/me'),
        headers: {
          'Authorization': 'Bearer $_token',
        },
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final nextUserId = data['id'] as int?;
      final nextUsername = data['username'] as String?;
      final nextTagline = data['tagline'] as String? ?? '';
      if (nextUserId == null || nextUsername == null) {
        return false;
      }
      _userId = nextUserId;
      _username = nextUsername;
      _tagline = nextTagline;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_userIdKey, _userId!);
      await prefs.setString(_usernameKey, _username!);
      await prefs.setString(_taglineKey, _tagline);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> updateProfileCache({
    required String username,
    required String tagline,
  }) async {
    _username = username;
    _tagline = tagline;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, username);
    await prefs.setString(_taglineKey, tagline);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
