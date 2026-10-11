import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/queue_item.dart';
import 'player_state_service.dart';
import 'api_service.dart';
import 'media_exceptions.dart';
import '../config.dart';

enum LoopMode { none, queue, single }

// Every queue occurrence has its own identity, including repeated songs.
class _QueueEntry {
  QueueItem item;
  final bool skipRecentlyPlayed;
  final Future<String?> Function(QueueItem)? loader;
  _QueueEntry(this.item, {this.skipRecentlyPlayed = false, this.loader});
}

class _ScheduledEntry {
  final _QueueEntry entry;
  final Duration crossfade;
  _ScheduledEntry(this.entry, this.crossfade);
}

class QueueService extends ChangeNotifier {
  static const int maxSnapshotEntries = 10000;
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
  PlayerStateService? _connectedPlayer;
  Future<String?> Function(QueueItem)? _connectedLoader;
  StreamSubscription<Object>? _handoffSubscription;
  _ScheduledEntry? _scheduled;
  Duration _crossfadeDuration = Duration.zero;

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
  Duration get crossfadeDuration => _crossfadeDuration;

  // Scheduled audio can cross its clock boundary between UI frames. Commit
  // that transition before an edit invalidates the token or reuses an index.
  void _synchronizePlayback() =>
      _connectedPlayer?.audioPlayer.synchronizeTransitions();

  void setCrossfadeDuration(Duration value) {
    _synchronizePlayback();
    final bounded =
        Duration(milliseconds: value.inMilliseconds.clamp(0, 12000));
    if (bounded == _crossfadeDuration) return;
    _crossfadeDuration = bounded;
    notifyListeners();
  }

