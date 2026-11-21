import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/queue_item.dart';
import 'api_service.dart';
import 'player_state_service.dart';
import 'queue_service.dart';

typedef RadioFetcher = Future<List<QueueItem>> Function(
    QueueItem seed, List<QueueItem> exclude);

/// Radio owns recommendation requests, while QueueService continues to own
/// playback. A slow response is abandoned after any newer playback/queue intent.
class SongRadioService extends ChangeNotifier {
  final QueueService _queue;
  final PlayerStateService _player;
  final RadioFetcher _fetchRadio;
  final Future<String?> Function(QueueItem)? _loadStreamingUrl;
  final bool Function() _isSessionCurrent;
  final Duration requestTimeout;
  final List<QueueItem> _recent = [];
  int _request = 0;
  bool _disposed = false;
  bool _busy = false;
  bool _automaticRequest = false;
  bool _autoplayEnabled = false;
  Object? _completedEntry;
  bool Function()? _pendingPlaybackGuard;
  String? _message;

  SongRadioService({
    required QueueService queue,
    required PlayerStateService player,
    required RadioFetcher fetchRadio,
    Future<String?> Function(QueueItem)? loadStreamingUrl,
    bool Function()? isSessionCurrent,
    this.requestTimeout = const Duration(seconds: 20),
  })  : _queue = queue,
        _player = player,
        _fetchRadio = fetchRadio,
        _loadStreamingUrl = loadStreamingUrl,
        _isSessionCurrent = isSessionCurrent ?? (() => true) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    _queue.addListener(_rememberCurrent);
    _rememberCurrent();
  }

  bool get busy => _busy;
  bool get autoplayEnabled => _autoplayEnabled;
  String? get message => _message;
  bool get _current => !_disposed && _isSessionCurrent();

  void setAutoplayEnabled(bool enabled) {
    if (_disposed || enabled == _autoplayEnabled) return;
    _autoplayEnabled = enabled;
    if (!enabled && _automaticRequest) cancelPending();
    notifyListeners();
  }

  void cancelPending() {
    if (_disposed) return;
    ++_request;
    _cancelPreparedPlayback();
    _busy = false;
    _automaticRequest = false;
    _message = null;
    notifyListeners();
  }

  void _cancelPreparedPlayback() {
    final guard = _pendingPlaybackGuard;
    _pendingPlaybackGuard = null;
    if (guard != null) _queue.cancelGuardedPlayback(guard);
  }

  static String _normalized(String? value) =>
      (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static bool sameRecording(QueueItem left, QueueItem right) {
    final leftId =
        ApiService.spotifyTrackId(left.originalUrl, id: left.spotifyId);
    final rightId =
        ApiService.spotifyTrackId(right.originalUrl, id: right.spotifyId);
    if (leftId != null && leftId == rightId) return true;
    final leftSource = ApiService.canonicalYouTubeSource(left.originalUrl) ??
        ApiService.youtubeSourceFromMediaUrl(left.url ?? '');
    final rightSource = ApiService.canonicalYouTubeSource(right.originalUrl) ??
        ApiService.youtubeSourceFromMediaUrl(right.url ?? '');
    if (leftSource != null && leftSource == rightSource) return true;
    if ((left.filename ?? '').isNotEmpty && left.filename == right.filename) {
      return true;
    }
    if (_normalized(left.title).isEmpty || _normalized(left.artist).isEmpty) {
      return left.id.isNotEmpty && left.id == right.id;
    }
    String kind(QueueItem item) {
      final type =
          VideoInfo.inferRecordingType('${item.title} ${item.album ?? ''}');
      return const ['studio', 'original', 'unspecified'].contains(type)
          ? 'original'
          : type;
    }

    return _normalized(left.title) == _normalized(right.title) &&
        _normalized(left.artist) == _normalized(right.artist) &&
        kind(left) == kind(right);
  }

  void _remember(QueueItem item) {
    _recent.removeWhere((previous) => sameRecording(previous, item));
    _recent.add(item);
    if (_recent.length > 100) _recent.removeAt(0);
  }

  void _rememberCurrent() {
    if (!_current) return;
    final item = _queue.currentItem;
    if (item != null && _queue.ownsCurrentPlayback(_player)) _remember(item);
  }

  List<QueueItem> _exclusions(QueueItem seed) {
    final all = [..._recent, ..._queue.queue, seed];
    final unique = <QueueItem>[];
    for (final item in all.reversed) {
      if (!unique.any((other) => sameRecording(item, other))) unique.add(item);
      if (unique.length == 100) break;
    }
    return List.unmodifiable(unique);
  }

  List<QueueItem> _select(List<QueueItem> candidates, QueueItem seed) {
    final excluded = [..._recent, ..._queue.queue, seed];
    final selected = <QueueItem>[];
    for (final track in candidates) {
      if ((track.title ?? '').trim().isEmpty) continue;
      if (excluded.any((other) => sameRecording(track, other)) ||
          selected.any((other) => sameRecording(track, other))) {
        continue;
      }
      selected.add(track);
      if (selected.length == 20) break;
    }
    return selected;
  }

  bool _valid(int request, int queueRevision, int playbackRevision,
          {required bool automatic}) =>
      _current &&
      request == _request &&
      queueRevision == _queue.revision &&
      playbackRevision == _player.playbackRevision &&
      (!automatic || _autoplayEnabled && _queue.loopMode == LoopMode.none);

  /// A deliberate radio action can replace the queue only after related songs
  /// arrive. A failed/empty lookup leaves the existing listening session intact.
  Future<bool> startRadio(QueueItem seed) => _load(seed, automatic: false);

  /// Call only from the audio engine's natural completion event, after normal
  /// queue/repeat advancement has been checked. Manual Next never calls this.
  Future<bool> onQueueCompleted() {
    if (!_current ||
        !_autoplayEnabled ||
        _busy ||
        _queue.loopMode != LoopMode.none ||
        _queue.isTransitioning ||
        _queue.currentIndex < 0 ||
        _queue.hasNext ||
        !_queue.ownsCurrentPlayback(_player)) {
      return _ignoredCompletion();
    }
    final entry = _queue.entryKeyAt(_queue.currentIndex);
    if (identical(entry, _completedEntry)) return _ignoredCompletion();
    _completedEntry = entry;
    final seed = _queue.currentItem!;
    _remember(seed);
    return _load(seed, automatic: true);
  }

  Future<bool> _ignoredCompletion() {
    if (_current && !_busy && _message != null) {
      _message = null;
      notifyListeners();
    }
    return Future.value(false);
  }

  Future<bool> _load(QueueItem seed, {required bool automatic}) async {
    if (!_current) return false;
    final request = ++_request;
    _cancelPreparedPlayback();
    final queueRevision = _queue.revision;
    final playbackRevision = _player.playbackRevision;
    _busy = true;
    _automaticRequest = automatic;
    _message = null;
    notifyListeners();
    var committed = false;
    Object? intendedEntry;
    bool canStartPlayback() =>
        _current &&
        request == _request &&
        (!automatic || _autoplayEnabled && _queue.loopMode == LoopMode.none);
    _pendingPlaybackGuard = canStartPlayback;
    try {
      final candidates =
          await _fetchRadio(seed, _exclusions(seed)).timeout(requestTimeout);
      if (!_valid(request, queueRevision, playbackRevision,
          automatic: automatic)) {
        return false;
      }
      final selected = _select(candidates, seed);
      if (selected.isEmpty) {
        _message = 'No new songs for this radio right now. Try another song.';
        return false;
      }
      if (automatic) {
        if (_queue.hasNext || !_queue.ownsCurrentPlayback(_player)) {
          return false;
        }
        if (_queue.queueLength + selected.length >
            QueueService.maxSnapshotEntries) {
          _message =
              'The queue is full. Start a new radio to keep discovering.';
          return false;
        }
        final nextIndex = _queue.queueLength;
        _queue.addAllToQueue(selected, loadStreamingUrl: _loadStreamingUrl);
        committed = true;
        intendedEntry = _queue.entryKeyAt(nextIndex);
        await _queue.playItem(nextIndex, _player,
            loadStreamingUrl: _loadStreamingUrl,
            canStartPlayback: canStartPlayback);
      } else {
        _queue.clearQueue();
        // Add the seed separately so shuffle never moves it out of first place.
        _queue.addToQueue(seed);
        _queue.addAllToQueue(selected, loadStreamingUrl: _loadStreamingUrl);
        committed = true;
        intendedEntry = _queue.entryKeyAt(0);
        await _queue.playItem(0, _player,
            loadStreamingUrl: _loadStreamingUrl,
            canStartPlayback: canStartPlayback);
      }
      if (!canStartPlayback() ||
          !_queue.ownsCurrentPlayback(_player) ||
          !identical(intendedEntry, _queue.entryKeyAt(_queue.currentIndex))) {
        return false;
      }
      _remember(seed);
      return true;
    } catch (_) {
      if (canStartPlayback() &&
          (committed ||
              _valid(request, queueRevision, playbackRevision,
                  automatic: automatic))) {
        _message = automatic
            ? 'Could not load more songs. Your queue is still available.'
            : 'Could not start song radio. Please try again.';
      }
      return false;
    } finally {
      if (identical(_pendingPlaybackGuard, canStartPlayback)) {
        _pendingPlaybackGuard = null;
      }
      if (!_disposed && request == _request) {
        _busy = false;
        _automaticRequest = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_request;
    _cancelPreparedPlayback();
    _queue.removeListener(_rememberCurrent);
    super.dispose();
  }
}
