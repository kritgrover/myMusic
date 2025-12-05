import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:async';
import '../services/audio_player_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayerService _playerService = AudioPlayerService();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<PlayerState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    _positionSubscription = _playerService.positionStream.listen((position) {
      setState(() {
        _position = position;
      });
    });
    _durationSubscription = _playerService.durationStream.listen((duration) {
      setState(() {
        _duration = duration;
      });
    });
    _stateSubscription = _playerService.stateStream.listen((state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _stateSubscription?.cancel();
    _playerService.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _seekTo(Duration position) async {
    await _playerService.seek(position);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_note,
            size: 120,
            color: neonBlue,
          ),
          const SizedBox(height: 32),
          Text(
            _playerService.currentUrl ?? 'No track selected',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Slider(
            value: _duration.inMilliseconds > 0
                ? _position.inMilliseconds.toDouble()
                : 0.0,
            max: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds.toDouble()
                : 1.0,
            onChanged: (value) {
              _seekTo(Duration(milliseconds: value.toInt()));
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(_position)),
                Text(_formatDuration(_duration)),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 48,
                onPressed: () {
                  // Previous track functionality
                },
              ),
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                iconSize: 64,
                onPressed: () async {
                  if (_isPlaying) {
                    await _playerService.pause();
                  } else {
                    await _playerService.resume();
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 48,
                onPressed: () {
                  // Next track functionality
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

