import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/saved_music_service.dart';
import '../widgets/album_cover.dart';
import '../widgets/playback_settings_sheet.dart';
import '../widgets/save_track_button.dart';
import '../widgets/discovery_actions.dart';

/// A view of the existing listening session. Closing it never stops playback.
class PlayerScreen extends StatefulWidget {
  final PlayerStateService player;
  final QueueService queue;
  final VoidCallback onQueue;
  final VoidCallback onLyrics;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final SavedMusicService? savedMusicService;
  final VoidCallback? onClose;

  const PlayerScreen({
    super.key,
    required this.player,
    required this.queue,
    required this.onQueue,
    required this.onLyrics,
    this.onDownload,
    this.onAddToPlaylist,
    this.savedMusicService,
    this.onClose,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  double? _seekValue;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  AudioPlayerService get _audio => widget.player.audioPlayer;

  @override
  void initState() {
    super.initState();
    _position = _audio.position;
    _duration = _audio.duration;
    _subscriptions.addAll([
      _audio.positionStream.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
      _audio.durationStream.listen((duration) {
        if (mounted) {
          setState(() {
            _duration = duration ?? Duration.zero;
            _seekValue = null;
          });
        }
      }),
      _audio.stateStream.listen((_) {
        if (mounted) setState(() {});
      }),
    ]);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not play this track. Try again.')));
      }
    }
  }

  String _time(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 864000);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _openFromPlayer(VoidCallback action) {
    _close();
    action();
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  Widget _progress() {
    final maximum = math.max(_duration.inMilliseconds.toDouble(), 1.0);
    final value =
        (_seekValue ?? _position.inMilliseconds.toDouble()).clamp(0.0, maximum);
    final enabled = _duration > Duration.zero && !widget.player.isPreparing;
    return Column(children: [
      Semantics(
        label: 'Playback position',
        child: Slider(
          value: value,
          max: maximum,
          semanticFormatterCallback: (value) =>
              _time(Duration(milliseconds: value.round())),
          onChanged:
              enabled ? (value) => setState(() => _seekValue = value) : null,
          onChangeEnd: enabled
              ? (value) {
                  setState(() {
                    _seekValue = null;
                    _position = Duration(milliseconds: value.round());
                  });
                  _run(() => _audio.seek(_position));
                }
              : null,
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(_time(Duration(milliseconds: value.round()))),
        Text(_time(_duration)),
      ]),
    ]);
  }

  Widget _transport() {
    final queue = widget.queue;
    final hasTrack = widget.player.currentTrack != null;
    final busy = widget.player.isPreparing || _audio.isBuffering;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      IconButton(
        tooltip: queue.isShuffled ? 'Shuffle on' : 'Shuffle off',
        isSelected: queue.isShuffled,
        onPressed: queue.toggleShuffle,
        icon: const Icon(Icons.shuffle),
      ),
      IconButton(
        tooltip: 'Previous',
        iconSize: 32,
        onPressed: hasTrack
            ? () => _run(() => queue.currentItem == null
                ? _audio.seek(Duration.zero)
                : queue.playPrevious(widget.player))
            : null,
        icon: const Icon(Icons.skip_previous_rounded),
      ),
      IconButton.filled(
        tooltip: _audio.isPlaying ? 'Pause' : 'Play',
        iconSize: 40,
        padding: const EdgeInsets.all(12),
        onPressed: hasTrack && !widget.player.isPreparing
            ? () => _run(
                _audio.isPlaying ? widget.player.pause : widget.player.resume)
            : null,
        icon: busy
            ? const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(_audio.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
      ),
      IconButton(
        tooltip: 'Next',
        iconSize: 32,
        onPressed: hasTrack && queue.hasNext
            ? () => _run(() => queue.playNext(widget.player))
            : null,
        icon: const Icon(Icons.skip_next_rounded),
      ),
      IconButton(
        tooltip: switch (queue.loopMode) {
          LoopMode.none => 'Repeat off',
          LoopMode.queue => 'Repeat all',
          LoopMode.single => 'Repeat one',
        },
        isSelected: queue.loopMode != LoopMode.none,
        onPressed: queue.toggleLoopMode,
        icon: Icon(queue.loopMode == LoopMode.single
            ? Icons.repeat_one
            : Icons.repeat),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([widget.player, widget.queue]),
        builder: (context, _) {
          final track = widget.player.currentTrack;
          final queued = widget.queue.currentItem;
          final artwork = queued?.title == track?.title
              ? queued?.thumbnail ?? track?.thumbnail
              : track?.thumbnail;
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Close now playing',
                onPressed: _close,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              title: const Text('Now playing',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                if (track != null &&
                    DiscoveryActionScope.maybeOf(context) != null)
                  DiscoveryTrackMenu(
                    track: track,
                    queueItem: widget.queue.ownsCurrentPlayback(widget.player)
                        ? queued
                        : null,
                  ),
                IconButton(
                  tooltip: 'Playback settings',
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => SingleChildScrollView(
                        child: PlaybackSettingsSheet(queue: widget.queue)),
                  ),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(builder: (context, constraints) {
                final contentWidth = math.min(constraints.maxWidth, 520.0);
                final coverSize = math.min(contentWidth - 48, 320.0);
                return SingleChildScrollView(
                  key: const ValueKey('now-playing-scroll'),
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: Center(
                    child: SizedBox(
                      width: contentWidth - 48,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: AlbumCover(
                              key: ValueKey(track?.id),
                              title: track?.title,
                              artist: track?.artist,
                              filename: track?.filename,
                              artworkUrl: artwork,
                              size: coverSize,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      track?.title ??
                                          'Choose something to play',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall),
                                  const SizedBox(height: 8),
                                  Text(track?.artist ?? 'Your music, your way',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge),
                                ],
                              ),
                            ),
                            if (track != null)
                              SaveTrackButton(
                                  track: track,
                                  service: widget.savedMusicService),
                          ]),
                          const SizedBox(height: 16),
                          _progress(),
                          const SizedBox(height: 12),
                          _transport(),
                          if (widget.player.playbackError != null) ...[
                            const SizedBox(height: 16),
                            const Text(
                                'Playback interrupted. Tap Play to try again.',
                                textAlign: TextAlign.center),
                          ],
                          const SizedBox(height: 24),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _openFromPlayer(widget.onQueue),
                                icon: const Icon(Icons.queue_music),
                                label: const Text('Queue'),
                              ),
                              OutlinedButton.icon(
                                onPressed: track == null
                                    ? null
                                    : () => _openFromPlayer(widget.onLyrics),
                                icon: const Icon(Icons.lyrics_outlined),
                                label: const Text('Lyrics'),
                              ),
                              if (widget.onAddToPlaylist != null)
                                OutlinedButton.icon(
                                  onPressed: track == null
                                      ? null
                                      : widget.onAddToPlaylist,
                                  icon: const Icon(Icons.playlist_add),
                                  label: const Text('Add to playlist'),
                                ),
                              if (widget.onDownload != null)
                                OutlinedButton.icon(
                                  onPressed:
                                      track == null ? null : widget.onDownload,
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text(kIsWeb
                                      ? 'Download'
                                      : 'Save on this device'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          );
        },
      );
}
