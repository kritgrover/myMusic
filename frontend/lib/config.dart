import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const defaultApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
  static const _serverKey = 'music_server_url_v1';
  static String? _server;

  static String get apiBaseUrl => _server ?? defaultApiBaseUrl;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_serverKey);
    _server = null;
    if (saved != null) {
      try {
        _server = normalizeServerUrl(saved);
      } on FormatException {
        await prefs.remove(_serverKey);
      }
    }
  }

  static Future<void> saveServer(String value) async {
    final normalized = normalizeServerUrl(value);
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_serverKey, normalized)) {
      throw StateError('Could not save the server address. Please try again.');
    }
    _server = normalized;
  }

  /// Servers expose routes at their origin. Do not accept embedded credentials,
  /// URL capabilities, or paths that could misdirect login details.
  static String normalizeServerUrl(String value) {
    var input = value.trim();
    if (input.isEmpty) {
      throw const FormatException('Enter your music server address.');
    }
    if (!input.contains('://')) {
      final candidate = Uri.tryParse('http://$input');
      input =
          '${candidate != null && isLocalHost(candidate.host) ? 'http' : 'https'}://$input';
    }
    final uri = Uri.tryParse(input);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535 ||
        !RegExp(r'^[a-zA-Z0-9.\-:\[\]]+$').hasMatch(uri.host)) {
      throw const FormatException(
          'Use a server address such as http://192.168.1.20:8000, without a path or password.');
    }
    if (uri.scheme == 'http' && !isLocalHost(uri.host)) {
      throw const FormatException(
          'Use HTTPS for a server outside your local network.');
    }
    return uri.replace(path: '').toString();
  }

  static bool isLocalHost(String host) {
    final name = host.toLowerCase();
    if (name == 'localhost' || name == '::1' || name == '[::1]') return true;
    if (name.endsWith('.local') ||
        RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name)) {
      return true;
    }
    final parts = name.split('.').map(int.tryParse).toList();
    if (parts.length != 4 ||
        parts.any((part) => part == null || part < 0 || part > 255) ||
        parts.join('.') != name) {
      return false;
    }
    return parts[0] == 10 ||
        parts[0] == 127 ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31);
  }
}
