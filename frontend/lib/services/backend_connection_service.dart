import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config.dart';

class BackendConnectionException implements Exception {
  final String message;
  const BackendConnectionException(this.message);
  @override
  String toString() => message;
}

/// The pre-login probe deliberately uses an unauthenticated client.
class BackendConnectionService {
  final bool _requireSecureTransport;

  BackendConnectionService({bool? requireSecureTransport})
      : _requireSecureTransport = requireSecureTransport ??
            (!kIsWeb &&
                kReleaseMode &&
                defaultTargetPlatform == TargetPlatform.android);

  Future<String> check(String address,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 8)}) async {
    final server = AppConfig.normalizeServerUrl(address);
    if (_requireSecureTransport && Uri.parse(server).scheme != 'https') {
      throw const BackendConnectionException(
          'This Android release requires an HTTPS music server. For local Wi-Fi testing with HTTP, install the Android test build.');
    }
    final connection = client ?? http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$server/'))
        ..followRedirects = false;
      final response = await connection
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw const BackendConnectionException(
            'The server responded, but myMusic is not available at this address.');
      }
      final data = jsonDecode(response.body);
      if (data is! Map ||
          data['message'] != 'Music Download API' ||
          data['status'] != 'running') {
        throw const BackendConnectionException(
            'This address is not a myMusic server.');
      }
      return server;
    } on BackendConnectionException {
      rethrow;
    } on FormatException {
      throw const BackendConnectionException(
          'This address is not a myMusic server.');
    } catch (_) {
      throw const BackendConnectionException(
          'Could not reach your music server. Keep this phone and your PC on the same Wi-Fi, start the server on your PC, and allow Local Network access for myMusic.');
    } finally {
      if (client == null) connection.close();
    }
  }
}
