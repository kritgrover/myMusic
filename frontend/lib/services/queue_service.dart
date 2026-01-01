import 'package:flutter/material.dart';
import '../models/queue_item.dart';
import 'player_state_service.dart';

enum LoopMode {
  none,
  queue,
  single,
}

class QueueService extends ChangeNotifier {
  final List<QueueItem> _queue = [];
  int _currentIndex = -1;
  LoopMode _loopMode = LoopMode.none;
  bool _isPlaylistQueue = false; // Track if queue is from a playlist
  bool _isTransitioning = false; // Prevent duplicate playNext calls
  Future<String?> Function(QueueItem)? _loadStreamingUrlCallback; // Callback for lazy loading streaming URLs

  List<QueueItem> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  QueueItem? get currentItem => _currentIndex >= 0 && _currentIndex < _queue.length 
      ? _queue[_currentIndex] 
      : null;
  bool get hasNext => _currentIndex >= 0 && _currentIndex < _queue.length - 1;
  bool get hasPrevious => _currentIndex > 0;
  int get queueLength => _queue.length;
  LoopMode get loopMode => _loopMode;

  // Add item to the end of queue
  void addToQueue(QueueItem item) {
    _queue.add(item);
    notifyListeners();
  }

  // Add multiple items to queue
  void addAllToQueue(List<QueueItem> items, {bool isPlaylistQueue = false, Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    _queue.addAll(items);
    _isPlaylistQueue = isPlaylistQueue;
    _loadStreamingUrlCallback = loadStreamingUrl;
    notifyListeners();
  }

  // Remove item from queue
  void removeFromQueue(int index) {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      if (_currentIndex == index) {
        if (_currentIndex >= _queue.length) {
          _currentIndex = _queue.length - 1;
        }
      } else if (_currentIndex > index) {
        _currentIndex--;
      }
      notifyListeners();
    }
  }

  // Update item at specific index
  void updateItemAt(int index, QueueItem newItem) {
    if (index >= 0 && index < _queue.length) {
      _queue[index] = newItem;
      notifyListeners();
    }
  }

  // Clear the entire queue
  void clearQueue() {
    _queue.clear();
    _currentIndex = -1;
    _isPlaylistQueue = false;
    _loadStreamingUrlCallback = null;
    notifyListeners();
  }

