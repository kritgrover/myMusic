import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

typedef AuthTokenProvider = String? Function();
typedef UnauthorizedCallback = Future<void> Function();

class AuthHttpClient {
  static final AuthHttpClient shared = AuthHttpClient();

  final http.Client _client;
  final String baseUrl;

  AuthHttpClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  AuthTokenProvider? _tokenProvider;
  UnauthorizedCallback? _unauthorizedCallback;
  String? _lastToken;
  int _sessionRevision = 0;
  final String _cacheInstance =
      DateTime.now().microsecondsSinceEpoch.toString();

  /// Non-secret cache scope changes whenever the active session changes.
  String get cacheScope {
    final token = _tokenProvider?.call();
    if (_lastToken != token) {
      _lastToken = token;
      _sessionRevision++;
    }
    return '$_cacheInstance-$_sessionRevision';
  }

  void configure({
    required AuthTokenProvider tokenProvider,
    required UnauthorizedCallback onUnauthorized,
  }) {
    _sessionRevision++;
    _tokenProvider = tokenProvider;
    _unauthorizedCallback = onUnauthorized;
  }

  /// Artwork on other hosts must never receive the user's backend token.
  bool isBackendUrl(String url) {
    final target = Uri.tryParse(url);
    final backend = Uri.tryParse(baseUrl);
    if (target == null ||
        backend == null ||
        !target.hasAuthority ||
        !backend.hasAuthority ||
        target.userInfo.isNotEmpty ||
        (target.scheme != 'http' && target.scheme != 'https') ||
        target.scheme != backend.scheme ||
        target.host != backend.host ||
        target.port != backend.port) {
      return false;
    }
    return true;
  }

  Map<String, String> authHeadersForUrl(String url) =>
      isBackendUrl(url) ? _headers(Uri.parse(url), null) : const {};

  /// Flutter's NetworkImage cache key omits HTTP headers. Partition private
  /// image URLs by session so a later account cannot see earlier image bytes.
  String cacheScopedUrl(String url) {
    if (!isBackendUrl(url)) return url;
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      '_session': cacheScope,
    }).toString();
  }

  Map<String, String> _headers(Uri url, Map<String, String>? headers) {
    final merged = <String, String>{...?headers};
    final token = _tokenProvider?.call();
    if (isBackendUrl(url.toString()) && token != null && token.isNotEmpty) {
      merged['Authorization'] = 'Bearer $token';
    }
    return merged;
  }

  Future<void> _handleUnauthorized(http.Response response, Uri url,
      String session, String? authorization) async {
    if (isBackendUrl(url.toString()) &&
        response.statusCode == 401 &&
        session == cacheScope &&
        authorization != null &&
        authorization == authHeadersForUrl(url.toString())['Authorization'] &&
        _unauthorizedCallback != null) {
      await _unauthorizedCallback!.call();
    }
  }

  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final session = cacheScope;
    final requestHeaders = _headers(url, headers);
    final response = await _client.get(url, headers: requestHeaders);
    await _handleUnauthorized(
        response, url, session, requestHeaders['Authorization']);
    return response;
  }

  Future<http.Response> post(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final session = cacheScope;
    final requestHeaders = _headers(url, headers);
    final response = await _client.post(url,
        headers: requestHeaders, body: body, encoding: encoding);
    await _handleUnauthorized(
        response, url, session, requestHeaders['Authorization']);
    return response;
  }

  Future<http.Response> put(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final session = cacheScope;
    final requestHeaders = _headers(url, headers);
    final response = await _client.put(url,
        headers: requestHeaders, body: body, encoding: encoding);
    await _handleUnauthorized(
        response, url, session, requestHeaders['Authorization']);
    return response;
  }

  Future<http.Response> delete(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final session = cacheScope;
    final requestHeaders = _headers(url, headers);
    final response = await _client.delete(url,
        headers: requestHeaders, body: body, encoding: encoding);
    await _handleUnauthorized(
        response, url, session, requestHeaders['Authorization']);
    return response;
  }

  http.MultipartRequest multipartRequest(String method, Uri url,
      {Map<String, String>? headers}) {
    final request = http.MultipartRequest(method, url);
    request.headers.addAll(_headers(url, headers));
    return request;
  }

  Future<http.Response> sendMultipart(http.MultipartRequest request) async {
    final session = cacheScope;
    final authorization = request.headers['Authorization'];
    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    await _handleUnauthorized(response, request.url, session, authorization);
    return response;
  }
}
