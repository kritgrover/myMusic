import 'dart:async';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Account-bound view of durable server jobs. The server owns their lifetime;
/// losing a poll or closing this view must not discard or cancel a job.
class ServerDownloadService extends ChangeNotifier {
  final ApiService _api;
  final Duration pollInterval;
  final Duration idleInterval;
  final String _scope;
  int _revision = 0;
  Timer? _timer;
  Future<void>? _loading;
  bool _started = false;
  bool _disposed = false;
  bool _refreshAgain = false;
  List<DownloadProgress> _jobs = [];
  final Set<String> _updating = {};
  String? _message;
  String? _watchedId;

  ServerDownloadService(
      {required ApiService api,
      this.pollInterval = const Duration(seconds: 2),
      this.idleInterval = const Duration(seconds: 10)})
      : _api = api,
        _scope = api.sessionScope;

  List<DownloadProgress> get jobs => List.unmodifiable(_jobs);
  String? get message => _message;
  bool get isRefreshing => _loading != null;
  bool get hasPendingJob =>
      _watchedId != null || _jobs.any((job) => job.isActive);
  bool isUpdating(String id) => _updating.contains(id);
  bool get _current => !_disposed && _scope == _api.sessionScope;

  DownloadProgress? get featuredJob {
    for (final job in _jobs) {
      if (job.isActive) return job;
    }
    for (final job in _jobs) {
      if (job.canRetry) return job;
    }
    return null;
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(refresh());
  }

  void watch(String id) {
    if (!_current) return;
    _watchedId = id;
    _started = true;
    if (_loading != null) _refreshAgain = true;
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (!_current) return Future.value();
    if (_loading != null) return _loading!;
    _timer?.cancel();
    final revision = _revision;
    final task = Future<void>.microtask(() async {
      try {
        final jobs = await _api.getDownloadJobs();
        if (!_current || revision != _revision) return;
        _jobs = jobs;
        if (_jobs.any((job) => job.downloadId == _watchedId)) _watchedId = null;
        _message = null;
      } catch (_) {
        if (!_current || revision != _revision) return;
        _message =
            'Could not reach the server. Downloads will reconnect automatically.';
      } finally {
        _loading = null;
        if (_current) {
          notifyListeners();
          if (_started) {
            final delay = _refreshAgain
                ? Duration.zero
                : (hasPendingJob || _message != null
                    ? pollInterval
                    : idleInterval);
            _refreshAgain = false;
            _timer = Timer(delay, () => unawaited(refresh()));
          }
        }
      }
    });
    _loading = task;
    return task;
  }

  Future<void> cancel(String id) => _update(id, retry: false);
  Future<void> retry(String id) => _update(id, retry: true);

  Future<void> _update(String id, {required bool retry}) async {
    if (!_current || !_updating.add(id)) return;
    _revision++;
    notifyListeners();
    try {
      final job = await (retry
          ? _api.retryDownloadJob(id)
          : _api.cancelDownloadJob(id));
      if (!_current) return;
      _revision++;
      _jobs = [
        for (final old in _jobs)
          if (old.downloadId != id) old,
        job
      ];
      _message = null;
      if (retry) _watchedId = id;
    } catch (_) {
      if (_current) {
        _message = retry
            ? 'Could not retry this download. Please reconnect and try again.'
            : 'Could not cancel this download. Please reconnect and try again.';
      }
    } finally {
      _updating.remove(id);
      if (_current) {
        notifyListeners();
        if (_started) {
          _timer?.cancel();
          _timer = Timer(pollInterval, () => unawaited(refresh()));
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
