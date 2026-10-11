import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:music_downloader/config.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/recently_played_service.dart';
import 'package:music_downloader/services/recommendation_service.dart';

class _Native extends Fake implements native.AudioPlayer {
  final states = StreamController<native.PlayerState>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final volumes = StreamController<double>.broadcast();
  final urls = <String>[];
  final starts = <Duration?>[];
  final seeks = <Duration>[];
  int plays = 0;
  bool started = false;
  double currentVolume = 1;
  Duration currentPosition = Duration.zero;
  Duration loadedDuration = const Duration(seconds: 60);
  native.ProcessingState processing = native.ProcessingState.idle;
  Completer<void>? loadGate;

  @override
  Duration get position => currentPosition;
  @override
  Duration? get duration => loadedDuration;
  @override
  double get volume => currentVolume;
  @override
  bool get playing => started;
  @override
  native.ProcessingState get processingState => processing;
  @override
  native.PlayerState get playerState => native.PlayerState(started, processing);
  @override
  Stream<native.PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Stream<native.SequenceState?> get sequenceStateStream => const Stream.empty();
  @override
  native.SequenceState? get sequenceState => null;
  @override
  Future<Duration?> setAudioSource(native.AudioSource source,
          {bool preload = true,
          int? initialIndex,
          Duration? initialPosition}) =>
      setUrl(
          (source as native.ConcatenatingAudioSource).children.first
                  is native.UriAudioSource
              ? (source.children.first as native.UriAudioSource).uri.toString()
              : '',
          initialPosition: initialPosition);

  @override
  Future<Duration?> setUrl(String url,
      {Map<String, String>? headers,
      Duration? initialPosition,
      bool preload = true,
      dynamic tag}) async {
    urls.add(url);
    starts.add(initialPosition);
    await loadGate?.future;
    currentPosition = initialPosition ?? Duration.zero;
    processing = native.ProcessingState.ready;
    durations.add(loadedDuration);
    return loadedDuration;
  }

  @override
  Future<void> play() async {
    plays++;
    started = true;
    states.add(playerState);
  }

  @override
  Future<void> pause() async {
    started = false;
    states.add(playerState);
  }

  @override
  Future<void> stop() async {
    started = false;
    processing = native.ProcessingState.idle;
    states.add(playerState);
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async {
    if (value == null) return;
    seeks.add(value);
    currentPosition = value;
    positions.add(value);
  }

  @override
  Future<void> setVolume(double value) async {
    currentVolume = value;
    volumes.add(value);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await positions.close();
    await durations.close();
    await volumes.close();
  }
}

class _Recent extends Fake implements RecentlyPlayedService {
  final titles = <String>[];
  @override
  Future<void> addSong(
      {required String id,
      required String title,
      String? artist,
      String? thumbnail,
      String? filename,
      String? url,
      String? album,
      double? duration,
      String? spotifyId}) async {
    titles.add(title);
  }
}

class _Recommendations extends Fake implements RecommendationService {
  final titles = <String>[];
  final events = <Map<String, dynamic>>[];
  @override
  String get sessionScope => 'test';
  @override
  Future<void> recordListeningEvent(Map<String, dynamic> body) async =>
      events.add(Map.of(body));
  @override
  Future<void> logHistory(
      {required String title,
      required String artist,
      required double durationPlayed,
      String? spotifyId}) async {
    titles.add(title);
  }
}

void main() {
  const canonical = '${AppConfig.apiBaseUrl}/downloads/fixture/tone.mp3';
  const second = '${AppConfig.apiBaseUrl}/downloads/fixture/second.mp3';

  group('paused audio restoration', () {
    test('restore is metadata only and discards an expired capability', () {
      final player = _Native();
      var authorizations = 0;
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async {
            authorizations++;
            return url;
          });
      addTearDown(audio.dispose);
      audio.restorePaused('$canonical?media_token=expired',
          position: const Duration(seconds: 22),
          duration: const Duration(seconds: 60));
      expect(audio.currentUrl, canonical);
      expect(audio.position, const Duration(seconds: 22));
      expect(audio.duration, const Duration(seconds: 60));
      expect(audio.isPlaying, isFalse);
      expect(player.urls, isEmpty);
      expect(player.plays, 0);
      expect(authorizations, 0);
    });

    test(
        'explicit resume obtains fresh authorization and starts at saved position',
        () async {
      final player = _Native();
      final resolved = <String>[];
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async {
            resolved.add(url);
            return '$url?media_token=fresh';
          });
      addTearDown(audio.dispose);
      audio.restorePaused(canonical,
          position: const Duration(seconds: 22),
          duration: const Duration(seconds: 60));
      await audio.resume();
      expect(resolved, [canonical]);
      expect(player.urls.single, '$canonical?media_token=fresh');
      expect(player.position, const Duration(seconds: 22));
      expect(player.plays, 1);
      expect(audio.currentUrl, canonical);
    });

    test('saved seek stays offline and resume clamps to the actual duration',
        () async {
      final player = _Native()..loadedDuration = const Duration(seconds: 10);
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async => '$url?media_token=fresh');
      addTearDown(audio.dispose);
      audio.restorePaused(canonical,
          position: const Duration(seconds: 30),
          duration: const Duration(seconds: 120));
      await audio.seek(const Duration(seconds: 80));
      expect(audio.position, const Duration(seconds: 80));
      expect(player.urls, isEmpty);
      expect(player.seeks, isEmpty);
      await audio.resume();
      expect(player.position, lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(player.position, greaterThanOrEqualTo(Duration.zero));
      expect(player.plays, 1);
    });

    test('a new restore cancels a previous pending resume authorization',
        () async {
      final player = _Native();
      final authorization = Completer<String>();
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (_) => authorization.future);
      addTearDown(audio.dispose);
      audio.restorePaused(canonical, position: const Duration(seconds: 22));
      final resuming = audio.resume();
      audio.restorePaused(second, position: const Duration(seconds: 8));
      authorization.complete('$canonical?media_token=late');
      await resuming;
      expect(audio.currentUrl, second);
      expect(audio.position, const Duration(seconds: 8));
      expect(player.urls, isEmpty);
      expect(player.plays, 0);
    });