  /// Bind once per account so every queue mutation and restored resume refreshes
  /// the scheduled successor. Tokens identify one transition, even on repeat.
  void connectPlayback(PlayerStateService player,
      {Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    _connectedPlayer?.removeListener(_syncScheduledNext);
    _handoffSubscription?.cancel();
    removeListener(_syncScheduledNext);
    _cancelScheduled();
    _connectedPlayer = player;
    _connectedLoader = loadStreamingUrl;
    addListener(_syncScheduledNext);
    player.addListener(_syncScheduledNext);
    _handoffSubscription =
        player.audioPlayer.handoffStream.listen(_adoptHandoff);
    _syncScheduledNext();
  }

  void _cancelScheduled() {
    final hadScheduled = _scheduled != null;
    _scheduled = null;
    if (hadScheduled && _connectedPlayer != null) {
      unawaited(_connectedPlayer!.audioPlayer.clearPreload());
    }
  }

  bool _playingCurrent(PlayerStateService player) {
    final item = _currentEntry?.item;
    final url = player.currentTrackUrl;
    if (item == null || url == null) return false;
    return (item.url != null &&
            ApiService.canonicalMediaUrl(item.url!) == url) ||
        (item.originalUrl != null &&
            item.originalUrl!.isNotEmpty &&
            ApiService.youtubeSourceFromMediaUrl(url) == item.originalUrl) ||
        (item.filename != null &&
            '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(item.filename!)}' ==
                url);
  }

  void _syncScheduledNext() {
    final player = _connectedPlayer;
    if (_disposed || player == null) return;
    if (_isTransitioning || player.isPreparing) {
      _cancelScheduled();
      return;
    }
    _refreshRecoveredDownload(player);
    if (!_playingCurrent(player)) {
      _cancelScheduled();
      return;
    }
    final next = _nextEntry(isAutomatic: true);
    if (next == null) {
      _cancelScheduled();
      return;
    }
    if (_scheduled?.entry == next &&
        _scheduled?.crossfade == _crossfadeDuration) {
      return;
    }
    _cancelScheduled();
    // Paused restoration never fetches media. On resume the player listener
    // reaches this branch after loading succeeds.
    if (!player.audioPlayer.isPlaying) return;
    final pending = _ScheduledEntry(next, _crossfadeDuration);
    _scheduled = pending;
    unawaited(_stageNext(pending, player));
  }

  void _refreshRecoveredDownload(PlayerStateService player) {
    final entry = _currentEntry;
    if (entry == null) return;
    final source = ApiService.canonicalYouTubeSource(entry.item.originalUrl);
    if (source == null) return;
    final current = player.currentTrackUrl;
    if (current != null &&
        ApiService.youtubeSourceFromMediaUrl(current) == source &&
        (entry.item.filename != null || _isDownloadUrl(entry.item.url))) {
      entry.item =
          entry.item.copyWithStreamingUrl(current, clearFilename: true);
    }
  }

  static bool _isDownloadUrl(String? url) {
    if (url == null) return false;
    final canonical = ApiService.canonicalMediaUrl(url);
    return ApiService.isProtectedMediaUrl(canonical) &&
        Uri.parse(canonical).path.startsWith('/downloads/');
  }

  Future<void> _stageNext(
      _ScheduledEntry pending, PlayerStateService player) async {
    try {
      final entry = pending.entry;
      var url = entry.item.url;
      if ((url == null || url.isEmpty) && entry.item.filename != null) {
        url =
            '${AppConfig.apiBaseUrl}/downloads/${Uri.encodeComponent(entry.item.filename!)}';
      }
      if (url == null || url.isEmpty) {
        url = await (entry.loader ?? _connectedLoader)?.call(entry.item);
      }
      if (_disposed ||
          !identical(_scheduled, pending) ||
          !identical(entry, _nextEntry(isAutomatic: true))) {
        return;
      }
      if (url == null || url.isEmpty) return;
      if (entry.item.filename == null) {
        entry.item = entry.item.copyWithStreamingUrl(url);
      }
      try {
        await player.audioPlayer
            .prepareNext(url, token: pending, crossfade: pending.crossfade);
      } on DownloadUnavailableException {
        if (_disposed || !identical(_scheduled, pending)) return;
        final source =
            ApiService.canonicalYouTubeSource(entry.item.originalUrl);
        if (source == null || !_isDownloadUrl(url)) return;
        final fallback =
            '${AppConfig.apiBaseUrl}/stream/${Uri.encodeComponent(source)}';
        final previous = entry.item;
        entry.item =
            previous.copyWithStreamingUrl(fallback, clearFilename: true);
        try {
          await player.audioPlayer.prepareNext(fallback,
              token: pending, crossfade: pending.crossfade);
        } finally {
          if (identical(_scheduled, pending) &&
              player.audioPlayer.preloadedUrl != fallback) {
            entry.item = previous;
          }
        }
      }
    } catch (_) {
      // The completion path retries normally if preloading is unavailable.
    }
  }

  void _adoptHandoff(Object token) {
    final pending = _scheduled;
    final player = _connectedPlayer;
    if (_disposed ||
        player == null ||
        pending == null ||
        !identical(token, pending) ||
        _isTransitioning ||
        !identical(pending.entry, _nextEntry(isAutomatic: true))) {
      return;
    }
    _scheduled = null;
    _currentEntry = pending.entry;
    _lastPlayedEntry = pending.entry;
    player.adoptScheduledTrack(pending.entry.item,
        skipRecentlyPlayed: pending.entry.skipRecentlyPlayed);
    notifyListeners();
  }

  /// Strip short-lived credentials from persisted references, including IDs
  /// that embed an old media URL (for example `video_http://...`).
  static String? persistentReference(String? value) {
    if (value == null || value.isEmpty) return value;
    final embedded = RegExp(r'https?://').firstMatch(value);
    final prefix = embedded == null ? '' : value.substring(0, embedded.start);
    final reference =
        embedded == null ? value : value.substring(embedded.start);
    final canonical = ApiService.canonicalMediaUrl(reference);
    final uri = Uri.tryParse(canonical);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    final query = Map<String, List<String>>.from(uri.queryParametersAll)
      ..removeWhere((key, _) => const {
            'media_token',
            'access_token',
            'token',
            'authorization',
            '_session'
          }.contains(key.toLowerCase()));
    final clean = uri
        .replace(queryParameters: query, fragment: '')
        .toString()
        .replaceFirst(RegExp(r'[?#]+$'), '');
    return '$prefix$clean';
  }

  static Map<String, dynamic> itemToSnapshot(QueueItem item) => {
        'id': persistentReference(item.id) ?? '',
        'title': item.title,
        'artist': item.artist,
        'album': item.album,
        'url': _networkReference(item.url),
        'filename': item.filename,
        'thumbnail': _networkReference(item.thumbnail),
        'originalUrl': _networkReference(item.originalUrl),
      };

  static String? _networkReference(String? value) {
    final clean = persistentReference(value);
    final uri = clean == null ? null : Uri.tryParse(clean);
    if (uri != null &&
        uri.hasScheme &&
        uri.scheme != 'http' &&
        uri.scheme != 'https') {
      return null;
    }
    return clean;
  }

  /// Malformed individual rows can be discarded without losing a valid queue.
  static QueueItem? itemFromSnapshot(Object? value) {
    if (value is! Map) return null;
    const limits = {
      'id': 4096,
      'title': 1024,
      'artist': 1024,
      'album': 1024,
      'url': 8192,
      'filename': 2048,
      'thumbnail': 8192,
      'originalUrl': 8192
    };
    for (final entry in limits.entries) {
      final field = value[entry.key];
      if (field != null && (field is! String || field.length > entry.value)) {
        return null;
      }
    }
    var filename = value['filename'] as String?;
    if (filename != null &&
        (filename.startsWith('/') ||
            filename.startsWith('\\') ||
            filename.contains(':') ||
            filename.replaceAll('\\', '/').split('/').contains('..'))) {
      filename = null;
    }
    final url = _networkReference(value['url'] as String?);
    final title = value['title'] as String?;
    var original = _networkReference(value['originalUrl'] as String?);
    if ((filename ?? '').isEmpty &&
        (url ?? '').isEmpty &&
        (original ?? '').isEmpty) {
      if ((title ?? '').trim().isEmpty) return null;
      // Restored metadata-only Spotify tracks can be resolved by title later.
      original = '';
    }
    return QueueItem(
        id: persistentReference(value['id'] as String?) ?? '',
        title: title,
        artist: value['artist'] as String?,
        album: value['album'] as String?,
        url: url,
        filename: (filename ?? '').isEmpty ? null : filename,
        thumbnail: _networkReference(value['thumbnail'] as String?),
        originalUrl: original);
  }

  Map<String, dynamic> exportSnapshot() {
    final selected = _isTransitioning ? _lastPlayedEntry : _currentEntry;
    return {
      'version': 1,
      'entries': _queue
          .map((entry) => {
                'item': itemToSnapshot(entry.item),
                'skipRecentlyPlayed': entry.skipRecentlyPlayed
              })
          .toList(),
      'originalOrder': _originalOrder.map(_queue.indexOf).toList(),
      'currentIndex': selected == null ? -1 : _queue.indexOf(selected),
      'isShuffled': _isShuffled,
      'loopMode': _loopMode.name
    };
  }

  /// Validates and normalizes persisted data without mutating a live queue.
  static Map<String, dynamic>? validateSnapshot(Object? value) {
    if (value is! Map || value['version'] != 1 || value['entries'] is! List) {
      return null;
    }
    final rows = value['entries'] as List;
    if (rows.length > maxSnapshotEntries) return null;
    final entries = <Map<String, dynamic>>[];
    final newIndexes = <int, int>{};
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      if (row is! Map) continue;
      final item = itemFromSnapshot(row['item']);
      if (item == null) continue;
      newIndexes[index] = entries.length;
      entries.add({
        'item': itemToSnapshot(item),
        'skipRecentlyPlayed': row['skipRecentlyPlayed'] == true
      });
    }
    final original = value['originalOrder'];
    final originalValid = original is List &&
        original.length == rows.length &&
        original.every(
            (index) => index is int && index >= 0 && index < rows.length) &&
        original.toSet().length == rows.length;
    final order = originalValid
        ? original
            .where(newIndexes.containsKey)
            .map((index) => newIndexes[index]!)
            .toList()
        : List.generate(entries.length, (index) => index);
    final selected = value['currentIndex'];
    final loop = LoopMode.values.firstWhere(
        (mode) => mode.name == value['loopMode'],
        orElse: () => LoopMode.none);
    return {
      'version': 1,
      'entries': entries,
      'originalOrder': order,
      'currentIndex': selected is int ? newIndexes[selected] ?? -1 : -1,
      'isShuffled': originalValid && value['isShuffled'] == true,
      'loopMode': loop.name
    };
  }

