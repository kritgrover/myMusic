import 'package:flutter/material.dart';
import 'dart:async';
import '../services/audio_player_service.dart';
import '../services/queue_service.dart';
import '../services/player_state_service.dart';
import '../utils/song_display_utils.dart';

class BottomPlayer extends StatefulWidget {
  final AudioPlayerService playerService;
  final String? currentTrackName;
  final String? currentTrackArtist;
  final QueueService? queueService;
  final PlayerStateService? playerStateService;
  final VoidCallback? onQueueToggle;

  const BottomPlayer({
    super.key,
    required this.playerService,
    this.currentTrackName,
    this.currentTrackArtist,
    this.queueService,
    this.playerStateService,
    this.onQueueToggle,
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
  double _volume = 1.0;
  bool _isDraggingVolume = false;
  double _dragVolumeValue = 1.0;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
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
      if (mounted && duration != null && !duration.isNegative) {
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
    try {
      if (duration.isNegative || duration.inSeconds < 0) {
        return '00:00';
      }
      String twoDigits(int n) => n.toString().padLeft(2, '0');
      final totalSeconds = duration.inSeconds.abs();
      final minutes = twoDigits(totalSeconds ~/ 60);
      final seconds = twoDigits(totalSeconds % 60);
      return '$minutes:$seconds';
    } catch (e) {
      return '00:00';
    }
  }


  Duration get _displayPosition {
    try {
      if (_isDragging && _duration.inMilliseconds > 0) {
        return Duration(milliseconds: _dragValue.toInt().clamp(0, _duration.inMilliseconds));
      }
      return _position;
    } catch (e) {
      return Duration.zero;
    }
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

  void _onVolumeSliderStart(double value) {
    setState(() {
      _isDraggingVolume = true;
      _dragVolumeValue = value;
    });
  }

  void _onVolumeSliderUpdate(double value) {
    setState(() {
      _dragVolumeValue = value;
    });
    try {
      widget.playerService.player.setVolume(value.clamp(0.0, 1.0));
    } catch (e) {
      // Handle error silently
    }
  }

  void _onVolumeSliderEnd(double value) {
    setState(() {
      _isDraggingVolume = false;
      _volume = value;
      _dragVolumeValue = value;
    });
    try {
      widget.playerService.player.setVolume(value.clamp(0.0, 1.0));
    } catch (e) {
      // Handle error silently
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = widget.playerService.currentUrl != null;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceElevated = Theme.of(context).colorScheme.surface;

    return Container(
      decoration: BoxDecoration(
        color: surfaceElevated,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar - only show if track is loaded
            if (hasTrack)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Slider(
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
              ),
            // Player controls
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
              child: Row(
                children: [
                  // Track info
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: primaryColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.music_note,
                            color: primaryColor,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                hasTrack
                                    ? getDisplayTitle(widget.currentTrackName, widget.playerService.currentUrl)
                                    : 'No track selected',
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: hasTrack ? null : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (hasTrack && widget.currentTrackArtist != null && widget.currentTrackArtist!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  widget.currentTrackArtist!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              if (hasTrack && _duration.inMilliseconds > 0) ...[
                                const SizedBox(height: 4),
                                Text(
                                  () {
                                    try {
                                      return '${_formatDuration(_displayPosition)} / ${_formatDuration(_duration)}';
                                    } catch (e) {
                                      return '00:00 / 00:00';
                                    }
                                  }(),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Control buttons
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous, size: 24),
                        onPressed: hasTrack && widget.queueService != null && widget.playerStateService != null
                            ? () async {
                                if (widget.queueService!.hasPrevious) {
                                  await widget.queueService!.playPrevious(widget.playerStateService!);
                                }
                              }
                            : hasTrack
                                ? () {
                                    // Previous track functionality (no queue)
                                  }
                                : null,
                        tooltip: 'Previous',
                      ),
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            size: 28,
                          ),
                          color: Colors.white,
                          onPressed: hasTrack
                              ? () async {
                                  if (_isPlaying) {
                                    await widget.playerService.pause();
                                  } else {
                                    await widget.playerService.resume();
                                  }
                                }
                              : null,
                          tooltip: _isPlaying ? 'Pause' : 'Play',
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, size: 24),
                        onPressed: hasTrack && widget.queueService != null && widget.playerStateService != null
                            ? () async {
                                if (widget.queueService!.hasNext) {
                                  await widget.queueService!.playNext(widget.playerStateService!);
                                }
                              }
                            : hasTrack
                                ? () {
                                    // Next track functionality (no queue)
                                  }
                                : null,
                        tooltip: 'Next',
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  // Queue and volume controls
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.queueService != null && widget.onQueueToggle != null)
                        ListenableBuilder(
                          listenable: widget.queueService!,
                          builder: (context, _) {
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.queue_music, size: 20),
                                  onPressed: widget.onQueueToggle,
                                  tooltip: 'Queue',
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                ),
                                if (widget.queueService!.queueLength > 0)
                                  Positioned(
                                    right: 8,
                                    top: 8,
                                    child: IgnorePointer(
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: primaryColor,
                                          shape: BoxShape.circle,
                                        ),
                                        constraints: const BoxConstraints(
                                          minWidth: 16,
                                          minHeight: 16,
                                        ),
                                        child: Text(
                                          '${widget.queueService!.queueLength}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      Icon(
                        _isDraggingVolume
                            ? (_dragVolumeValue > 0.5
                                ? Icons.volume_up
                                : _dragVolumeValue > 0.0
                                    ? Icons.volume_down
                                    : Icons.volume_off)
                            : (_volume > 0.5
                                ? Icons.volume_up
                                : _volume > 0.0
                                    ? Icons.volume_down
                                    : Icons.volume_off),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _isDraggingVolume ? _dragVolumeValue : _volume,
                          min: 0.0,
                          max: 1.0,
                          onChangeStart: _onVolumeSliderStart,
                          onChangeEnd: _onVolumeSliderEnd,
                          onChanged: _onVolumeSliderUpdate,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

