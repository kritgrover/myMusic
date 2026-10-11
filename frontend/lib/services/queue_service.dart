import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/queue_item.dart';
import 'player_state_service.dart';

enum LoopMode { none, queue, single }

// Every queue occurrence has its own identity, including repeated songs.
class _QueueEntry {
  QueueItem item;
  final bool skipRecentlyPlayed;
  final Future<String?> Function(QueueItem)? loader;
  _QueueEntry(this.item, {this.skipRecentlyPlayed = false, this.loader});
}

class QueueService extends ChangeNotifier {
  final List<_QueueEntry> _queue = [];
  final List<_QueueEntry> _originalOrder = [];
  final Random _random;
  _QueueEntry? _currentEntry;
  _QueueEntry? _lastPlayedEntry;
  PlayerStateService? _pendingPlayer;
  LoopMode _loopMode = LoopMode.none;
  bool _isShuffled = false;
  bool _isTransitioning = false;
  bool _disposed = false;
  int _playRequest = 0;

  QueueService({Random? random}) : _random = random ?? Random();

  List<QueueItem> get queue =>
      List.unmodifiable(_queue.map((entry) => entry.item));
  Object entryKeyAt(int index) => _queue[index];
  int get currentIndex =>
      _currentEntry == null ? -1 : _queue.indexOf(_currentEntry!);
  QueueItem? get currentItem => _currentEntry?.item;
  bool get hasNext => _nextEntry() != null;
  bool get hasPrevious =>
      currentIndex > 0 ||
      (_loopMode == LoopMode.queue && currentIndex >= 0 && _queue.isNotEmpty);
  int get queueLength => _queue.length;
  int get upcomingCount => _queue.length - currentIndex - 1;
  LoopMode get loopMode => _loopMode;
  bool get isShuffled => _isShuffled;
  bool get isTransitioning => _isTransitioning;

  void addToQueue(QueueItem item) {
    final entry = _QueueEntry(item);
    _queue.add(entry);
    _originalOrder.add(entry);
    notifyListeners();
  }

  void addAllToQueue(
    List<QueueItem> items, {
    bool isPlaylistQueue = false,
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) {
    final entries = items
        .map((item) => _QueueEntry(item,
            skipRecentlyPlayed: isPlaylistQueue, loader: loadStreamingUrl))
        .toList();
    _originalOrder.addAll(entries);
    if (_isShuffled) entries.shuffle(_random);
    _queue.addAll(entries);
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    // Keep now playing attached to the actual audio until another song starts.
    if (identical(_queue[index], _currentEntry)) return;
    final entry = _queue.removeAt(index);
    _originalOrder.remove(entry);
    notifyListeners();
  }

  void updateItemAt(int index, QueueItem newItem) {
    if (index < 0 || index >= _queue.length) return;
    _queue[index].item = newItem;
    notifyListeners();
  }

  void clearQueue() {
    _pendingPlayer?.cancelPendingPlayback();
    _pendingPlayer = null;
    ++_playRequest;
    _isTransitioning = false;
    _queue.clear();
    _originalOrder.clear();
    _currentEntry = null;
    _lastPlayedEntry = null;
    notifyListeners();
  }

  /// Clears upcoming songs, retaining now playing and playback history.
  void clearUpcoming() {
    final removed = _queue.sublist(currentIndex + 1);
    _queue.removeRange(currentIndex + 1, _queue.length);
    _originalOrder.removeWhere(removed.contains);
    notifyListeners();
  }

  /// Uses Flutter's ReorderableListView destination-index convention.
  void reorderQueue(int oldIndex, int newIndex) {
    final firstUpcoming = currentIndex + 1;
    if (oldIndex < firstUpcoming ||
        oldIndex >= _queue.length ||
        newIndex < firstUpcoming ||
        newIndex > _queue.length) return;
    if (newIndex > oldIndex) newIndex--;
    final entry = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, entry);
    _originalOrder
      ..clear()
      ..addAll(_queue);
    _isShuffled = false;
    notifyListeners();
  }

  void toggleShuffle() {
    _isShuffled = !_isShuffled;
    final start = currentIndex + 1;
    final upcoming = _queue.sublist(start);
    if (_isShuffled) {
      upcoming.shuffle(_random);
    } else {
      upcoming.sort((a, b) =>
          _originalOrder.indexOf(a).compareTo(_originalOrder.indexOf(b)));
    }
    _queue.replaceRange(start, _queue.length, upcoming);
    notifyListeners();
  }

  void setCurrentIndex(int index) {
    if (index < 0 || index >= _queue.length) return;
    _currentEntry = _queue[index];
    _lastPlayedEntry = _currentEntry;
    notifyListeners();
  }

  _QueueEntry? _nextEntry({bool isAutomatic = false}) {
    if (_queue.isEmpty) return null;
    if (isAutomatic && _loopMode == LoopMode.single && _currentEntry != null) {
      return _currentEntry;
    }
    if (currentIndex + 1 < _queue.length) return _queue[currentIndex + 1];
    if (_loopMode == LoopMode.queue) return _queue.first;
    return null;
  }

