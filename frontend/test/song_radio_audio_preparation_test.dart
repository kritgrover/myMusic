import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/song_radio_service.dart';

class _Deck extends Fake implements native.AudioPlayer {
  int starts = 0;
  Completer<void>? loadGate;
  Completer<void>? loading;
  @override
  double get volume => 1;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  bool get playing => starts > 0;
  @override
  native.ProcessingState get processingState => native.ProcessingState.ready;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<native.PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<native.SequenceState?> get sequenceStateStream => const Stream.empty();
  @override
  Future<Duration?> setAudioSource(native.AudioSource source,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition}) async {
    if (!(loading?.isCompleted ?? true)) loading!.complete();
    await loadGate?.future;
    return duration;
  }

  @override
  Future<void> play() async {
    starts++;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _Player extends Fake implements PlayerStateService {
  final AudioPlayerService audio;
  int revision = 0;
  _Player(this.audio);
  @override
  int get playbackRevision => revision;
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  String? get currentTrackUrl => audio.currentUrl;
  @override
  void cancelPendingPlayback() {
    revision++;
    audio.cancelPendingPlayback();
  }

  @override
  Future<void> streamTrack(String value,
      {String? trackName,
      String? trackArtist,
      String? url,
      String? album,
      double? duration,
      String? spotifyId,
      bool skipRecentlyPlayed = false}) async {
    revision++;
    await audio.playFromUrl(value);
  }

  @override
  Future<void> preloadTrackUrl(String value) async {}
}

void main() {
  test('turning autoplay off cancels a native decoder before audio starts',
      () async {
    final deck = _Deck();
    final audio = AudioPlayerService(
        player: deck,
        preloadPlayer: _Deck(),
        mediaUrlResolver: (url) async => url,
        useScheduledEngine: false);
    final player = _Player(audio);
    final queue = QueueService();
    final radio = SongRadioService(
        queue: queue,
        player: player,
        fetchRadio: (_, __) async => [
              QueueItem(
                  id: 'new',
                  title: 'New',
                  artist: 'Artist',
                  url: 'https://audio.example/new.m4a')
            ]);
    addTearDown(() {
      radio.dispose();
      queue.dispose();
      audio.dispose();
    });
    queue.addToQueue(QueueItem(
        id: 'old',
        title: 'Old',
        artist: 'Artist',
        url: 'https://audio.example/old.m4a'));
    await queue.playItem(0, player);
    expect(deck.starts, 1);
    radio.setAutoplayEnabled(true);
    deck.loadGate = Completer<void>();
    deck.loading = Completer<void>();
    final pending = radio.onQueueCompleted();
    await deck
        .loading!.future; // The real audio service is awaiting its decoder.
    radio.setAutoplayEnabled(false);
    deck.loadGate!.complete();
    expect(await pending, isFalse);
    expect(deck.starts, 1);
    expect(audio.currentUrl, 'https://audio.example/old.m4a');
    expect(queue.currentItem?.title, 'Old');
  });
}
