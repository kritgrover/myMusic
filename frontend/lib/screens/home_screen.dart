import 'package:flutter/material.dart';
import 'search_screen.dart';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
import 'csv_upload_screen.dart';
import '../widgets/bottom_player.dart';
import '../services/player_state_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final PlayerStateService _playerStateService = PlayerStateService();

  final List<Widget> _screens = [];

  @override
  void initState() {
    super.initState();
    _screens.addAll([
      const SearchScreen(),
      DownloadsScreen(playerStateService: _playerStateService),
      PlaylistsScreen(playerStateService: _playerStateService),
      const CsvUploadScreen(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('myMusic'),
        backgroundColor: Colors.black,
        foregroundColor: neonBlue,
      ),
      body: Row(
        children: [
          // Side Navigation
          NavigationRail(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            useIndicator: true,
            indicatorColor: Colors.grey[900],
            selectedIconTheme: const IconThemeData(color: neonBlue, size: 24),
            unselectedIconTheme: const IconThemeData(color: Colors.grey, size: 24),
            destinations: [
              NavigationRailDestination(
                icon: const Icon(Icons.search),
                selectedIcon: const Icon(Icons.search),
                label: const Text('Search'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.download),
                selectedIcon: const Icon(Icons.download),
                label: const Text('Downloads'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.playlist_play),
                selectedIcon: const Icon(Icons.playlist_play),
                label: const Text('Playlists'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.upload_file),
                selectedIcon: const Icon(Icons.upload_file),
                label: const Text('CSV Upload'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
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
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _playerStateService.dispose();
    super.dispose();
  }
}


