import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/models/queue_item.dart';
import 'package:music_downloader/screens/player_screen.dart';
import 'package:music_downloader/services/audio_player_service.dart';
import 'package:music_downloader/services/auth_http_client.dart';
import 'package:music_downloader/services/player_state_service.dart';
import 'package:music_downloader/services/queue_service.dart';
import 'package:music_downloader/services/saved_music_service.dart';
import 'package:music_downloader/widgets/bottom_player.dart';

class _Audio extends Fake implements AudioPlayerService {
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration?>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
  final seeks = <Duration>[];
  bool playing = false;
  bool disposed = false;
  @override
  double get volume => 1;
  @override
  Stream<double> get volumeStream => const Stream.empty();
  @override
  Duration get position => const Duration(seconds: 20);
  @override
  Duration get duration => const Duration(seconds: 180);
  @override
  bool get isPlaying => playing;
  @override
  bool get isBuffering => false;
  @override
  String? get currentUrl => 'https://example.test/song.m4a';
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> dispose() async => disposed = true;
  Future<void> close() async {
    await positions.close();
    await durations.close();
    await states.close();
  }
}

class _Player extends ChangeNotifier implements PlayerStateService {
  final _Audio audio;
  int resumes = 0;
  int pauses = 0;
  _Player(this.audio);
  @override
  AudioPlayerService get audioPlayer => audio;
  @override
  bool get isPreparing => false;
  @override
  String? get playbackError => null;
  @override
  PlaylistTrack get currentTrack => PlaylistTrack(
      id: 'song',
      title: 'A song title long enough to wrap naturally on a phone',
      artist: 'An artist with a long name',
      filename: 'song.m4a');
  @override
  Future<void> resume() async {
    resumes++;
    audio.playing = true;
    audio.states.add(PlayerState.playing);
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauses++;
    audio.playing = false;
    audio.states.add(PlayerState.paused);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Queue extends QueueService {
  int nextCalls = 0;
  int previousCalls = 0;
  @override
  QueueItem get currentItem => QueueItem(id: 'song');
  @override
  bool get hasNext => true;
  @override
  Future<void> playNext(PlayerStateService playerService,
          {Future<String?> Function(QueueItem)? loadStreamingUrl,
          bool isAutomatic = false}) async =>
      nextCalls++;
  @override
  Future<void> playPrevious(PlayerStateService playerService,
          {Future<String?> Function(QueueItem)? loadStreamingUrl}) async =>
      previousCalls++;
}

void main() {
  late _Audio audio;
  late _Player player;
  late _Queue queue;
  late SavedMusicService saved;

  setUp(() {
    audio = _Audio();
    player = _Player(audio);
    queue = _Queue();
    saved = SavedMusicService(
        client: AuthHttpClient(
            client: MockClient((_) async =>
                http.Response('{"tracks":[],"albums":[],"artists":[]}', 200))));
  });
  tearDown(() async {
    queue.dispose();
    player.dispose();
    saved.dispose();
    await audio.close();
  });

  Future<void> showPlayer(WidgetTester tester,
      {double width = 390,
      double height = 844,
      double textScale = 1,
      VoidCallback? onQueue,
      VoidCallback? onLyrics}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: 47, bottom: 34),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: child!,
      ),
      home: Builder(
          builder: (context) => Scaffold(
                  body: Center(
                child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => PlayerScreen(
                                    player: player,
                                    queue: queue,
                                    savedMusicService: saved,
                                    onQueue: onQueue ?? () {},
                                    onLyrics: onLyrics ?? () {},
                                    onDownload: () {},
                                    onAddToPlaylist: () {},
                                  )),
                        ),
                    child: const Text('Open player')),
              ))),
    ));
    await tester.tap(find.text('Open player'));
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(430, 932),
    const Size(844, 390)
  ]) {
    testWidgets(
        'full player scrolls within phone cutouts at $size with large text',
        (tester) async {
      await showPlayer(tester,
          width: size.width, height: size.height, textScale: 1.8);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.byTooltip('Close now playing')).dy,
          greaterThanOrEqualTo(47));
      await tester.ensureVisible(find.text('Save on this device'));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.text('Save on this device')).dy,
          lessThan(size.height - 34));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('transport controls operate shared playback without disposing it',
      (tester) async {
    await showPlayer(tester);
    await tester.ensureVisible(find.byTooltip('Play'));
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(player.resumes, 1);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(player.pauses, 1);
    await tester.tap(find.byTooltip('Next'));
    await tester.tap(find.byTooltip('Previous'));
    expect(queue.nextCalls, 1);
    expect(queue.previousCalls, 1);
    await tester.tap(find.byTooltip('Shuffle off'));
    await tester.tap(find.byTooltip('Repeat off'));
    await tester.pump();
    expect(queue.isShuffled, isTrue);
    expect(queue.loopMode, LoopMode.queue);
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChanged!(42000);
    slider.onChangeEnd!(42000);
    await tester.pump();
    expect(audio.seeks, [const Duration(seconds: 42)]);
    await tester.tap(find.byTooltip('Close now playing'));
    await tester.pumpAndSettle();
    expect(find.text('Open player'), findsOneWidget);
    expect(audio.disposed, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['Queue', 'Lyrics']) {
    testWidgets('$action returns to library shell and invokes navigation',
        (tester) async {
      var queueCalls = 0;
      var lyricsCalls = 0;
      await showPlayer(tester,
          onQueue: () => queueCalls++, onLyrics: () => lyricsCalls++);
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('Open player'), findsOneWidget);
      expect(queueCalls, action == 'Queue' ? 1 : 0);
      expect(lyricsCalls, action == 'Lyrics' ? 1 : 0);
      expect(audio.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('embedded player closes through its account-owned shell',
      (tester) async {
    var showPlayer = true;
    var closeCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setShellState) {
        return showPlayer
            ? PlayerScreen(
                player: player,
                queue: queue,
                savedMusicService: saved,
                onQueue: () {},
                onLyrics: () {},
                onClose: () {
                  closeCalls++;
                  setShellState(() => showPlayer = false);
                },
              )
            : const Scaffold(body: Text('Library'));
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close now playing'));
    await tester.pumpAndSettle();
    expect(closeCalls, 1);
    expect(find.text('Library'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(audio.disposed, isFalse);
    audio.positions.add(const Duration(seconds: 25));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'mini player opens shared player and yields phone space to keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opened = 0;
    Future<void> showBar(double keyboard) => tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
                size: const Size(320, 568),
                textScaler: const TextScaler.linear(1.8),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: Scaffold(
                bottomNavigationBar: BottomPlayer(
              playerService: audio,
              playerStateService: player,
              savedMusicService: saved,
              onOpenPlayer: () => opened++,
              padBottom: false,
            )),
          ),
        ));
    await showBar(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open now playing'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
    await showBar(290);
    await tester.pump();
    expect(find.byTooltip('Open now playing'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await showBar(0);
    await tester.pump();
    expect(find.byTooltip('Open now playing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
