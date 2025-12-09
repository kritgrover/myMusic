import 'package:flutter/material.dart';
import 'dart:async';
import '../services/audio_player_service.dart';
import '../utils/song_display_utils.dart';

const Color neonBlue = Color(0xFF00D9FF);

class BottomPlayer extends StatefulWidget {
  final AudioPlayerService playerService;
  final String? currentTrackName;
  final String? currentTrackArtist;

  const BottomPlayer({
    super.key,
    required this.playerService,
    this.currentTrackName,
    this.currentTrackArtist,
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

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: const Border(
          top: BorderSide(color: neonBlue, width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: neonBlue.withOpacity(0.3),
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
            // Player controls - all on one line
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: SizedBox(
                height: 48,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    // Song name with timestamp on the left, volume on the right
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Song name and artist with timestamp
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                flex: 1,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      hasTrack
                                          ? getDisplayTitle(widget.currentTrackName, widget.playerService.currentUrl)
                                          : 'No track selected',
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: hasTrack ? neonBlue : null,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.left,
                                    ),
                                    if (hasTrack && widget.currentTrackArtist != null && widget.currentTrackArtist!.isNotEmpty)
                                      Text(
                                        widget.currentTrackArtist!,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: neonBlue.withOpacity(0.7),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.left,
                                      ),
                                  ],
                                ),
                              ),
                              if (hasTrack && _duration.inMilliseconds > 0)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Text(
                                    () {
                                      try {
                                        return '${_formatDuration(_displayPosition)} / ${_formatDuration(_duration)}';
                                      } catch (e) {
                                        return '00:00 / 00:00';
                                      }
                                    }(),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Volume control on the right
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                              color: neonBlue,
                            ),
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 120,
                              child: Slider(
                                value: _isDraggingVolume ? _dragVolumeValue : _volume,
                                min: 0.0,
                                max: 1.0,
                                onChangeStart: _onVolumeSliderStart,
                                onChangeEnd: _onVolumeSliderEnd,
                                onChanged: _onVolumeSliderUpdate,
                                activeColor: neonBlue,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    // Control buttons centered
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          onPressed: hasTrack
                              ? () {
                                  // Previous track functionality
                                }
                              : null,
                          tooltip: 'Previous',
                          color: hasTrack ? neonBlue : null,
                        ),
                        IconButton(
                          icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                          iconSize: 32,
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
                          color: hasTrack ? neonBlue : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          onPressed: hasTrack
                              ? () {
                                  // Next track functionality
                                }
                              : null,
                          tooltip: 'Next',
                          color: hasTrack ? neonBlue : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

