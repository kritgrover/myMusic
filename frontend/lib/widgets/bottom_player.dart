import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:async';
import '../services/audio_player_service.dart';

class BottomPlayer extends StatefulWidget {
  final AudioPlayerService playerService;
  final String? currentTrackName;

  const BottomPlayer({
    super.key,
    required this.playerService,
    this.currentTrackName,
  });

  @override
  State<BottomPlayer> createState() => _BottomPlayerState();
}

class _BottomPlayerState extends State<BottomPlayer> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isDragging = false;
  double _dragValue = 0.0;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<PlayerState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _positionSubscription = widget.playerService.positionStream.listen((position) {
      if (mounted && !_isDragging) {
        setState(() {
          _position = position;
        });
      } else if (mounted) {
        // Update position but don't update slider while dragging
        _position = position;
      }
    });
    _durationSubscription = widget.playerService.durationStream.listen((duration) {
      if (mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });
    _stateSubscription = widget.playerService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _stateSubscription?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Duration get _displayPosition {
    if (_isDragging && _duration.inMilliseconds > 0) {
      return Duration(milliseconds: _dragValue.toInt());
    }
    return _position;
  }

  Future<void> _seekTo(Duration position) async {
    await widget.playerService.seek(position);
  }

  void _onSliderStart(double value) {
    setState(() {
      _isDragging = true;
      _dragValue = value;
    });
  }

  void _onSliderUpdate(double value) {
    setState(() {
      _dragValue = value;
    });
  }

  void _onSliderEnd(double value) async {
    final seekPosition = Duration(milliseconds: value.toInt());
    
    setState(() {
      _isDragging = false;
      _dragValue = value;
    });
    
    // Seek to the new position - this should maintain playing state
    await widget.playerService.seek(seekPosition);
  }

  @override
  Widget build(BuildContext context) {
    // Only show player if there's a track loaded
    final hasTrack = widget.playerService.currentUrl != null;
    if (!hasTrack) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar
            Slider(
              value: _isDragging
                  ? _dragValue
                  : (_duration.inMilliseconds > 0
                      ? _position.inMilliseconds.toDouble()
                      : 0.0),
              max: _duration.inMilliseconds > 0
                  ? _duration.inMilliseconds.toDouble()
                  : 1.0,
              onChangeStart: _onSliderStart,
              onChangeEnd: _onSliderEnd,
              onChanged: _onSliderUpdate,
            ),
            // Player controls
            Row(
              children: [
                // Track info
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.currentTrackName ?? 'Unknown Track',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_formatDuration(_displayPosition)} / ${_formatDuration(_duration)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                // Control buttons
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () {
                    // Previous track functionality
                  },
                  tooltip: 'Previous',
                ),
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 32,
                  onPressed: () async {
                    if (_isPlaying) {
                      await widget.playerService.pause();
                    } else {
                      await widget.playerService.resume();
                    }
                  },
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () {
                    // Next track functionality
                  },
                  tooltip: 'Next',
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