  QueueItem? getNext() => _nextEntry()?.item;
  QueueItem? getPrevious() => hasPrevious
      ? _queue[currentIndex > 0 ? currentIndex - 1 : _queue.length - 1].item
      : null;
  QueueItem? getNextForCompletion() => _nextEntry(isAutomatic: true)?.item;

  void toggleLoopMode() {
    _loopMode = LoopMode.values[(_loopMode.index + 1) % LoopMode.values.length];
    notifyListeners();
  }

  Future<void> playNext(
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
    bool isAutomatic = false,
  }) async {
    if (_isTransitioning) return;
    final next = _nextEntry(isAutomatic: isAutomatic);
    if (next != null) {
      await _playEntry(next, playerService, loadStreamingUrl: loadStreamingUrl);
    }
  }

  Future<void> playPrevious(
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) async {
    if (_isTransitioning) return;
    if (currentItem != null &&
        (playerService.audioPlayer.position >= const Duration(seconds: 3) ||
            !hasPrevious)) {
      await playerService.audioPlayer.seek(Duration.zero);
      return;
    }
    if (hasPrevious) {
      final previous =
          _queue[currentIndex > 0 ? currentIndex - 1 : _queue.length - 1];
      await _playEntry(previous, playerService,
          loadStreamingUrl: loadStreamingUrl);
    }
  }

  Future<void> playItem(
    int index,
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) async {
    if (index < 0 || index >= _queue.length) return;
    await _playEntry(_queue[index], playerService,
        loadStreamingUrl: loadStreamingUrl);
  }

  Future<void> _playEntry(
    _QueueEntry entry,
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) async {
    _pendingPlayer?.cancelPendingPlayback();
    _pendingPlayer = playerService;
    final request = ++_playRequest;
    _isTransitioning = true;
    _currentEntry = entry;
    notifyListeners();
    try {
      final loader = loadStreamingUrl ?? entry.loader;
      String? streamingUrl = entry.item.url;
      if ((streamingUrl == null || streamingUrl.isEmpty) &&
          entry.item.filename == null &&
          entry.item.originalUrl != null &&
          loader != null) {
        streamingUrl = await loader(entry.item);
      }
      if (_disposed || request != _playRequest || !_queue.contains(entry))
        return;
      if (streamingUrl != null && streamingUrl.isNotEmpty) {
        entry.item = entry.item.copyWithStreamingUrl(streamingUrl);
        await playerService.streamTrack(
          streamingUrl,
          trackName: entry.item.title,
          trackArtist: entry.item.artist,
          url: entry.item.originalUrl,
          skipRecentlyPlayed: entry.skipRecentlyPlayed,
        );
      } else if (entry.item.filename != null &&
          entry.item.filename!.isNotEmpty) {
        await playerService.playTrack(
          entry.item.filename!,
          trackName: entry.item.title,
          trackArtist: entry.item.artist,
          url: entry.item.originalUrl,
          skipRecentlyPlayed: entry.skipRecentlyPlayed,
        );
      } else {
        throw StateError(
            'Could not find audio for "${entry.item.displayTitle}". Try another track.');
      }
      if (!_disposed && request == _playRequest) {
        _lastPlayedEntry = entry;
        unawaited(
            _preloadNext(playerService, loadStreamingUrl: loadStreamingUrl));
      }
    } catch (_) {
      if (_disposed || request != _playRequest) return;
      _currentEntry =
          _queue.contains(_lastPlayedEntry) ? _lastPlayedEntry : null;
      rethrow;
    } finally {
      if (!_disposed && request == _playRequest) {
        _isTransitioning = false;
        _pendingPlayer = null;
        notifyListeners();
      }
    }
  }

  Future<void> _preloadNext(
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) async {
    final next = _nextEntry(isAutomatic: true);
    if (next == null || identical(next, _currentEntry)) return;
    try {
      final loader = loadStreamingUrl ?? next.loader;
      var streamingUrl = next.item.url;
      if (streamingUrl == null &&
          next.item.filename == null &&
          next.item.originalUrl != null &&
          loader != null) {
        streamingUrl = await loader(next.item);
      }
      if (_disposed ||
          !_queue.contains(next) ||
          !identical(next, _nextEntry(isAutomatic: true))) return;
      if (streamingUrl != null && streamingUrl.isNotEmpty) {
        next.item = next.item.copyWithStreamingUrl(streamingUrl);
        await playerService.preloadTrackUrl(streamingUrl);
      } else if (next.item.filename != null) {
        await playerService.preloadTrack(next.item.filename!);
      }
    } catch (_) {
      // Normal playback can retry failed preloading.
    }
  }

  Future<void> addAndPlay(
      QueueItem item, PlayerStateService playerService) async {
    final entry = _QueueEntry(item);
    _queue.insert(currentIndex + 1, entry);
    final originalIndex =
        _currentEntry == null ? 0 : _originalOrder.indexOf(_currentEntry!) + 1;
    _originalOrder.insert(originalIndex, entry);
    await _playEntry(entry, playerService);
  }

  @override
  void dispose() {
    _pendingPlayer?.cancelPendingPlayback();
    _pendingPlayer = null;
    _disposed = true;
    ++_playRequest;
    super.dispose();
  }
}