    test('cancelled pending native source load never starts restored playback',
        () async {
      final player = _Native()..loadGate = Completer<void>();
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async => '$url?media_token=fresh');
      addTearDown(audio.dispose);
      audio.restorePaused(canonical, position: const Duration(seconds: 22));
      final resuming = audio.resume();
      await Future<void>.delayed(Duration.zero);
      expect(player.urls, hasLength(1));
      audio.cancelPendingPlayback();
      player.loadGate!.complete();
      await resuming;
      expect(player.plays, 0);
    });

    test('seek while resumed media loads keeps the most recent saved position',
        () async {
      final player = _Native()..loadGate = Completer<void>();
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async => '$url?media_token=fresh');
      addTearDown(audio.dispose);
      audio.restorePaused(canonical,
          position: const Duration(seconds: 7),
          duration: const Duration(seconds: 60));
      final resuming = audio.resume();
      await Future<void>.delayed(Duration.zero);
      expect(player.urls, hasLength(1));
      await audio.seek(const Duration(seconds: 25));
      player.loadGate!.complete();
      await resuming;
      expect(player.position, const Duration(seconds: 25));
      expect(player.plays, 1);
    });

    test('resuming broadcasts the actual duration after saved metadata',
        () async {
      final player = _Native()..loadedDuration = const Duration(seconds: 10);
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async => '$url?media_token=fresh');
      addTearDown(audio.dispose);
      final observed = <Duration?>[];
      final subscription = audio.durationStream.listen(observed.add);
      addTearDown(subscription.cancel);
      audio.restorePaused(canonical,
          position: const Duration(seconds: 7),
          duration: const Duration(seconds: 120));
      await Future<void>.delayed(Duration.zero);
      expect(observed.last, const Duration(seconds: 120));
      await audio.resume();
      await Future<void>.delayed(Duration.zero);
      expect(audio.duration, const Duration(seconds: 10));
      expect(observed.last, const Duration(seconds: 10));
    });

    test('resume at the saved track ending replays from the beginning',
        () async {
      final player = _Native();
      final audio = AudioPlayerService(
          player: player,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async => '$url?media_token=fresh');
      addTearDown(audio.dispose);
      audio.restorePaused(canonical,
          position: const Duration(seconds: 60),
          duration: const Duration(seconds: 60));
      expect(audio.position, const Duration(seconds: 60));
      expect(player.urls, isEmpty);
      await audio.resume();
      expect(player.position, Duration.zero);
      expect(player.plays, 1);
    });
  });

  group('player session preparation', () {
    late _Native nativePlayer;
    late AudioPlayerService audio;
    late _Recent recent;
    late _Recommendations recommendations;
    late PlayerStateService player;
    late List<String> authorizations;

    setUp(() {
      nativePlayer = _Native();
      authorizations = [];
      audio = AudioPlayerService(
          player: nativePlayer,
          preloadPlayer: _Native(),
          mediaUrlResolver: (url) async {
            authorizations.add(url);
            return '$url?media_token=fresh';
          });
      recent = _Recent();
      recommendations = _Recommendations();
      player = PlayerStateService(
          audioPlayerService: audio,
          recentlyPlayedService: recent,
          recommendationService: recommendations);
    });
    tearDown(() => player.dispose());

    test(
        'prepare restores track, position and volume without loading or history',
        () async {
      await player.preparePaused(
          QueueItem(
              id: 'saved',
              title: 'Restored Song',
              artist: 'Fixture',
              album: 'Album',
              filename: 'fixture/tone.mp3',
              thumbnail: 'https://images.example/cover.png'),
          position: const Duration(seconds: 22),
          duration: const Duration(seconds: 60),
          volume: 0.4);
      expect(player.currentTrackName, 'Restored Song');
      expect(player.currentTrackArtist, 'Fixture');
      expect(player.currentTrack?.filename, 'fixture/tone.mp3');
      expect(player.currentTrack?.album, 'Album');
      expect(audio.position, const Duration(seconds: 22));
      expect(nativePlayer.volume, 0.4);
      expect(nativePlayer.urls, isEmpty);
      expect(nativePlayer.plays, 0);
      expect(authorizations, isEmpty);
      expect(recent.titles, isEmpty);
      expect(recommendations.titles, isEmpty);
    });

    test('lazy restored track resolves on resume and enters local recents once',
        () async {
      var resolutions = 0;
      await player.preparePaused(
          QueueItem(
              id: 'lazy',
              title: 'Lazy Song',
              artist: 'Fixture',
              originalUrl: 'https://www.youtube.com/watch?v=demo0000001'),
          position: const Duration(seconds: 7),
          duration: const Duration(seconds: 60), loadStreamingUrl: (_) async {
        resolutions++;
        return canonical;
      });
      expect(resolutions, 0);
      expect(authorizations, isEmpty);
      await player.resume();
      await Future<void>.delayed(Duration.zero);
      expect(resolutions, 1);
      expect(nativePlayer.position, const Duration(seconds: 7));
      expect(nativePlayer.plays, 1);
      expect(recent.titles, ['Lazy Song']);
      expect(recommendations.titles, isEmpty);
      await player.pause();
      await player.resume();
      await Future<void>.delayed(Duration.zero);
      expect(resolutions, 1);
      expect(recent.titles, ['Lazy Song']);
      expect(recommendations.titles, isEmpty);
    });

    test(
        'failed lazy restoration is retryable and records no unsuccessful history',
        () async {
      var attempts = 0;
      await player.preparePaused(
          QueueItem(
              id: 'lazy',
              title: 'Retry Song',
              artist: 'Fixture',
              originalUrl: 'https://www.youtube.com/watch?v=demo0000001'),
          position: const Duration(seconds: 7),
          loadStreamingUrl: (_) async => ++attempts == 1 ? null : canonical);
      await expectLater(player.resume(), throwsA(isA<StateError>()));
      expect(nativePlayer.plays, 0);
      expect(recent.titles, isEmpty);
      expect(recommendations.titles, isEmpty);
      expect(player.playbackError, isNotNull);
      await player.resume();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 2);
      expect(nativePlayer.position, const Duration(seconds: 7));
      expect(recent.titles, ['Retry Song']);
      expect(player.playbackError, isNull);
    });

    test(
        'late lazy result cannot replace a newer restored track or enter history',
        () async {
      final lazy = Completer<String?>();
      final started = Completer<void>();
      await player.preparePaused(
          QueueItem(
              id: 'old',
              title: 'Old Song',
              artist: 'Fixture',
              originalUrl: 'https://www.youtube.com/watch?v=demo0000001'),
          position: const Duration(seconds: 22), loadStreamingUrl: (_) {
        started.complete();
        return lazy.future;
      });
      final resuming = player.resume();
      await started.future;
      await player.preparePaused(
          QueueItem(
              id: 'new',
              title: 'New Song',
              artist: 'Fixture',
              filename: 'fixture/second.mp3'),
          position: const Duration(seconds: 8));
      lazy.complete(canonical);
      await resuming;
      expect(player.currentTrackName, 'New Song');
      expect(audio.position, const Duration(seconds: 8));
      expect(nativePlayer.urls, isEmpty);
      expect(nativePlayer.plays, 0);
      expect(recent.titles, isEmpty);
      expect(recommendations.titles, isEmpty);
    });
  });
}