  /// Rebuild occurrence identity and attach the current app's lazy source
  /// resolver. No audio or history operation is performed during restoration.
  bool restoreSnapshot(Map<String, dynamic> snapshot,
      {Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    if (_disposed) return false;
    _synchronizePlayback();
    final normalized = validateSnapshot(snapshot);
    if (normalized == null) return false;
    final entries = (normalized['entries'] as List)
        .map((row) => _QueueEntry(itemFromSnapshot(row['item'])!,
            skipRecentlyPlayed: row['skipRecentlyPlayed'] == true,
            loader: loadStreamingUrl))
        .toList();
    _pendingPlayer?.cancelPendingPlayback();
    _pendingPlayer = null;
    ++_playRequest;
    _isTransitioning = false;
    _queue
      ..clear()
      ..addAll(entries);
    _originalOrder
      ..clear()
      ..addAll((normalized['originalOrder'] as List)
          .map((index) => entries[index as int]));
    final index = normalized['currentIndex'] as int;
    _currentEntry = index < 0 ? null : entries[index];
    _lastPlayedEntry = _currentEntry;
    _isShuffled = normalized['isShuffled'] as bool;
    _loopMode = LoopMode.values
        .firstWhere((mode) => mode.name == normalized['loopMode']);
    notifyListeners();
    return true;
  }

  void addToQueue(QueueItem item) {
    _synchronizePlayback();
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
    _synchronizePlayback();
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
    _synchronizePlayback();
    if (index < 0 || index >= _queue.length) return;
    // Keep now playing attached to the actual audio until another song starts.
    if (identical(_queue[index], _currentEntry)) return;
    final entry = _queue.removeAt(index);
    _originalOrder.remove(entry);
    notifyListeners();
  }

  void updateItemAt(int index, QueueItem newItem) {
    _synchronizePlayback();
    if (index < 0 || index >= _queue.length) return;
    if (identical(_scheduled?.entry, _queue[index])) _cancelScheduled();
    _queue[index].item = newItem;
    notifyListeners();
  }

  void clearQueue() {
    _synchronizePlayback();
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
    _synchronizePlayback();
    final removed = _queue.sublist(currentIndex + 1);
    _queue.removeRange(currentIndex + 1, _queue.length);
    _originalOrder.removeWhere(removed.contains);
    notifyListeners();
  }

  /// Uses Flutter's ReorderableListView destination-index convention.
  void reorderQueue(int oldIndex, int newIndex) {
    _synchronizePlayback();
    final firstUpcoming = currentIndex + 1;
    if (oldIndex < firstUpcoming ||
        oldIndex >= _queue.length ||
        newIndex < firstUpcoming ||
        newIndex > _queue.length) {
      return;
    }
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
    _synchronizePlayback();
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
    _synchronizePlayback();
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
    _synchronizePlayback();
    _loopMode = LoopMode.values[(_loopMode.index + 1) % LoopMode.values.length];
    notifyListeners();
  }

  Future<void> playNext(
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
    bool isAutomatic = false,
  }) async {
    _synchronizePlayback();
    if (_isTransitioning) return;
    if (isAutomatic &&
        _connectedPlayer != null &&
        !_playingCurrent(playerService)) {
      return;
    }
    final next = _nextEntry(isAutomatic: isAutomatic);
    if (next != null) {
      await _playEntry(next, playerService, loadStreamingUrl: loadStreamingUrl);
    }
  }

