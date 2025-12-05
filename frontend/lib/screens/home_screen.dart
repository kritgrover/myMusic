import 'package:flutter/material.dart';
import 'search_screen.dart';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
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
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Downloader'),
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
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.search),
                selectedIcon: Icon(Icons.search),
                label: Text('Search'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.download),
                selectedIcon: Icon(Icons.download),
                label: Text('Downloads'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.playlist_play),
                selectedIcon: Icon(Icons.playlist_play),
                label: Text('Playlists'),
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


