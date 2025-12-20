import 'package:flutter/material.dart';
import 'dart:async';
import 'search_screen.dart';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
import 'csv_upload_screen.dart';
import '../widgets/bottom_player.dart';
import '../widgets/queue_panel.dart';
import '../widgets/csv_progress_bar.dart';
import '../widgets/download_progress_bar.dart';
import '../widgets/not_found_songs_dialog.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';

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
  
  // CSV progress tracking
  CsvProgress? _csvProgress;
  Timer? _csvProgressTimer;
  String? _csvFilename;
  
  // Download progress tracking
  DownloadProgress? _downloadProgress;
  Timer? _downloadProgressTimer;
  String? _downloadId;
  
  // Pending dialog data
  List<Map<String, dynamic>>? _pendingNotFoundSongs;
  String? _pendingPlaylistId;
  
  // Services for dialog
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();

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
        onDownloadStart: (downloadId) {
          setState(() {
            _downloadId = downloadId;
            _downloadProgress = null;
          });
          _startDownloadProgressPolling(downloadId);
        },
      ),
      CsvUploadScreen(
        onConversionStart: (filename) {
          setState(() {
            _csvFilename = filename;
            _csvProgress = null;
          });
          _startProgressPolling(filename);
        },
        onConversionComplete: (conversionResult) {
          _stopProgressPolling();
          setState(() {
            _csvFilename = null;
            _csvProgress = null;
            
            // Store pending dialog data
            if (conversionResult.notFound.isNotEmpty) {
              _pendingNotFoundSongs = conversionResult.notFound;
              _pendingPlaylistId = conversionResult.playlistId;
            }
          });
          
          // Show dialog after state update
          if (conversionResult.notFound.isNotEmpty) {
            print('CSV Conversion: ${conversionResult.notFound.length} songs not found, showing dialog...');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _pendingNotFoundSongs != null) {
                final notFound = _pendingNotFoundSongs!;
                final playlistId = _pendingPlaylistId;
                _pendingNotFoundSongs = null;
                _pendingPlaylistId = null;
                print('Showing dialog with ${notFound.length} not found songs');
                _showNotFoundSongsDialog(notFound, playlistId);
              }
            });
          } else {
            print('CSV Conversion: All songs found, no dialog needed');
          }
        },
      ),
    ]);

    // Listen for song completion and auto-play next song in queue
    _completionSubscription = _playerStateService.audioPlayer.completionStream.listen((_) {
      // Only auto-play next if we're playing from queue
      if (_queueService.currentIndex >= 0) {
        final nextItem = _queueService.getNextForCompletion();
        if (nextItem != null) {
          _queueService.playNext(_playerStateService);
        }
      }
    });
  }

  void _startProgressPolling(String filename) {
    final apiService = ApiService();
    _csvProgressTimer?.cancel();
    _csvProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      try {
        final progress = await apiService.getCsvProgress(filename);
        if (mounted) {
          setState(() {
            _csvProgress = progress;
          });
          if (progress.isCompleted || progress.hasError) {
            timer.cancel();
          }
        }
      } catch (e) {
        // Progress not available yet or conversion finished
        timer.cancel();
      }
    });
  }

  void _stopProgressPolling() {
    _csvProgressTimer?.cancel();
    _csvProgressTimer = null;
  }

  void _startDownloadProgressPolling(String downloadId) {
    _downloadProgressTimer?.cancel();
    _downloadProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      try {
        final progress = await _apiService.getDownloadProgress(downloadId);
        if (mounted) {
          setState(() {
            _downloadProgress = progress;
          });
          if (progress.isCompleted || progress.hasError) {
            timer.cancel();
            // Clear progress after a short delay
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) {
                setState(() {
                  _downloadProgress = null;
                  _downloadId = null;
                });
              }
            });
          }
        }
      } catch (e) {
        // Progress not available yet or download finished
        timer.cancel();
        if (mounted) {
          setState(() {
            _downloadProgress = null;
            _downloadId = null;
          });
        }
      }
    });
  }

  void _stopDownloadProgressPolling() {
    _downloadProgressTimer?.cancel();
    _downloadProgressTimer = null;
  }

  Future<void> _showNotFoundSongsDialog(List<Map<String, dynamic>> notFoundSongs, String? playlistId) async {
    if (!mounted || notFoundSongs.isEmpty) return;
    
    try {
      // Find the root navigator to ensure dialog shows above everything
      final navigator = Navigator.of(context, rootNavigator: true);
      
      await showDialog(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (dialogContext) => NotFoundSongsDialog(
          notFoundSongs: notFoundSongs,
          playlistId: playlistId,
          apiService: _apiService,
          playlistService: _playlistService,
        ),
      );
    } catch (e) {
      // If dialog fails, try again after a short delay
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && notFoundSongs.isNotEmpty) {
          showDialog(
            context: context,
            barrierDismissible: false,
            useRootNavigator: true,
            builder: (dialogContext) => NotFoundSongsDialog(
              notFoundSongs: notFoundSongs,
              playlistId: playlistId,
              apiService: _apiService,
              playlistService: _playlistService,
            ),
          );
        }
      });
    }
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
                  label: const Text('CSV'),
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
                // CSV Progress bar
                if (_csvProgress != null && _csvFilename != null)
                  CsvProgressBar(
                    processed: _csvProgress!.processed,
                    notFound: _csvProgress!.notFound,
                    total: _csvProgress!.total,
                    status: _csvProgress!.status,
                    progress: _csvProgress!.progress,
                  ),
                // Download Progress bar
                if (_downloadProgress != null && _downloadId != null)
                  DownloadProgressBar(
                    processed: _downloadProgress!.processed,
                    failed: _downloadProgress!.failed,
                    total: _downloadProgress!.total,
                    status: _downloadProgress!.status,
                    progress: _downloadProgress!.progress,
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
    _csvProgressTimer?.cancel();
    _downloadProgressTimer?.cancel();
    _playerStateService.dispose();
    _queueService.dispose();
    super.dispose();
  }
}


