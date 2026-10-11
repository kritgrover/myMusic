import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/search_results.dart';
import 'unified_search_service.dart';

/// One request generation covers debounce, results, errors, and autocomplete.
/// Recent searches are explicit submissions/selections, never every keystroke.
class UnifiedSearchController extends ChangeNotifier {
  UnifiedSearchController({
    required int userId,
    String? baseUrl,
    Future<SearchResults> Function(String)? search,
    Future<SearchResults> Function(String)? librarySearch,
    this.debounce = const Duration(milliseconds: 350),
  })  : _search = search ?? UnifiedSearchService(baseUrl: baseUrl).search,
        _librarySearch = librarySearch ??
            (search == null
                ? UnifiedSearchService(baseUrl: baseUrl).searchLibrary
                : null),
        _historyKey = historyKey(userId, baseUrl ?? AppConfig.apiBaseUrl);

  static String historyKey(int userId, String baseUrl) =>
      'search_history_v1_${sha256.convert(utf8.encode(baseUrl.replaceFirst(RegExp(r'/+$'), '')))}_$userId';

  final Future<SearchResults> Function(String) _search;
  final Future<SearchResults> Function(String)? _librarySearch;
  final String _historyKey;
  final Duration debounce;
  Timer? _timer;
  int _generation = 0;
  int _historyRevision = 0;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  String query = '';
  SearchResults results = const SearchResults();
  bool isSearching = false;
  bool hasSearched = false;
  String? error;
  List<String> _recent = [];
  List<String> get recent => List.unmodifiable(_recent);

  List<String> get suggestions {
    if (query.isEmpty) return const [];
    final seen = <String>{query.toLowerCase()};
    return [
      ..._recent.where((q) => q.toLowerCase().startsWith(query.toLowerCase())),
      ...results.suggestions,
    ].where((q) => seen.add(q.toLowerCase())).take(6).toList();
  }

  Future<void> loadHistory() async {
    final revision = _historyRevision;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed || revision != _historyRevision) return;
      _recent = (preferences.getStringList(_historyKey) ?? [])
          .where((q) => q.trim().isNotEmpty && q.length <= 300)
          .take(12)
          .toList();
      notifyListeners();
    } catch (_) {
      // Browsing remains available when local preferences are unavailable.
    }
  }

  Future<void> remember([String? value]) {
    final text = (value ?? query).trim();
    if (_disposed || text.isEmpty || text.length > 300) return Future.value();
    _recent = [
      text,
      ..._recent.where((q) => q.toLowerCase() != text.toLowerCase())
    ].take(12).toList();
    return _saveHistory();
  }

  Future<void> removeRecent(String value) {
    _recent.remove(value);
    return _saveHistory();
  }

  Future<void> clearHistory() {
    _recent = [];
    return _saveHistory();
  }

  Future<void> _saveHistory() {
    _historyRevision++;
    final snapshot = List<String>.of(_recent);
    if (!_disposed) notifyListeners();
    _writes = _writes.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setStringList(_historyKey, snapshot);
      } catch (_) {/* History is best effort; searching is still available. */}
    });
    return _writes;
  }

  void updateQuery(String value) {
    if (_disposed || value.trim() == query) return;
    _prepare(value);
    if (query.isNotEmpty) {
      final request = _generation;
      final text = query;
      _timer = Timer(debounce, () => _run(request, text));
    }
  }

  Future<void> searchNow([String? value]) async {
    if (_disposed) return;
    _prepare(value ?? query);
    if (query.isEmpty) return;
    unawaited(remember());
    await _run(_generation, query);
  }

  Future<void> retry() async {
    if (_disposed || query.isEmpty) return;
    _prepare(query);
    await _run(_generation, query);
  }

  void _prepare(String value) {
    _timer?.cancel();
    _generation++;
    query = value.trim();
    results = const SearchResults();
    isSearching = query.isNotEmpty;
    hasSearched = false;
    error = null;
    notifyListeners();
  }

  Future<void> _run(int request, String text) async {
    final local = _loadLibrary(request, text);
    try {
      final response = await _search(text);
      if (_disposed || request != _generation) return;
      results = response;
    } catch (_) {
      await local;
      if (_disposed || request != _generation) return;
      if (results.isEmpty) {
        error = 'Search could not connect. Please try again.';
      } else {
        results = SearchResults(
            library: results.library,
            playlists: results.playlists,
            warnings: const [
              'Catalog search could not connect. Your library is still available.'
            ]);
      }
    }
    if (_disposed || request != _generation) return;
    isSearching = false;
    hasSearched = true;
    notifyListeners();
  }

  Future<void> _loadLibrary(int request, String text) async {
    if (_librarySearch == null) return;
    try {
      final local = await _librarySearch!(text);
      if (_disposed || request != _generation || !isSearching) return;
      results = local;
      notifyListeners();
    } catch (_) {
      // The combined response supplies a library warning or a second attempt.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _generation++;
    super.dispose();
  }
}
