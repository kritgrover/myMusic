import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as native;
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/widgets/bottom_player.dart';
import 'package:music_downloader/widgets/app_top_bar.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/saved_music_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class TestNativePlayer extends Fake implements native.AudioPlayer {
  final volumes = StreamController<double>.broadcast();
  double level = 0.6;
  @override
  double get volume => level;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Future<void> setVolume(double value) async {
    level = value;
    volumes.add(value);
  }
}

class TestAudio extends Fake implements AudioPlayerService {
  @override
  double get volume => player.volume;
  @override
  Stream<double> get volumeStream => player.volumeStream;
  @override
  Future<void> setVolume(double value) => player.setVolume(value);
  final nativePlayer = TestNativePlayer();
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
  final errors = StreamController<String>.broadcast();
  final seeks = <Duration>[];
  @override
  native.AudioPlayer get player => nativePlayer;
  @override
  Duration get position => const Duration(seconds: 20);
  @override
  Duration get duration => const Duration(seconds: 10);
  @override
  bool get isPlaying => false;
  @override
  bool get isBuffering => false;
  @override
  String? get currentUrl => 'https://example.test/audio';
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  Future<void> close() async {
    await positions.close();
    await durations.close();
    await states.close();
    await errors.close();
    await nativePlayer.volumes.close();
  }
}

class TestPlayerState extends Fake implements PlayerStateService {
  @override
  bool get isPreparing => false;
  final PlaylistTrack? track;
  TestPlayerState({this.track});
  @override
  PlaylistTrack? get currentTrack => track;
}

void main() {
  for (final width in [320.0, 390.0, 768.0, 1100.0, 1440.0]) {
    testWidgets('player fits width $width and clamps stale seek positions',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final audio = TestAudio();
      final saved = SavedMusicService(
          client: AuthHttpClient(
              client: MockClient((_) async => http.Response(
                  '{"tracks":[],"albums":[],"artists":[]}', 200))));
      addTearDown(saved.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
              bottomNavigationBar: BottomPlayer(
                  playerService: audio,
                  savedMusicService: saved,
                  playerStateService: TestPlayerState(
                      track: PlaylistTrack(
                          id: 'song',
                          title:
                              'A long song title that should fit beside the save control',
                          artist: 'An artist with a long name',
                          filename: 'song.mp3')),
                  onQueueToggle: () {},
                  onLyricsToggle: () {}))));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Save to Liked Songs'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final seek = tester.widget<Slider>(find.byType(Slider).first);
      expect(seek.value, seek.max);
      audio.durations.add(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
          tester.widget<Slider>(find.byType(Slider).first).onChanged, isNull);
      await tester.pumpWidget(const SizedBox());
      await audio.close();
    });
  }
  testWidgets(
      'mute restores the previous volume and follows external volume changes',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final audio = TestAudio();
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(bottomNavigationBar: BottomPlayer(playerService: audio))));
    await tester.pump();
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump();
    expect(audio.nativePlayer.level, 0.6);
    audio.nativePlayer.volumes.add(0.35);
    await tester.pump();
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(audio.nativePlayer.level, 0);
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump();
    expect(audio.nativePlayer.level, 0.35);
    await tester.pumpWidget(const SizedBox());
    await audio.close();
  });
  testWidgets('Previous restarts direct playback when queue is empty',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final audio = TestAudio();
    final queue = QueueService();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            bottomNavigationBar: BottomPlayer(
                playerService: audio,
                queueService: queue,
                playerStateService: TestPlayerState()))));
    await tester.tap(find.byTooltip('Previous'));
    await tester.pump();
    expect(audio.seeks, [Duration.zero]);
    await tester.pumpWidget(const SizedBox());
    queue.dispose();
    await audio.close();
  });
  testWidgets('asynchronous audio failures show a recovery message',
      (tester) async {
    final audio = TestAudio();
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(bottomNavigationBar: BottomPlayer(playerService: audio))));
    audio.errors.add('device unavailable');
    await tester.pump();
    expect(find.text('Playback failed. Try the track again.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await audio.close();
  });
  testWidgets('small search bar supports long usernames without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AppTopBar(
                searchController: controller,
                onSearchTap: () {},
                onSearchSubmitted: (_) {},
                onSearchChanged: (_) {},
                username: 'A very long listener name that must fit',
                onProfile: () {},
                onFriends: () {},
                onLogout: () {}))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
