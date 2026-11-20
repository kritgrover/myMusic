import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../models/queue_item.dart';
import 'api_service.dart';
import 'audio_player_service.dart';
import 'auth_http_client.dart';
import 'player_state_service.dart';
import 'queue_service.dart';

/// Starts one native media session. The actual audio players continue to belong
/// to the signed-in account; this handler never creates a second player.
Future<MobileAudioHandler?> initializeMobileAudio() async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    return null;
  }
  if (MobileAudioHandler.instance != null) return MobileAudioHandler.instance;
  MobileAudioHandler? handler;
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    final candidate = MobileAudioHandler(
      interruptions: session.interruptionEventStream,
      becomingNoisy: session.becomingNoisyEventStream,
      deactivateSession: () async {
        await session.setActive(false);
      },
    );
    handler = candidate;
    await AudioService.init<MobileAudioHandler>(
      builder: () => candidate,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.music_downloader.playback',
        androidNotificationChannelName: 'Music playback',
        androidNotificationIcon: 'drawable/ic_stat_music',
        // Retain the paused media service so headset/lock-screen resume does
        // not try to start a new foreground service from the background.
        androidStopForegroundOnPause: false,
      ),
    );
    MobileAudioHandler.instance = handler;
    AudioPlayerService.externalInterruptionHandling = true;
    return handler;
  } catch (_) {
    // A native initialization failure must not prevent login or basic playback.
    // just_audio keeps its own interruption handling when this bridge is absent.
    handler?.dispose();
    debugPrint('Native media controls could not be initialized.');
    return null;
  }
}

class MobileAudioHandler extends BaseAudioHandler with SeekHandler {
  static MobileAudioHandler? instance;

  final Future<void> Function()? _deactivateSession;
  final AuthHttpClient _auth;
  final List<StreamSubscription<dynamic>> _sessionSubscriptions = [];
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  PlayerStateService? _player;
  QueueService? _queue;
  Future<String?> Function(QueueItem)? _loader;
  int _binding = 0;
  bool _pauseInterrupted = false;
  bool _resumeAfterInterruption = false;
  int? _resumeRevision;
  Future<void> _interruptions = Future.value();

  MobileAudioHandler({
    Stream<AudioInterruptionEvent>? interruptions,
    Stream<void>? becomingNoisy,
    Future<void> Function()? deactivateSession,
    AuthHttpClient? authClient,
  })  : _deactivateSession = deactivateSession,
        _auth = authClient ?? AuthHttpClient.shared {
    if (interruptions != null) {
      _sessionSubscriptions.add(interruptions.listen((event) {
        final binding = _binding;
        _interruptions = _interruptions.then((_) async {
          if (binding == _binding) await handleInterruption(event);
        }).catchError((Object _) {
          _publishControlError();
        });
      }));
    }
    if (becomingNoisy != null) {
      _sessionSubscriptions.add(becomingNoisy.listen((_) {
        // Route loss never resumes automatically, including after a call ends.
        unawaited(pause());
      }));
    }
  }

  void attach(PlayerStateService player, QueueService queue,
      {Future<String?> Function(QueueItem)? loadStreamingUrl}) {
    if (identical(_player, player) && identical(_queue, queue)) {
      _loader = loadStreamingUrl;
      return;
    }
    final previous = _player;
    if (previous != null) detach(previous);
    ++_binding;
    _player = player;
    _queue = queue;
    _loader = loadStreamingUrl;
    player.addListener(_publish);
    queue.addListener(_publish);
    _playerSubscriptions.addAll([
      player.audioPlayer.positionStream.listen((_) => _publishPosition()),
      player.audioPlayer.durationStream.listen((_) => _publish()),
    ]);
    _publish();
  }

  /// Called before account-owned services are disposed. A late disposal from
  /// an old account cannot remove the current account's media controls.
  void detach(PlayerStateService player) {
    if (!identical(_player, player)) return;
    ++_binding;
    player.removeListener(_publish);
    _queue?.removeListener(_publish);
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _playerSubscriptions.clear();
    _player = null;
    _queue = null;
    _loader = null;
    _resetInterruption();
    queue.add(const []);
    mediaItem.add(null);
    playbackState.add(PlaybackState());
    unawaited(_deactivate());
  }

