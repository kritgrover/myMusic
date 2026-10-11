import 'dart:convert';

import '../config.dart';
import '../models/search_results.dart';
import 'auth_http_client.dart';

class UnifiedSearchService {
  final AuthHttpClient _client;
  final String baseUrl;
  UnifiedSearchService({AuthHttpClient? client, String? baseUrl})
      : _client = client ?? AuthHttpClient.shared,
        baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  Future<SearchResults> search(String query) => _get('unified', query);

  Future<SearchResults> searchLibrary(String query) => _get('library', query);

  Future<SearchResults> _get(String endpoint, String query) async {
    final scope = _client.cacheScope;
    final response = await _client
        .get(Uri.parse('$baseUrl/search/$endpoint')
            .replace(queryParameters: {'q': query, 'limit': '20'}))
        .timeout(const Duration(seconds: 25));
    if (scope != _client.cacheScope) throw StateError('Account changed');
    if (response.statusCode != 200) throw StateError('Search unavailable');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    // Private artwork stays on the configured backend and uses its auth client.
    for (final key in ['songs', 'artists', 'albums', 'playlists', 'library']) {
      for (final entry
          in (data[key] as List? ?? []).whereType<Map<String, dynamic>>()) {
        final image = entry['thumbnail'];
        if (image is String && image.startsWith('/')) {
          entry['thumbnail'] = Uri.parse(baseUrl).resolve(image).toString();
        }
      }
    }
    return SearchResults.fromJson(data);
  }
}
