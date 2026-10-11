import 'dart:async';
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../utils/song_display_utils.dart';
import 'album_cover.dart';
import 'save_track_button.dart';
import '../services/saved_music_service.dart';
import '../models/playlist.dart';
import 'playback_settings_sheet.dart';

class BottomPlayer extends StatefulWidget {
  final AudioPlayerService playerService;
  final String? currentTrackName;
  final String? currentTrackArtist;
  final QueueService? queueService;
  final PlayerStateService? playerStateService;
  final VoidCallback? onQueueToggle;
  final VoidCallback? onLyricsToggle;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final SavedMusicService? savedMusicService;
  const BottomPlayer(
      {super.key,
      required this.playerService,
      this.currentTrackName,
      this.currentTrackArtist,
      this.queueService,
      this.playerStateService,
      this.onQueueToggle,
      this.onLyricsToggle,
      this.onDownload,
      this.onAddToPlaylist,
      this.savedMusicService});
  @override
  State<BottomPlayer> createState() => _BottomPlayerState();
}

class _BottomPlayerState extends State<BottomPlayer> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _seekValue;
  double _volume = 1;
  double _lastAudibleVolume = 1;
  bool _isPlaying = false;
  bool _isBuffering = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant BottomPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playerService != widget.playerService) {
      _cancelSubscriptions();
      _listen();
    }
  }

  void _listen() {
    final audio = widget.playerService;
    _position = audio.position;
    _duration = audio.duration;
    _isPlaying = audio.isPlaying;
    _isBuffering = audio.isBuffering;
    _volume = audio.volume.clamp(0.0, 1.0);
    if (_volume > 0) _lastAudibleVolume = _volume;
    _seekValue = null;
    _subscriptions.addAll([
      audio.positionStream.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
      audio.durationStream.listen((v) {
        if (mounted)
          setState(() {
            _duration = v ?? Duration.zero;
            _seekValue = null;
          });
      }),
      audio.stateStream.listen((v) {
        if (mounted)
          setState(() {
            _isPlaying = audio.isPlaying;
            _isBuffering = v == PlayerState.buffering;
          });
      }),
      audio.errorStream.listen((_) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _isBuffering = false;
          });
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content: Text('Playback failed. Try the track again.'),
          ));
        }
      }),
      audio.volumeStream.listen((v) {
        if (mounted)
          setState(() {
            _volume = v.clamp(0.0, 1.0);
            if (_volume > 0) _lastAudibleVolume = _volume;
          });
      }),
    ]);
  }

  void _cancelSubscriptions() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    _cancelSubscriptions();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Playback failed. Try the track again.')));
    }
  }

  String _time(Duration v) {
    final seconds = v.inSeconds.clamp(0, 864000);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  bool get _hasTrack =>
      widget.playerService.currentUrl != null ||
      widget.playerStateService?.currentTrack != null;
  bool get _isPreparing => widget.playerStateService?.isPreparing ?? false;
  PlaylistTrack? get _savedTrack {
    final track = widget.playerStateService?.currentTrack;
    if (track == null) return null;
    final queued = widget.queueService?.currentItem;
    final matches =
        queued?.title == track.title && queued?.artist == track.artist;
    return PlaylistTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: matches ? queued?.album : track.album,
      filename: track.filename,
      url: track.url ?? (matches ? queued?.originalUrl : null),
      thumbnail: matches ? queued?.thumbnail : track.thumbnail,
      duration: _duration.inMilliseconds / 1000,
    );
  }

  Future<void> _previous() async {
    if (widget.queueService?.currentItem != null &&
        widget.playerStateService != null) {
      await widget.queueService!.playPrevious(widget.playerStateService!);
    } else {
      await widget.playerService.seek(Duration.zero);
    }
  }

  Widget _button(IconData icon, String tooltip, VoidCallback? onPressed,
          {bool selected = false}) =>
      IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 22,
          color: selected ? Theme.of(context).colorScheme.primary : null,
          icon: Icon(icon));
  Widget _playButton() => IconButton.filled(
      tooltip: _isPlaying ? 'Pause' : 'Play',
      style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          disabledBackgroundColor: Colors.white12),
      onPressed: _hasTrack && !_isPreparing
          ? () => _run(_isPlaying
              ? (widget.playerStateService?.pause ?? widget.playerService.pause)
              : (widget.playerStateService?.resume ??
                  widget.playerService.resume))
          : null,
      icon: _isBuffering || _isPreparing
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 28));
  String get _repeatLabel => switch (widget.queueService?.loopMode) {
        LoopMode.queue => 'Repeat all',
        LoopMode.single => 'Repeat one',
        _ => 'Repeat off',
      };
  Widget _transport({bool compact = false}) {
    final queue = widget.queueService;
    final canSkip = _hasTrack &&
        queue != null &&
        widget.playerStateService != null &&
        queue.hasNext;
    return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!compact) ...[
            _button(
                Icons.shuffle,
                queue?.isShuffled == true ? 'Shuffle on' : 'Shuffle off',
                queue?.toggleShuffle,
                selected: queue?.isShuffled == true),
            _button(Icons.skip_previous_rounded, 'Previous',
                _hasTrack ? () => _run(_previous) : null),
          ],
          _playButton(),
          _button(
              Icons.skip_next_rounded,
              'Next',
              canSkip
                  ? () => _run(() => queue.playNext(widget.playerStateService!))
                  : null),
          if (!compact)
            _button(
                queue?.loopMode == LoopMode.single
                    ? Icons.repeat_one
                    : Icons.repeat,
                _repeatLabel,
                queue?.toggleLoopMode,
                selected: queue != null && queue.loopMode != LoopMode.none),
        ]);
  }

  Widget _progress() {
    final max = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    // Position events can briefly belong to the previous track after a skip.
    final value =
        (_seekValue ?? _position.inMilliseconds.toDouble()).clamp(0.0, max);
    final enabled = _hasTrack && _duration.inMilliseconds > 0;
    return Row(children: [
      SizedBox(
          width: 36,
          child: Text(_time(Duration(milliseconds: value.toInt())),
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.labelSmall)),
      Expanded(
          child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12)),
              child: Slider(
                  value: value,
                  max: max,
                  semanticFormatterCallback: (v) =>
                      _time(Duration(milliseconds: v.toInt())),
                  onChanged:
                      enabled ? (v) => setState(() => _seekValue = v) : null,
                  onChangeEnd: enabled
                      ? (v) {
                          final position = Duration(milliseconds: v.toInt());
                          setState(() {
                            _position = position;
                            _seekValue = null;
                          });
                          _run(() => widget.playerService.seek(position));
                        }
                      : null))),
      SizedBox(
          width: 36,
          child: Text(_time(_duration),
              style: Theme.of(context).textTheme.labelSmall)),
    ]);
  }

  Widget _trackInfo({bool showSave = true}) {
    final item = widget.queueService?.currentItem;
    final title = item?.title ?? widget.currentTrackName;
    final artist = item?.artist ?? widget.currentTrackArtist;
    return Row(children: [
      AlbumCover(
          key: ValueKey(item?.id ?? widget.playerService.currentUrl),
          filename: item?.filename,
          title: title,
          artist: artist,
          artworkUrl: item?.thumbnail,
          size: 48),
      const SizedBox(width: 12),
      Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
            Text(
                _hasTrack
                    ? getDisplayTitle(title, widget.playerService.currentUrl)
                    : 'Choose something to play',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
                _hasTrack
                    ? (artist ?? 'Unknown artist')
                    : 'Your music, your way',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ])),
      if (showSave && _hasTrack && _savedTrack != null)
        SaveTrackButton(track: _savedTrack!, service: widget.savedMusicService),
    ]);
  }

  Widget _volumeControls() => Row(mainAxisSize: MainAxisSize.min, children: [
        _button(
            _volume == 0 ? Icons.volume_off : Icons.volume_up,
            _volume == 0 ? 'Unmute' : 'Mute',
            () => _run(() => widget.playerService
                .setVolume(_volume == 0 ? _lastAudibleVolume : 0))),
        SizedBox(
            width: 90,
            child: Slider(
                value: _volume,
                semanticFormatterCallback: (v) =>
                    '${(v * 100).round()} percent',
                onChanged: (v) =>
                    _run(() => widget.playerService.setVolume(v)))),
      ]);
  Widget _moreMenu() {
    final queue = widget.queueService;
    return PopupMenuButton<String>(
        tooltip: 'More player options',
        icon: const Icon(Icons.more_horiz),
        onSelected: (value) {
          switch (value) {
            case 'previous':
              _run(_previous);
            case 'shuffle':
              queue?.toggleShuffle();
            case 'repeat':
              queue?.toggleLoopMode();
            case 'lyrics':
              widget.onLyricsToggle?.call();
            case 'playlist':
              widget.onAddToPlaylist?.call();
            case 'download':
              widget.onDownload?.call();
            case 'settings':
              if (queue != null) {
                showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => PlaybackSettingsSheet(queue: queue));
              }
            case 'volume':
              showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => SafeArea(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: StreamBuilder<double>(
                              stream: widget.playerService.volumeStream,
                              initialData: _volume,
                              builder: (context, snapshot) => Row(children: [
                                    const Icon(Icons.volume_up),
                                    Expanded(
                                        child: Slider(
                                            value: (snapshot.data ?? 1)
                                                .clamp(0.0, 1.0),
                                            onChanged: (v) => _run(() => widget
                                                .playerService
                                                .setVolume(v)))),
                                  ])))));
          }
        },
        itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'previous',
                  enabled: _hasTrack,
                  child: const Text('Previous track')),
              if (queue != null) ...[
                PopupMenuItem(
                    value: 'shuffle',
                    child: Text(queue.isShuffled
                        ? 'Turn shuffle off'
                        : 'Turn shuffle on')),
                PopupMenuItem(
                    value: 'repeat', child: Text('$_repeatLabel · change')),
              ],
              if (_hasTrack && widget.onLyricsToggle != null)
                const PopupMenuItem(value: 'lyrics', child: Text('Lyrics')),
              if (_hasTrack && widget.onAddToPlaylist != null)
                const PopupMenuItem(
                    value: 'playlist', child: Text('Add to playlist')),
              if (_hasTrack &&
                  widget.onDownload != null &&
                  widget.queueService?.currentItem?.filename == null)
                const PopupMenuItem(value: 'download', child: Text('Download')),
              const PopupMenuItem(value: 'volume', child: Text('Volume')),
              if (queue != null)
                const PopupMenuItem(
                    value: 'settings', child: Text('Playback settings')),
            ]);
  }

  Widget _layout(BuildContext context, BoxConstraints constraints) {
    if (constraints.maxWidth < 1100) {
      return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: _trackInfo(showSave: false)),
              _transport(compact: true),
              _moreMenu()
            ]),
            Row(children: [
              Expanded(child: _progress()),
              if (_hasTrack && _savedTrack != null)
                SaveTrackButton(
                    track: _savedTrack!, service: widget.savedMusicService),
              if (widget.onQueueToggle != null)
                _button(Icons.queue_music, 'Queue', widget.onQueueToggle)
            ]),
          ]));
    }
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(flex: 3, child: _trackInfo()),
          Expanded(
              flex: 4,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_transport(), _progress()])),
          Expanded(
              flex: 3,
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (widget.onLyricsToggle != null)
                  _button(Icons.lyrics_outlined, 'Lyrics',
                      _hasTrack ? widget.onLyricsToggle : null),
                if (widget.onQueueToggle != null)
                  _button(Icons.queue_music, 'Queue', widget.onQueueToggle),
                _volumeControls(),
                _moreMenu(),
              ])),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final child = Material(
        color: const Color(0xFF121212),
        child: SafeArea(top: false, child: LayoutBuilder(builder: _layout)));
    if (widget.queueService == null) return child;
    return ListenableBuilder(
        listenable: widget.queueService!,
        builder: (context, _) => Material(
            color: const Color(0xFF121212),
            child:
                SafeArea(top: false, child: LayoutBuilder(builder: _layout))));
  }
}