  // Set current index
  void setCurrentIndex(int index) {
    if (index >= 0 && index < _queue.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  // Get next item
  QueueItem? getNext() {
    if (hasNext) {
      return _queue[_currentIndex + 1];
    }
    return null;
  }

  // Get previous item
  QueueItem? getPrevious() {
    if (hasPrevious) {
      return _queue[_currentIndex - 1];
    }
    return null;
  }

  // Toggle loop mode: none -> queue -> single -> none
  void toggleLoopMode() {
    switch (_loopMode) {
      case LoopMode.none:
        _loopMode = LoopMode.queue;
        break;
      case LoopMode.queue:
        _loopMode = LoopMode.single;
        break;
      case LoopMode.single:
        _loopMode = LoopMode.none;
        break;
    }
    notifyListeners();
  }

  // Move to next track
  Future<void> playNext(PlayerStateService playerService, {Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    // Prevent duplicate calls during transitions
    if (_isTransitioning) {
      return;
    }
    
    _isTransitioning = true;
    try {
      // If loop single mode, replay current song
      if (_loopMode == LoopMode.single && _currentIndex >= 0 && _currentIndex < _queue.length) {
        final currentItem = _queue[_currentIndex];
        await _playItem(currentItem, playerService, loadStreamingUrl: loadStreamingUrl);
        return;
      }
      
      if (hasNext) {
        _currentIndex++;
        notifyListeners(); // Notify immediately so UI updates
        final nextItem = _queue[_currentIndex];
        await _playItem(nextItem, playerService, loadStreamingUrl: loadStreamingUrl);
      } else if (_loopMode == LoopMode.queue && _queue.isNotEmpty) {
        // Loop back to the beginning
        _currentIndex = 0;
        notifyListeners(); // Notify immediately so UI updates
        final firstItem = _queue[0];
        await _playItem(firstItem, playerService, loadStreamingUrl: loadStreamingUrl);
      }
    } finally {
      // Reset flag after a short delay to allow the transition to complete
      Future.delayed(const Duration(milliseconds: 500), () {
        _isTransitioning = false;
      });
    }
  }

  // Move to previous track
  Future<void> playPrevious(PlayerStateService playerService, {Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    // If loop single mode, replay current song
    if (_loopMode == LoopMode.single && _currentIndex >= 0 && _currentIndex < _queue.length) {
      final currentItem = _queue[_currentIndex];
      await _playItem(currentItem, playerService, loadStreamingUrl: loadStreamingUrl);
      return;
    }
    
    if (hasPrevious) {
      _currentIndex--;
      final previousItem = _queue[_currentIndex];
      await _playItem(previousItem, playerService, loadStreamingUrl: loadStreamingUrl);
    } else if (_loopMode == LoopMode.queue && _queue.isNotEmpty) {
      // Loop to the end
      _currentIndex = _queue.length - 1;
      final lastItem = _queue[_currentIndex];
      await _playItem(lastItem, playerService, loadStreamingUrl: loadStreamingUrl);
    }
  }

  // Play a specific item from queue
  Future<void> playItem(int index, PlayerStateService playerService, {Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    if (index >= 0 && index < _queue.length) {
      _currentIndex = index;
      final item = _queue[index];
      await _playItem(item, playerService, loadStreamingUrl: loadStreamingUrl);
    }
  }

  // Internal method to play an item
  Future<void> _playItem(QueueItem item, PlayerStateService playerService, {Future<String?> Function(QueueItem)? loadStreamingUrl}) async {
    // Skip recently played if this is a playlist queue
    final skipRecentlyPlayed = _isPlaylistQueue;
    
    // Use provided callback or stored callback for lazy loading
    final loadCallback = loadStreamingUrl ?? _loadStreamingUrlCallback;
    
    // If item doesn't have streaming URL but has originalUrl, load it first
    String? streamingUrl = item.url;
    if (streamingUrl == null && item.originalUrl != null && loadCallback != null) {
      try {
        streamingUrl = await loadCallback(item);
        // Update the item with the loaded streaming URL
        if (streamingUrl != null && _currentIndex >= 0 && _currentIndex < _queue.length) {
          final updatedItem = item.copyWithStreamingUrl(streamingUrl);
          _queue[_currentIndex] = updatedItem;
        }
      } catch (e) {
        // If loading fails, try to play with original URL (might work for some cases)
        // Or we could throw an error here
        throw Exception('Failed to load streaming URL: $e');
      }
    }
    
    if (streamingUrl != null) {
      // Stream from URL
      await playerService.streamTrack(
        streamingUrl,
        trackName: item.title,
        trackArtist: item.artist,
        skipRecentlyPlayed: skipRecentlyPlayed,
      );
    } else if (item.filename != null) {
      // Play local file
      await playerService.playTrack(
        item.filename!,
        trackName: item.title,
        trackArtist: item.artist,
        skipRecentlyPlayed: skipRecentlyPlayed,
      );
    } else {
      throw Exception('No URL or filename available for playback');
    }
    
    // Preload the next song in the queue
    _preloadNextSong(playerService, loadStreamingUrl: loadStreamingUrl);
    
    notifyListeners();
  }
  
  // Preload the next song in queue
  void _preloadNextSong(PlayerStateService playerService, {Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    final nextItem = getNextForCompletion();
    if (nextItem != null) {
      // Use provided callback or stored callback for lazy loading
      final loadCallback = loadStreamingUrl ?? _loadStreamingUrlCallback;
      
      // Preload asynchronously without blocking
      if (nextItem.url != null) {
        playerService.preloadTrackUrl(nextItem.url!);
      } else if (nextItem.filename != null) {
        playerService.preloadTrack(nextItem.filename!);
      } else if (nextItem.originalUrl != null && loadCallback != null) {
        // Load streaming URL in background for lazy-loaded items
        loadCallback(nextItem).then((streamingUrl) {
          if (streamingUrl != null) {
            // Update the item and preload
            final nextIndex = _currentIndex + 1;
            if (nextIndex < _queue.length && _queue[nextIndex].id == nextItem.id) {
              _queue[nextIndex] = nextItem.copyWithStreamingUrl(streamingUrl);
              playerService.preloadTrackUrl(streamingUrl);
            }
          }
        }).catchError((_) {
          // Silently fail preloading
        });
      }
    }
  }

  // Add item and play it immediately
  Future<void> addAndPlay(QueueItem item, PlayerStateService playerService) async {
    // If queue is empty or we're at the end, just add and play
    if (_queue.isEmpty || _currentIndex == _queue.length - 1) {
      _queue.add(item);
      _currentIndex = _queue.length - 1;
      await _playItem(item, playerService);
    } else {
      // Insert after current position
      _currentIndex++;
      _queue.insert(_currentIndex, item);
      await _playItem(item, playerService);
    }
  }

  // Get next item considering loop mode
  QueueItem? getNextForCompletion() {
    if (_loopMode == LoopMode.single && _currentIndex >= 0 && _currentIndex < _queue.length) {
      // Return current item for single loop
      return _queue[_currentIndex];
    }
    
    if (hasNext) {
      return _queue[_currentIndex + 1];
    } else if (_loopMode == LoopMode.queue && _queue.isNotEmpty) {
      // Loop back to the beginning
      return _queue[0];
    }
    
    return null;
  }
}

