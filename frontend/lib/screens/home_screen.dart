import 'package:flutter/material.dart';
import 'dart:async';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
import 'csv_upload_screen.dart';
import 'playlist_detail_screen.dart';
import '../widgets/bottom_player.dart';
import '../widgets/queue_panel.dart';
import '../widgets/csv_progress_bar.dart';
import '../widgets/download_progress_bar.dart';
import '../widgets/not_found_songs_dialog.dart';
import '../widgets/video_card.dart';
import '../widgets/album_cover.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../services/recently_played_service.dart';
import '../models/queue_item.dart';
import '../models/playlist.dart';
import '../utils/song_display_utils.dart';
import '../services/recommendation_service.dart';
import '../widgets/horizontal_song_list.dart';
import '../widgets/genre_card.dart';
import 'genre_screen.dart';
import 'spotify_playlist_screen.dart';
import 'made_for_you_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late final RecentlyPlayedService _recentlyPlayedService;
  late final PlayerStateService _playerStateService;
  final QueueService _queueService = QueueService();
  bool _showQueuePanel = false;
  StreamSubscription? _completionSubscription;
  DateTime? _lastCompletionTime;
  int? _lastCompletedIndex;
  
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
  // Pending playlist ID for navigation from recently played
  String? _navigateToPlaylistId;
  
  // Services for dialog
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  final RecommendationService _recommendationService = RecommendationService();

  // Recommendations
  List<VideoInfo> _dailyMix = [];
  bool _isLoadingRecommendations = false;
  final List<String> _genres = ['Pop', 'Rock', 'Hip Hop', 'Electronic', 'Jazz', 'Classical', 'Indie', 'Metal'];
  
  // Genre navigation
  String? _selectedGenre;
  
  // Made for You navigation
  bool _showMadeForYou = false;

  // Search state
  final TextEditingController _searchController = TextEditingController();
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _recentlyPlayedService = RecentlyPlayedService();
    _playerStateService = PlayerStateService(recentlyPlayedService: _recentlyPlayedService);

    // Listen for song completion and auto-play next song in queue
    _completionSubscription = _playerStateService.audioPlayer.completionStream.listen((_) {
      // Only auto-play next if we're playing from queue
      if (_queueService.currentIndex >= 0) {
        final currentIndex = _queueService.currentIndex;
        
        // Debounce: ignore if this is a duplicate completion for the same song
        final now = DateTime.now();
        if (_lastCompletedIndex == currentIndex && 
            _lastCompletionTime != null &&
            now.difference(_lastCompletionTime!) < const Duration(milliseconds: 1000)) {
          return;
        }
        
        _lastCompletedIndex = currentIndex;
        _lastCompletionTime = now;
        
        final nextItem = _queueService.getNextForCompletion();
        if (nextItem != null) {
          _queueService.playNext(_playerStateService);
        }
      }
    });

    // Listen to recently played service changes
    _recentlyPlayedService.addListener(_onRecentlyPlayedChanged);
    
    // Load items if they haven't been loaded yet
    if (_recentlyPlayedService.items.isEmpty) {
      // Wait a bit for async load to complete, then check again
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && _recentlyPlayedService.items.isNotEmpty) {
          setState(() {});
        }
      });
    }
    
    _fetchRecommendations();
  }

  Future<void> _fetchRecommendations() async {
    setState(() {
      _isLoadingRecommendations = true;
    });

    try {
      final dailyMixTracks = await _recommendationService.getDailyMix();

      if (mounted) {
        setState(() {
          _dailyMix = dailyMixTracks.map((t) => VideoInfo(
            id: t.url ?? '',
            title: t.title,
            uploader: t.artist ?? 'Unknown',
            duration: t.duration ?? 0,
            url: t.url ?? '',
            thumbnail: t.thumbnail ?? '',
          )).toList();
          
          _isLoadingRecommendations = false;
        });
      }
    } catch (e) {
      print('Error fetching recommendations: $e');
      if (mounted) {
        setState(() {
          _isLoadingRecommendations = false;
        });
      }
    }
  }

  void _onRecentlyPlayedChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildCurrentScreen() {
    switch (_currentIndex) {
      case 0:
        // If Made for You is selected, show that screen
        if (_showMadeForYou) {
          return MadeForYouScreen(
            songs: _dailyMix,
            playerStateService: _playerStateService,
            queueService: _queueService,
            recentlyPlayedService: _recentlyPlayedService,
            onBack: () {
              setState(() {
                _showMadeForYou = false;
              });
            },
          );
        }
        // If a genre is selected, show genre screen, otherwise show home content
        if (_selectedGenre != null) {
          return GenreScreen(
            genre: _selectedGenre!,
            playerStateService: _playerStateService,
            queueService: _queueService,
            recentlyPlayedService: _recentlyPlayedService,
            embedded: true,
            onBack: () {
              setState(() {
                _selectedGenre = null;
              });
            },
            onDownloadStart: (downloadId) {
              setState(() {
                _downloadId = downloadId;
                _downloadProgress = null;
              });
              _startDownloadProgressPolling(downloadId);
            },
          );
        }
        return _buildHomeContent();
      case 1:
        return DownloadsScreen(
          playerStateService: _playerStateService,
          queueService: _queueService,
          recentlyPlayedService: _recentlyPlayedService,
        );
      case 2:
        final playlistId = _navigateToPlaylistId;
        // Clear the navigation ID after using it
        if (_navigateToPlaylistId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _navigateToPlaylistId = null;
              });
            }
          });
        }
        return PlaylistsScreen(
          playerStateService: _playerStateService,
          queueService: _queueService,
          recentlyPlayedService: _recentlyPlayedService,
          initialPlaylistId: playlistId,
          onDownloadStart: (downloadId) {
            setState(() {
              _downloadId = downloadId;
              _downloadProgress = null;
            });
            _startDownloadProgressPolling(downloadId);
          },
        );
      case 3:
        return CsvUploadScreen(
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
        );
      default:
        return _buildHomeContent();
    }
  }

  Widget _buildHomeContent() {
    return Column(
      children: [
        // Search section
        Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Discover Music',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search for songs, artists, albums...',
                  prefixIcon: const Icon(Icons.search, size: 24),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchResults = [];
                            });
                          },
                        )
                      : null,
                ),
                onSubmitted: (_) => _performSearch(),
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
              ),
            ],
          ),
        ),
        // Search results or recently played section
        Expanded(
          child: _isSearching
              ? const Center(child: CircularProgressIndicator())
              : _searchResults.isNotEmpty
                  ? ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: _searchResults.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        return VideoCard(
                          video: _searchResults[index],
                          onStream: () async {
                            await _streamVideo(_searchResults[index]);
                          },
                          onDownload: () async {
                            await _downloadVideo(_searchResults[index]);
                          },
                          onAddToPlaylist: () async {
                            await _showAddToPlaylistDialog(_searchResults[index]);
                          },
                          onAddToQueue: () async {
                            await _addToQueue(_searchResults[index]);
                          },
                        );
                      },
                    )
                  : _searchController.text.isNotEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.search_off,
                                size: 64,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No results found',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Try a different search term',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _fetchRecommendations,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Recently Played
                                ListenableBuilder(
                                  listenable: _recentlyPlayedService,
                                  builder: (context, _) {
                                    if (_recentlyPlayedService.items.isEmpty) return const SizedBox.shrink();
                                    
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                                          child: Text(
                                            'Recently Played',
                                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 24.0),
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              final cardWidth = (constraints.maxWidth - 16) / 2;
                                              final cardHeight = 112.0;
                                              final aspectRatio = cardWidth / cardHeight;
                                              
                                              return GridView.builder(
                                                shrinkWrap: true,
                                                physics: const NeverScrollableScrollPhysics(),
                                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: 2,
                                                  crossAxisSpacing: 16,
                                                  mainAxisSpacing: 16,
                                                  childAspectRatio: aspectRatio,
                                                ),
                                                itemCount: _recentlyPlayedService.items.length,
                                                itemBuilder: (context, index) {
                                                  return _buildRecentlyPlayedCard(_recentlyPlayedService.items[index]);
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),

                                if (_isLoadingRecommendations)
                                  const Padding(
                                    padding: EdgeInsets.all(32.0),
                                    child: Center(child: CircularProgressIndicator()),
                                  )
                                else ...[
                                  HorizontalSongList(
                                    title: 'Songs for You',
                                    songs: _dailyMix,
                                    onPlay: _streamVideo,
                                    onAddToQueue: _addToQueue,
                                    maxItems: 8,
                                    onShowAll: () {
                                      setState(() {
                                        _showMadeForYou = true;
                                      });
                                    },
                                  ),
                                ],

                                // Genres
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                                  child: Text(
                                    'Browse by Genre',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final cardWidth = (constraints.maxWidth - 48) / 4; // 4 columns with 3 gaps of 16px
                                      final cardHeight = 112.0;
                                      final aspectRatio = cardWidth / cardHeight;
                                      
                                      return GridView.builder(
                                        shrinkWrap: true,
                                        physics: const NeverScrollableScrollPhysics(),
                                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 4,
                                          crossAxisSpacing: 16,
                                          mainAxisSpacing: 16,
                                          childAspectRatio: aspectRatio,
                                        ),
                                        itemCount: _genres.length,
                                        itemBuilder: (context, index) {
                                          return GenreCard(
                                            genre: _genres[index],
                                            onTap: () {
                                              setState(() {
                                                _selectedGenre = _genres[index];
                                              });
                                            },
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 120), // Bottom padding for player
                              ],
                            ),
                          ),
                        ),
        ),
      ],
    );
  }

  Widget _buildRecentlyPlayedCard(RecentlyPlayedItem item) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;
    
    return Card(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _handleRecentlyPlayedTap(item),
          borderRadius: BorderRadius.circular(12),
          hoverColor: surfaceHover,
          child: SizedBox(
            height: 112, // Match VideoCard height: 80 (image) + 32 (padding)
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  // Thumbnail/Album Cover on the left
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: item.type == RecentlyPlayedType.playlist
                        ? item.thumbnail != null && item.thumbnail!.isNotEmpty
                            ? Image.network(
                                item.thumbnail!,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    width: 80,
                                    height: 80,
                                    color: surfaceHover,
                                    child: Icon(
                                      Icons.playlist_play,
                                      size: 32,
                                      color: primaryColor,
                                    ),
                                  );
                                },
                              )
                            : Container(
                                width: 80,
                                height: 80,
                                color: surfaceHover,
                                child: Icon(
                                  Icons.playlist_play,
                                  size: 32,
                                  color: primaryColor,
                                ),
                              )
                        : item.thumbnail != null
                            ? Image.network(
                                item.thumbnail!,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  // Fallback to AlbumCover if thumbnail fails
                                  return AlbumCover(
                                    filename: item.filename,
                                    title: item.title,
                                    artist: item.artist,
                                    size: 80,
                                  );
                                },
                              )
                            : AlbumCover(
                                filename: item.filename,
                                title: item.title,
                                artist: item.artist,
                                size: 80,
                              ),
                  ),
                  const SizedBox(width: 16),
                  // Title and artist on the right
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            if (item.type == RecentlyPlayedType.playlist)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.playlist_play,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                item.title,
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (item.artist != null && item.artist!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            item.artist!,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleRecentlyPlayedTap(RecentlyPlayedItem item) async {
    if (item.type == RecentlyPlayedType.playlist) {
      if (item.playlistId != null) {
        bool isLocal = false;
        try {
          // Check if it exists in local playlists
          final localPlaylists = await _playlistService.getAllPlaylists();
          isLocal = localPlaylists.any((p) => p.id == item.playlistId);
        } catch (_) {}

        if (isLocal) {
          // Switch to playlists tab and show the playlist directly
          setState(() {
            _navigateToPlaylistId = item.playlistId;
            _currentIndex = 2; // Switch to Playlists tab
          });
        } else {
          // Navigate to SpotifyPlaylistScreen
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SpotifyPlaylistScreen(
                playlistId: item.playlistId!,
                playlistName: item.title,
                coverUrl: item.thumbnail,
                playerStateService: _playerStateService,
                queueService: _queueService,
                recentlyPlayedService: _recentlyPlayedService,
              ),
            ),
          );
        }
      }
    } else {
      // Play the song
      // First, try to stream if URL is available (even if filename exists, URL takes priority for non-downloaded songs)
      if (item.url != null && item.url!.isNotEmpty) {
        try {
          final result = await _apiService.getStreamingUrl(
            url: item.url!,
            title: item.title,
            artist: item.artist ?? '',
          );

          await _playerStateService.streamTrack(
            result.streamingUrl,
            trackName: result.title,
            trackArtist: result.artist,
            url: item.url,
          );
          // Update recently played
          await _recentlyPlayedService.addSong(
            id: item.id,
            title: item.title,
            artist: item.artist,
            thumbnail: item.thumbnail,
            filename: item.filename,
            url: item.url,
          );
        } catch (e) {
          // Streaming failed, try playing from file if filename exists
          if (item.filename != null && item.filename!.isNotEmpty) {
            try {
              await _playerStateService.playTrack(
                item.filename!,
                trackName: item.title,
                trackArtist: item.artist,
                url: item.url,
              );
              // Update recently played
              await _recentlyPlayedService.addSong(
                id: item.id,
                title: item.title,
                artist: item.artist,
                thumbnail: item.thumbnail,
                filename: item.filename,
                url: item.url,
              );
            } catch (fileError) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to stream and play file: $fileError'),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          } else {
            // No filename, streaming failed
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to stream: $e'),
                  backgroundColor: Colors.red,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        }
      } else if (item.filename != null && item.filename!.isNotEmpty) {
        // No URL, but filename exists - try to play from file
        try {
          await _playerStateService.playTrack(
            item.filename!,
            trackName: item.title,
            trackArtist: item.artist,
            url: item.url,
          );
          // Update recently played
          await _recentlyPlayedService.addSong(
            id: item.id,
            title: item.title,
            artist: item.artist,
            thumbnail: item.thumbnail,
            filename: item.filename,
            url: item.url,
          );
        } catch (e) {
          // File doesn't exist, try to find URL in playlists
          String? foundUrl = await _findUrlInPlaylists(item.title, item.artist);
          if (foundUrl != null && foundUrl.isNotEmpty) {
            try {
              final result = await _apiService.getStreamingUrl(
                url: foundUrl,
                title: item.title,
                artist: item.artist ?? '',
              );

              await _playerStateService.streamTrack(
                result.streamingUrl,
                trackName: result.title,
                trackArtist: result.artist,
                url: foundUrl,
              );
              // Update recently played with found URL
              await _recentlyPlayedService.addSong(
                id: item.id,
                title: item.title,
                artist: item.artist,
                thumbnail: item.thumbnail,
                filename: item.filename,
                url: foundUrl,
              );
            } catch (streamError) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to play file and stream: $streamError'),
                    backgroundColor: Colors.red,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          } else {
            // No URL found, show error
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to play file: $e'),
                  backgroundColor: Colors.red,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        }
      } else {
        // No filename or URL available, try to find URL in playlists
        String? foundUrl = await _findUrlInPlaylists(item.title, item.artist);
        if (foundUrl != null && foundUrl.isNotEmpty) {
          try {
            final result = await _apiService.getStreamingUrl(
              url: foundUrl,
              title: item.title,
              artist: item.artist ?? '',
            );

            await _playerStateService.streamTrack(
              result.streamingUrl,
              trackName: result.title,
              trackArtist: result.artist,
              url: foundUrl,
            );
            // Update recently played with found URL
            await _recentlyPlayedService.addSong(
              id: item.id,
              title: item.title,
              artist: item.artist,
              thumbnail: item.thumbnail,
              filename: item.filename,
              url: foundUrl,
            );
          } catch (streamError) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to stream: $streamError'),
                  backgroundColor: Colors.red,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        } else {
          // No filename or URL available
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot play: ${item.title} (not downloaded and no URL available)'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      }
    }
  }

  Future<String?> _findUrlInPlaylists(String title, String? artist) async {
    try {
      final playlists = await _playlistService.getAllPlaylists();
      final titleLower = title.toLowerCase().trim();
      final artistLower = artist?.toLowerCase().trim() ?? '';
      
      for (final playlist in playlists) {
        for (final track in playlist.tracks) {
          final trackTitleLower = track.title.toLowerCase().trim();
          final trackArtistLower = track.artist?.toLowerCase().trim() ?? '';
          
          // Match by title (case insensitive, allow partial matches)
          bool titleMatches = trackTitleLower == titleLower || 
                              trackTitleLower.contains(titleLower) ||
                              titleLower.contains(trackTitleLower);
          
          if (titleMatches) {
            // If artist is provided, try to match it too (but don't require exact match)
            bool artistMatches = artistLower.isEmpty || 
                                 trackArtistLower.isEmpty ||
                                 trackArtistLower == artistLower ||
                                 trackArtistLower.contains(artistLower) ||
                                 artistLower.contains(trackArtistLower);
            
            // If we have a URL, return it (prefer exact matches but accept partial)
            if (track.url != null && track.url!.isNotEmpty) {
              // Prefer exact matches
              if (trackTitleLower == titleLower && 
                  (artistLower.isEmpty || trackArtistLower == artistLower)) {
                return track.url;
              }
            }
          }
        }
      }
      
      // Second pass: if no exact match, return first partial match
      for (final playlist in playlists) {
        for (final track in playlist.tracks) {
          final trackTitleLower = track.title.toLowerCase().trim();
          final trackArtistLower = track.artist?.toLowerCase().trim() ?? '';
          
          bool titleMatches = trackTitleLower == titleLower || 
                              trackTitleLower.contains(titleLower) ||
                              titleLower.contains(trackTitleLower);
          
          if (titleMatches && track.url != null && track.url!.isNotEmpty) {
            return track.url;
          }
        }
      }
    } catch (e) {
      print('Error searching playlists for URL: $e');
    }
    return null;
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final results = await _apiService.searchYoutube(query);
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (e) {
      setState(() {
        _isSearching = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    }
  }

  Future<void> _streamVideo(VideoInfo video) async {
    try {
      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: video.title,
        artist: video.uploader,
      );

      await _playerStateService.streamTrack(
        result.streamingUrl,
        trackName: result.title,
        trackArtist: result.artist,
        url: video.url,
      );
      // Tracking is now done in PlayerStateService when song starts
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Stream failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _downloadVideo(VideoInfo video) async {
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      final result = await _apiService.downloadAudio(
        url: video.url,
        title: video.title,
        artist: video.uploader,
        outputFormat: 'm4a',
        embedThumbnail: true,
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded: ${result.filename}'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showAddToPlaylistDialog(VideoInfo video) async {
    final track = PlaylistTrack.fromVideoInfo(video);
    
    await showDialog(
      context: context,
      builder: (context) => PlaylistSelectionDialog(
        playlistService: _playlistService,
        track: track,
      ),
    );
  }

  Future<void> _addToQueue(VideoInfo video) async {
    try {
      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: video.title,
        artist: video.uploader,
      );

      final queueItem = QueueItem.fromVideoInfo(
        videoId: video.id,
        title: result.title,
        artist: result.artist,
        streamingUrl: result.streamingUrl,
        thumbnail: video.thumbnail,
      );

      _queueService.addToQueue(queueItem);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to queue: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home),
                  label: const Text('Home'),
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
                  child: _buildCurrentScreen(),
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
    _searchController.dispose();
    _recentlyPlayedService.removeListener(_onRecentlyPlayedChanged);
    _playerStateService.dispose();
    _queueService.dispose();
    super.dispose();
  }
}