  Future<void> playPrevious(
    PlayerStateService playerService, {
    Future<String?> Function(QueueItem)? loadStreamingUrl,
  }) async {
    _synchronizePlayback();
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
    _synchronizePlayback();
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
      final loader = loadStreamingUrl ?? entry.loader ?? _connectedLoader;
      String? streamingUrl = entry.item.url;
      if ((streamingUrl == null || streamingUrl.isEmpty) &&
          entry.item.filename == null &&
          entry.item.originalUrl != null &&
          loader != null) {
        streamingUrl = await loader(entry.item);
      }
      if (_disposed || request != _playRequest || !_queue.contains(entry)) {
        return;
      }
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
        if (_connectedPlayer == null) _refreshRecoveredDownload(playerService);
        _lastPlayedEntry = entry;
        if (_connectedPlayer == null) {
          unawaited(
              _preloadNext(playerService, loadStreamingUrl: loadStreamingUrl));
        }
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
          !identical(next, _nextEntry(isAutomatic: true))) {
        return;
      }
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
    _synchronizePlayback();
    final entry = _QueueEntry(item);
    _queue.insert(currentIndex + 1, entry);
    final originalIndex =
        _currentEntry == null ? 0 : _originalOrder.indexOf(_currentEntry!) + 1;
    _originalOrder.insert(originalIndex, entry);
    await _playEntry(entry, playerService);
  }

  @override
  void dispose() {
    _cancelScheduled();
    _connectedPlayer?.removeListener(_syncScheduledNext);
    _handoffSubscription?.cancel();
    removeListener(_syncScheduledNext);
    _pendingPlayer?.cancelPendingPlayback();
    _pendingPlayer = null;
    _disposed = true;
    ++_playRequest;
    super.dispose();
  }
}
