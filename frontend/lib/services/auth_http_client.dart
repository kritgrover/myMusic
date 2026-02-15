import 'dart:convert';
import 'package:http/http.dart' as http;

typedef AuthTokenProvider = String? Function();
typedef UnauthorizedCallback = Future<void> Function();

class AuthHttpClient {
  static final AuthHttpClient shared = AuthHttpClient._internal();

  AuthHttpClient._internal();

  AuthTokenProvider? _tokenProvider;
  UnauthorizedCallback? _unauthorizedCallback;

  void configure({
    required AuthTokenProvider tokenProvider,
    required UnauthorizedCallback onUnauthorized,
  }) {
    _tokenProvider = tokenProvider;
    _unauthorizedCallback = onUnauthorized;
  }

  Map<String, String> _headers(Map<String, String>? headers) {
    final merged = <String, String>{...?headers};
    final token = _tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      merged['Authorization'] = 'Bearer $token';
    }
    return merged;
  }

  Future<void> _handleUnauthorized(http.Response response) async {
    if (response.statusCode == 401 && _unauthorizedCallback != null) {
      await _unauthorizedCallback!.call();
    }
  }

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final response = await http.get(url, headers: _headers(headers));
    await _handleUnauthorized(response);
    return response;
  }

  Future<http.Response> post(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final response = await http.post(url, headers: _headers(headers), body: body, encoding: encoding);
    await _handleUnauthorized(response);
    return response;
  }

  Future<http.Response> put(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final response = await http.put(url, headers: _headers(headers), body: body, encoding: encoding);
    await _handleUnauthorized(response);
    return response;
  }

  Future<http.Response> delete(Uri url, {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final response = await http.delete(url, headers: _headers(headers), body: body, encoding: encoding);
    await _handleUnauthorized(response);
    return response;
  }

  http.MultipartRequest multipartRequest(String method, Uri url, {Map<String, String>? headers}) {
    final request = http.MultipartRequest(method, url);
    request.headers.addAll(_headers(headers));
    return request;
  }

  Future<http.Response> sendMultipart(http.MultipartRequest request) async {
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    await _handleUnauthorized(response);
    return response;
  }
}
