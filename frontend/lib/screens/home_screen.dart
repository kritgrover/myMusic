import 'package:flutter/material.dart';
import 'dart:async';
import 'search_screen.dart';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
import 'csv_upload_screen.dart';
import '../widgets/bottom_player.dart';
import '../widgets/queue_panel.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final PlayerStateService _playerStateService = PlayerStateService();
  final QueueService _queueService = QueueService();
  bool _showQueuePanel = false;
  StreamSubscription? _completionSubscription;

  final List<Widget> _screens = [];

  @override
  void initState() {
    super.initState();
    _screens.addAll([
      SearchScreen(
        playerStateService: _playerStateService,
        queueService: _queueService,
      ),
      DownloadsScreen(
        playerStateService: _playerStateService,
        queueService: _queueService,
      ),
      PlaylistsScreen(
        playerStateService: _playerStateService,
        queueService: _queueService,
      ),
      const CsvUploadScreen(),
    ]);

    // Listen for song completion and auto-play next song in queue
    _completionSubscription = _playerStateService.audioPlayer.completionStream.listen((_) {
      // Only auto-play next if we're playing from queue
      if (_queueService.currentIndex >= 0 && _queueService.hasNext) {
        _queueService.playNext(_playerStateService);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('myMusic'),
      ),
      body: Row(
        children: [
          // Side Navigation
          Container(
            width: 80,
            decoration: const BoxDecoration(
              border: Border(
                right: BorderSide(color: Color(0xFF262626), width: 1),
              ),
            ),
            child: NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              labelType: NavigationRailLabelType.all,
              useIndicator: true,
              extended: false,
              minExtendedWidth: 80,
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.search_outlined),
                  selectedIcon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.download_outlined),
                  selectedIcon: const Icon(Icons.download),
                  label: const Text('Downloads'),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.playlist_play_outlined),
                  selectedIcon: const Icon(Icons.playlist_play),
                  label: const Text('Playlists'),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.upload_file_outlined),
                  selectedIcon: const Icon(Icons.upload_file),
                  label: const Text('CSV Upload'),
                ),
              ],
            ),
          ),
          // Main content
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: _screens[_currentIndex],
                ),
                // Bottom player
                ListenableBuilder(
                  listenable: _playerStateService,
                  builder: (context, _) {
                    return BottomPlayer(
                      playerService: _playerStateService.audioPlayer,
                      currentTrackName: _playerStateService.currentTrackName,
                      currentTrackArtist: _playerStateService.currentTrackArtist,
                      queueService: _queueService,
                      playerStateService: _playerStateService,
                      onQueueToggle: () {
                        setState(() {
                          _showQueuePanel = !_showQueuePanel;
                        });
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          // Queue panel
          if (_showQueuePanel)
            QueuePanel(
              queueService: _queueService,
              onClose: () {
                setState(() {
                  _showQueuePanel = false;
                });
              },
              onItemTap: (item) async {
                final index = _queueService.queue.indexOf(item);
                if (index >= 0) {
                  await _queueService.playItem(index, _playerStateService);
                }
              },
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _completionSubscription?.cancel();
    _playerStateService.dispose();
    _queueService.dispose();
    super.dispose();
  }
}


