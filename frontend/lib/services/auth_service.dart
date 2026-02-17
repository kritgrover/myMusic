import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class AuthService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _userIdKey = 'auth_user_id';
  static const String _usernameKey = 'auth_username';
  static const String _taglineKey = 'auth_tagline';

  String? _token;
  int? _userId;
  String? _username;
  String _tagline = '';
  bool _isLoading = false;
  bool _isInitialized = false;

  String? get token => _token;
  int? get userId => _userId;
  String? get username => _username;
  String get tagline => _tagline;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  bool get isAuthenticated => _token != null && _userId != null && _username != null;

  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

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

    _isInitialized = true;
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      );
      if (response.statusCode != 200) {
        return false;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['access_token'] as String?;
      final user = data['user'] as Map<String, dynamic>?;
      if (token == null || user == null) {
        return false;
      }

      _token = token;
      _userId = user['id'] as int?;
      _username = user['username'] as String?;
      _tagline = user['tagline'] as String? ?? '';

      if (_userId == null || _username == null) {
        await _clearSession();
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, _token!);
      await prefs.setInt(_userIdKey, _userId!);
      await prefs.setString(_usernameKey, _username!);
      await prefs.setString(_taglineKey, _tagline);
      return true;
    } catch (_) {
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
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
      final response = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/auth/me'),
        headers: {
          'Authorization': 'Bearer $_token',
        },
      );
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
}
