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
  void addAllToQueue(List<QueueItem> items, {bool isPlaylistQueue = false}) {
    _queue.addAll(items);
    _isPlaylistQueue = isPlaylistQueue;
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

  // Clear the entire queue
  void clearQueue() {
    _queue.clear();
    _currentIndex = -1;
    _isPlaylistQueue = false;
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
  Future<void> playNext(PlayerStateService playerService) async {
    // If loop single mode, replay current song
    if (_loopMode == LoopMode.single && _currentIndex >= 0 && _currentIndex < _queue.length) {
      final currentItem = _queue[_currentIndex];
      await _playItem(currentItem, playerService);
      return;
    }
    
    if (hasNext) {
      _currentIndex++;
      final nextItem = _queue[_currentIndex];
      await _playItem(nextItem, playerService);
    } else if (_loopMode == LoopMode.queue && _queue.isNotEmpty) {
      // Loop back to the beginning
      _currentIndex = 0;
      final firstItem = _queue[0];
      await _playItem(firstItem, playerService);
    }
  }

  // Move to previous track
  Future<void> playPrevious(PlayerStateService playerService) async {
    // If loop single mode, replay current song
    if (_loopMode == LoopMode.single && _currentIndex >= 0 && _currentIndex < _queue.length) {
      final currentItem = _queue[_currentIndex];
      await _playItem(currentItem, playerService);
      return;
    }
    
    if (hasPrevious) {
      _currentIndex--;
      final previousItem = _queue[_currentIndex];
      await _playItem(previousItem, playerService);
    } else if (_loopMode == LoopMode.queue && _queue.isNotEmpty) {
      // Loop to the end
      _currentIndex = _queue.length - 1;
      final lastItem = _queue[_currentIndex];
      await _playItem(lastItem, playerService);
    }
  }

  // Play a specific item from queue
  Future<void> playItem(int index, PlayerStateService playerService) async {
    if (index >= 0 && index < _queue.length) {
      _currentIndex = index;
      final item = _queue[index];
      await _playItem(item, playerService);
    }
  }

  // Internal method to play an item
  Future<void> _playItem(QueueItem item, PlayerStateService playerService) async {
    // Skip recently played if this is a playlist queue
    final skipRecentlyPlayed = _isPlaylistQueue;
    
    if (item.url != null) {
      // Stream from URL
      await playerService.streamTrack(
        item.url!,
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
    }
    notifyListeners();
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

