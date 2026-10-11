import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Debounces typing and only publishes results for the current search query.
class MusicSearchController extends ChangeNotifier {
  MusicSearchController({
    Future<List<VideoInfo>> Function(String)? search,
    this.debounce = const Duration(milliseconds: 400),
  }) : _search = search ?? ApiService().searchYoutube;

  final Future<List<VideoInfo>> Function(String) _search;
  final Duration debounce;
  Timer? _timer;
  int _requestId = 0;
  bool _disposed = false;
  String _query = '';
  List<VideoInfo> _results = const [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _error;

  String get query => _query;
  List<VideoInfo> get results => _results;
  bool get isSearching => _isSearching;
  bool get hasSearched => _hasSearched;
  String? get error => _error;

  void updateQuery(String value) {
    if (_disposed) return;
    final query = value.trim();
    if (query == _query) return;
    _prepareQuery(query);
    if (query.isNotEmpty) {
      _timer = Timer(debounce, () => _runSearch(_requestId, query));
    }
  }

  Future<void> searchNow([String? value]) async {
    if (_disposed) return;
    final query = (value ?? _query).trim();
    _prepareQuery(query);
    if (query.isNotEmpty) await _runSearch(_requestId, query);
  }

  Future<void> retry() => searchNow();

  void clear() {
    if (!_disposed) _prepareQuery('');
  }

  void _prepareQuery(String query) {
    _timer?.cancel();
    _requestId++;
    _query = query;
    _results = const [];
    _isSearching = query.isNotEmpty;
    _hasSearched = false;
    _error = null;
    notifyListeners();
  }

  Future<void> _runSearch(int requestId, String query) async {
    try {
      final results = await _search(query);
      if (_disposed || requestId != _requestId) return;
      _results = List.unmodifiable(results);
    } catch (_) {
      if (_disposed || requestId != _requestId) return;
      _error = 'Search is unavailable right now. Please try again.';
    }
    if (_disposed || requestId != _requestId) return;
    _isSearching = false;
    _hasSearched = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _requestId++;
    super.dispose();
  }
}