  Duration? _duration(double? seconds) =>
      seconds == null || !seconds.isFinite || seconds <= 0
          ? null
          : Duration(milliseconds: (seconds * 1000).round());

  Uri? _artUri(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('/')) return Uri.file(value);
    var uri = Uri.tryParse(value);
    if (uri != null && _auth.isBackendUrl(value)) {
      uri = Uri.parse(_auth.cacheScopedUrl(
          ApiService.canonicalMediaUrl(value, baseUrl: _auth.baseUrl)));
    }
    return uri != null &&
            uri.userInfo.isEmpty &&
            ['http', 'https', 'file'].contains(uri.scheme)
        ? uri
        : null;
  }

  Map<String, String>? _artHeaders(Uri? uri) {
    if (uri == null) return null;
    final headers = _auth.authHeadersForUrl(uri.toString());
    return headers.isEmpty ? null : headers;
  }

  MediaItem _queueMediaItem(QueueItem item, int index) {
    final artwork = _artUri(item.thumbnail);
    return MediaItem(
      id: 'queue:$index',
      title: item.displayTitle,
      artist: item.artist,
      album: item.album,
      duration: _duration(item.duration),
      artUri: artwork,
      artHeaders: _artHeaders(artwork),
    );
  }

  void _publish() {
    final player = _player;
    final queueService = _queue;
    if (player == null || queueService == null) return;
    final items = queueService.queue;
    queue.add([
      for (var index = 0; index < items.length; index++)
        _queueMediaItem(items[index], index),
    ]);
    final track = player.currentTrack;
    final item = queueService.currentItem;
    final isCurrentQueueItem = track != null &&
        item != null &&
        track.title == item.displayTitle &&
        track.artist == item.artist;
    final audio = player.audioPlayer;
    final duration = audio.duration > Duration.zero
        ? audio.duration
        : _duration(track?.duration);
    final artwork = _artUri(
        track?.thumbnail ?? (isCurrentQueueItem ? item.thumbnail : null));
    mediaItem.add(track == null
        ? null
        : MediaItem(
            id: isCurrentQueueItem
                ? 'queue:${queueService.currentIndex}'
                : 'current',
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: duration,
            artUri: artwork,
            artHeaders: _artHeaders(artwork),
          ));
    final controls = <MediaControl>[
      if (track != null) MediaControl.skipToPrevious,
      if (track != null || items.isNotEmpty)
        audio.isPlaying ? MediaControl.pause : MediaControl.play,
      if (queueService.hasNext) MediaControl.skipToNext,
      if (track != null) MediaControl.stop,
    ];
    playbackState.add(PlaybackState(
      controls: controls,
      androidCompactActionIndices:
          List.generate(controls.length.clamp(0, 3), (index) => index),
      systemActions: {
        if (track != null) ...{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
        if (items.isNotEmpty) MediaAction.skipToQueueItem,
      },
      processingState: player.isPreparing || audio.isBuffering
          ? AudioProcessingState.buffering
          : track == null
              ? AudioProcessingState.idle
              : AudioProcessingState.ready,
      playing: audio.isPlaying,
      updatePosition: audio.position,
      bufferedPosition: audio.position,
      speed: 1,
      queueIndex: isCurrentQueueItem ? queueService.currentIndex : null,
      repeatMode: switch (queueService.loopMode) {
        LoopMode.none => AudioServiceRepeatMode.none,
        LoopMode.queue => AudioServiceRepeatMode.all,
        LoopMode.single => AudioServiceRepeatMode.one,
      },
      shuffleMode: queueService.isShuffled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      errorCode: player.playbackError == null ? null : 1,
      errorMessage: player.playbackError == null
          ? null
          : 'This song could not play. Open the app to try again.',
    ));
  }

  void _publishPosition() {
    final player = _player;
    if (player == null) return;
    playbackState.add(playbackState.value.copyWith(
      updatePosition: player.audioPlayer.position,
      bufferedPosition: player.audioPlayer.position,
    ));
  }

  void _publishControlError() {
    if (_player == null) return;
    playbackState.add(playbackState.value.copyWith(
      errorCode: 1,
      errorMessage: 'This song could not play. Open the app to try again.',
    ));
  }

  Future<void> _run(
      Future<void> Function(PlayerStateService, QueueService) action) async {
    final player = _player;
    final queue = _queue;
    if (player == null || queue == null) return;
    final binding = _binding;
    try {
      await action(player, queue);
      if (binding == _binding) _publish();
    } catch (_) {
      if (binding == _binding) _publishControlError();
    }
  }

  void _resetInterruption() {
    _pauseInterrupted = false;
    _resumeAfterInterruption = false;
    _resumeRevision = null;
  }

  @override
  Future<void> play() {
    _resumeAfterInterruption = false;
    return _run((player, queue) async {
      if (player.audioPlayer.isPlaying) return;
      if (player.currentTrack != null) {
        await player.resume();
      } else if (queue.queueLength > 0) {
        await queue.playItem(
            queue.currentIndex >= 0 ? queue.currentIndex : 0, player,
            loadStreamingUrl: _loader);
      }
    });
  }

  @override
  Future<void> pause() {
    _resumeAfterInterruption = false;
    return _run((player, _) => player.pause());
  }

  @override
  Future<void> stop() async {
    final binding = _binding;
    _resetInterruption();
    await _run((player, _) => player.stop());
    if (binding == _binding) await _deactivate();
  }

  Future<void> _deactivate() async {
    try {
      await _deactivateSession?.call();
    } catch (_) {
      debugPrint('The native audio session could not be released.');
    }
  }

  @override
  Future<void> seek(Duration position) => _run((player, _) async {
        final duration = player.audioPlayer.duration;
        final bounded = position < Duration.zero
            ? Duration.zero
            : duration > Duration.zero && position > duration
                ? duration
                : position;
        await player.audioPlayer.seek(bounded);
      });

  @override
  Future<void> skipToNext() {
    _resumeAfterInterruption = false;
    return _run(
        (player, queue) => queue.playNext(player, loadStreamingUrl: _loader));
  }

  @override
  Future<void> skipToPrevious() {
    _resumeAfterInterruption = false;
    return _run((player, queue) =>
        queue.playPrevious(player, loadStreamingUrl: _loader));
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _resumeAfterInterruption = false;
    return _run((player, queue) =>
        queue.playItem(index, player, loadStreamingUrl: _loader));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _run((_, queue) async {
        final desired = switch (repeatMode) {
          AudioServiceRepeatMode.one => LoopMode.single,
          AudioServiceRepeatMode.all ||
          AudioServiceRepeatMode.group =>
            LoopMode.queue,
          AudioServiceRepeatMode.none => LoopMode.none,
        };
        while (queue.loopMode != desired) {
          queue.toggleLoopMode();
        }
      });

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _run((_, queue) async {
        final enabled = shuffleMode != AudioServiceShuffleMode.none;
        if (queue.isShuffled != enabled) queue.toggleShuffle();
      });

  /// Handles the shared audio focus, rather than independently resuming the two
  /// just_audio decks after a phone call or navigation announcement.
  Future<void> handleInterruption(AudioInterruptionEvent event) async {
    final player = _player;
    if (player == null) return;
    final binding = _binding;
    if (event.type == AudioInterruptionType.duck) {
      await player.audioPlayer.setInterruptionDucking(event.begin);
      return;
    }
    if (event.begin) {
      if (!_pauseInterrupted) {
        _resumeAfterInterruption =
            player.audioPlayer.isPlaying && !player.isPreparing;
      } else if (_resumeRevision != player.playbackRevision) {
        _resumeAfterInterruption = false;
      }
      if (event.type == AudioInterruptionType.unknown) {
        _resumeAfterInterruption = false;
      }
      _pauseInterrupted = true;
      final paused = player.pause();
      _resumeRevision = player.playbackRevision;
      await paused;
      return;
    }
    final shouldResume = _pauseInterrupted &&
        _resumeAfterInterruption &&
        event.type == AudioInterruptionType.pause &&
        player.playbackRevision == _resumeRevision;
    _resetInterruption();
    if (shouldResume && binding == _binding) {
      await _run((player, _) => player.resume());
    }
  }

  void dispose() {
    final player = _player;
    if (player != null) detach(player);
    for (final subscription in _sessionSubscriptions) {
      unawaited(subscription.cancel());
    }
    _sessionSubscriptions.clear();
    if (identical(instance, this)) {
      instance = null;
      AudioPlayerService.externalInterruptionHandling = false;
    }
  }
}
