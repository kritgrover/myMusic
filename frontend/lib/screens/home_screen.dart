import 'package:flutter/material.dart';
import 'dart:async';
import '../utils/responsive_utils.dart';
import 'downloads_screen.dart';
import 'playlists_screen.dart';
import 'csv_upload_screen.dart';
import '../widgets/bottom_player.dart';
import '../widgets/queue_panel.dart';
import 'lyrics_screen.dart';
import '../widgets/csv_progress_bar.dart';
import '../widgets/download_progress_bar.dart';
import '../widgets/not_found_songs_dialog.dart';
import '../widgets/video_card.dart';
import '../widgets/album_cover.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/lyrics_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../services/recently_played_service.dart';
import '../models/queue_item.dart';
import '../models/playlist.dart';
import '../services/recommendation_service.dart';
import '../services/auth_service.dart';
import '../models/discovery.dart';
import '../widgets/horizontal_song_list.dart';
import '../widgets/horizontal_card_row.dart';
import '../widgets/browse_category_card.dart';
import '../widgets/section_header.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_bar.dart';
import '../widgets/playlist_card.dart';
import '../widgets/artist_card.dart';
import 'genre_screen.dart';
import 'spotify_playlist_screen.dart';
import 'made_for_you_screen.dart';
import 'new_releases_screen.dart';
import 'album_detail_screen.dart';
import 'artist_screen.dart';
import 'mood_playlists_screen.dart';
import 'profile_screen.dart';
import 'friends_screen.dart';

/// Fires a callback whenever a route is pushed onto the content navigator, used
/// to dismiss the lyrics overlay so it doesn't hide freshly-opened screens.
class _NavPushObserver extends NavigatorObserver {
  final VoidCallback onPush;
  _NavPushObserver(this.onPush);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    onPush();
  }
}

class HomeScreen extends StatefulWidget {
  final AuthService authService;

  const HomeScreen({super.key, required this.authService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  // Nested navigator for the center content pane, so secondary screens (genre,
  // artist, album, playlist, mood, friends, profile) open in-pane while the
  // sidebar, top bar, and player stay put.
  final GlobalKey<NavigatorState> _contentNavigatorKey = GlobalKey<NavigatorState>();
  // Close the lyrics overlay whenever a screen is pushed into the content pane,
  // so it doesn't stay layered on top of (and hide) the new screen.
  late final _NavPushObserver _contentNavObserver = _NavPushObserver(_onContentPushed);

  void _onContentPushed() {
    if (_showLyrics && mounted) setState(() => _showLyrics = false);
  }
  late final RecentlyPlayedService _recentlyPlayedService;
  late final PlayerStateService _playerStateService;
  final QueueService _queueService = QueueService();
  final LyricsService _lyricsService = LyricsService();
  bool _showQueuePanel = false;
  bool _showLyrics = false;
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
  List<Map<String, dynamic>> _newReleases = [];
  bool _isLoadingRecommendations = false;
  final List<String> _genres = [
    'Pop', 'Rock', 'Hip Hop', 'Electronic', 'Jazz', 'Classical',
    'Indie', 'Metal', 'R&B', 'Country', 'K-Pop', 'Latin',
    'Reggae', 'Blues', 'Soul', 'Folk', 'Punk', 'Dance',
  ];

  // Spotify-style home shelves (load independently and render progressively)
  List<HomeMix> _mixes = [];
  List<BecauseRow> _becauseRows = [];
  List<SpotifyPlaylistInfo> _curated = [];
  List<ArtistInfo> _recommendedArtists = [];
  List<MoodCategory> _moods = [];
  
  // Library hub state
  int _libraryTab = 0; // 0 playlists · 1 downloads
  int _libraryRefreshKey = 0;
  List<Playlist> _sidebarPlaylists = [];

  // Made for You navigation
  bool _showMadeForYou = false;

  // New Releases navigation
  bool _showNewReleases = false;

  // Search state
  final TextEditingController _searchController = TextEditingController();
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _recentlyPlayedService = RecentlyPlayedService(userNamespace: widget.authService.username ?? 'default');
    _playerStateService = PlayerStateService(
      recentlyPlayedService: _recentlyPlayedService,
      recommendationService: _recommendationService,
    );

    // Listen for track changes to update lyrics panel
    _playerStateService.addListener(_onTrackChanged);

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
    _fetchDiscoveryShelves();
    _loadSidebarPlaylists();
  }

  Future<void> _loadSidebarPlaylists() async {
    final playlists = await _playlistService.getAllPlaylists();
    if (mounted) setState(() => _sidebarPlaylists = playlists);
  }

  VideoInfo _trackToVideo(PlaylistTrack t) => VideoInfo(
        id: t.url ?? '',
        title: t.title,
        uploader: t.artist ?? 'Unknown',
        duration: t.duration ?? 0,
        url: t.url ?? '',
        thumbnail: t.thumbnail ?? '',
      );

  Future<void> _fetchRecommendations() async {
    setState(() {
      _isLoadingRecommendations = true;
    });

    try {
      final results = await Future.wait([
        _recommendationService.getDailyMix(),
        _recommendationService.getNewReleases(),
      ]);

      if (mounted) {
        final dailyMixTracks = results[0] as List<PlaylistTrack>;
        final newReleases = results[1] as List<Map<String, dynamic>>;
        setState(() {
          _dailyMix = dailyMixTracks.map(_trackToVideo).toList();
          _newReleases = newReleases;
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

  /// Fetch the richer discovery shelves independently so each renders as soon as
  /// it resolves and self-hides when empty (no single slow shelf blocks the page).
  void _fetchDiscoveryShelves() {
    _recommendationService.getMixes().then((v) {
      if (mounted) setState(() => _mixes = v);
    });
    _recommendationService.getBecauseYouListened().then((v) {
      if (mounted) setState(() => _becauseRows = v);
    });
    _recommendationService.getCuratedPlaylists().then((v) {
      if (mounted) setState(() => _curated = v);
    });
    _recommendationService.getRecommendedArtists().then((v) {
      if (mounted) setState(() => _recommendedArtists = v);
    });
    _recommendationService.getMoods().then((v) {
      if (mounted) setState(() => _moods = v);
    });
  }

  Future<void> _refreshHome() async {
    _fetchDiscoveryShelves();
    await _fetchRecommendations();
  }

  // Navigation helpers for the new shelves

  void _openAlbumDetail(Map<String, dynamic> release) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => AlbumDetailScreen(
        albumId: release['id'] as String? ?? '',
        albumName: release['name'] as String? ?? '',
        artist: release['artist'] as String?,
        coverUrl: release['thumbnail'] as String?,
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      ),
    ));
  }

  void _openArtist(ArtistInfo artist) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => ArtistScreen(
        artistId: artist.id,
        artistName: artist.name,
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      ),
    ));
  }

  void _openSpotifyPlaylist(SpotifyPlaylistInfo playlist) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => SpotifyPlaylistScreen(
        playlistId: playlist.id,
        playlistName: playlist.name,
        coverUrl: playlist.thumbnail,
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      ),
    ));
  }

  void _openFriends() {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => FriendsScreen(
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      ),
    ));
  }

  void _openMood(MoodCategory mood) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => MoodPlaylistsScreen(
        mood: mood.mood,
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      ),
    ));
  }

  void _openMixShowAll(HomeMix mix) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      // MadeForYouScreen renders a bare Column, so give it an opaque background
      // to fully cover the destinations beneath in the content pane.
      builder: (context) => Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: MadeForYouScreen(
          title: mix.title,
          songs: mix.tracks.map(_trackToVideo).toList(),
          playerStateService: _playerStateService,
          queueService: _queueService,
          recentlyPlayedService: _recentlyPlayedService,
        ),
      ),
    ));
  }

  void _onRecentlyPlayedChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _openGenre(String genre) {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => GenreScreen(
        genre: genre,
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
        onDownloadStart: (downloadId) {
          setState(() {
            _downloadId = downloadId;
            _downloadProgress = null;
          });
          _startDownloadProgressPolling(downloadId);
        },
      ),
    ));
  }

  void _openProfile() {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: ProfileScreen(
          authService: widget.authService,
          playerStateService: _playerStateService,
          queueService: _queueService,
          onOpenFriends: _openFriends,
        ),
      ),
    ));
  }

  void _openCsvImport() {
    _contentNavigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Import from CSV')),
        body: CsvUploadScreen(
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
              if (conversionResult.notFound.isNotEmpty) {
                _pendingNotFoundSongs = conversionResult.notFound;
                _pendingPlaylistId = conversionResult.playlistId;
              }
            });
            if (conversionResult.notFound.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _pendingNotFoundSongs != null) {
                  final notFound = _pendingNotFoundSongs!;
                  final playlistId = _pendingPlaylistId;
                  _pendingNotFoundSongs = null;
                  _pendingPlaylistId = null;
                  _showNotFoundSongsDialog(notFound, playlistId);
                }
              });
            }
            _loadSidebarPlaylists();
          },
        ),
      ),
    ));
  }

  Future<void> _createPlaylistDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await _playlistService.createPlaylist(name);
      await _loadSidebarPlaylists();
      if (mounted) {
        setState(() {
          _currentIndex = 2;
          _libraryTab = 0;
          _libraryRefreshKey++;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create playlist: $e')));
      }
    }
  }

  void _showCreateOrImportMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('New playlist'),
              onTap: () {
                Navigator.of(context).pop();
                _createPlaylistDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Import from CSV'),
              onTap: () {
                Navigator.of(context).pop();
                _openCsvImport();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openLibraryPlaylist(Playlist playlist) {
    _contentNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _currentIndex = 2;
      _libraryTab = 0;
      _navigateToPlaylistId = playlist.id;
      _showLyrics = false;
      // Force PlaylistsScreen to rebuild so it picks up the initial playlist even
      // if the Library tab is already visible.
      _libraryRefreshKey++;
    });
  }

  void _onSearchTap() {
    _contentNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _currentIndex = 1;
      _showLyrics = false;
    });
  }

  void _onSearchSubmitted(String query) {
    _contentNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _currentIndex = 1;
      _showLyrics = false;
    });
    _performSearch();
  }

  void _onSearchChanged(String value) {
    setState(() {
      if (value.isEmpty) {
        _searchResults = [];
      }
    });
  }

  /// The lyrics overlay, shown above the content stack when toggled from the
  /// player. Kept as an overlay (not in the nested navigator) so it covers
  /// whatever secondary screen is open while the sidebar/player stay visible.
  Widget _buildLyricsOverlay() {
    final currentItem = _queueService.currentItem;
    final duration = _playerStateService.audioPlayer.duration;
    final durationSeconds = duration.inSeconds > 0 ? duration.inSeconds : null;
    // Opaque background so the overlay fully covers the content beneath it
    // (the embedded lyrics screen is otherwise transparent).
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LyricsScreen(
        trackName: _playerStateService.currentTrackName!,
        artistName: _playerStateService.currentTrackArtist ?? '',
        albumName: currentItem?.album,
        duration: durationSeconds,
        lyricsService: _lyricsService,
        playerStateService: _playerStateService,
        embedded: true,
        onBack: () {
          setState(() {
            _showLyrics = false;
          });
        },
      ),
    );
  }

  Widget _buildCurrentScreen() {
    switch (_currentIndex) {
      case 0:
        if (_showNewReleases) {
          return NewReleasesScreen(
            releases: _newReleases,
            onBack: () {
              setState(() {
                _showNewReleases = false;
              });
            },
            onPlayAlbum: _playAlbumFirstTrack,
          );
        }
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
        return _buildHomeFeed();
      case 1:
        return _buildSearchPage();
      case 2:
        return _buildLibrary();
      default:
        return _buildHomeFeed();
    }
  }

  /// The Library hub: filter chips (Playlists / Downloads) + a "+" to create or
  /// import, rendering the existing PlaylistsScreen / DownloadsScreen bodies.
  Widget _buildLibrary() {
    final playlistId = _navigateToPlaylistId;
    if (_navigateToPlaylistId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _navigateToPlaylistId = null;
          });
        }
      });
    }

    Widget body;
    if (_libraryTab == 0) {
      body = PlaylistsScreen(
        key: ValueKey('library_playlists_$_libraryRefreshKey'),
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
    } else {
      body = DownloadsScreen(
        playerStateService: _playerStateService,
        queueService: _queueService,
        recentlyPlayedService: _recentlyPlayedService,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            top: 12,
            bottom: 4,
          ),
          child: Row(
            children: [
              Text(
                'Your Library',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Create playlist or import',
                onPressed: _showCreateOrImportMenu,
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            vertical: 4,
          ),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Playlists'),
                selected: _libraryTab == 0,
                onSelected: (_) => setState(() => _libraryTab = 0),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Downloads'),
                selected: _libraryTab == 1,
                onSelected: (_) => setState(() => _libraryTab = 1),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildGreetingHeader() {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    return Padding(
      padding: EdgeInsets.only(
        left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
        right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
        top: 12,
        bottom: 4,
      ),
      child: Text(
        greeting,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
      ),
    );
  }

  Widget _buildHomeFeed() {
    return RefreshIndicator(
      onRefresh: _refreshHome,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGreetingHeader(),
            // Recently Played
                                ListenableBuilder(
                                  listenable: _recentlyPlayedService,
                                  builder: (context, _) {
                                    if (_recentlyPlayedService.items.isEmpty) return const SizedBox.shrink();
                                    
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: EdgeInsets.only(
                                            left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
                                            right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
                                            top: 16,
                                            bottom: 16,
                                          ),
                                          child: Text(
                                            'Jump back in',
                                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        Padding(
                                          padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              final crossAxisCount = ResponsiveUtils.responsiveValue<int>(
                                                context,
                                                compact: 1,
                                                medium: 2,
                                                expanded: 3,
                                              );
                                              final spacing = ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 14, expanded: 16);
                                              final totalSpacing = spacing * (crossAxisCount - 1);
                                              final cardWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;
                                              final cardHeight = ResponsiveUtils.responsiveCardHeight(context);
                                              final aspectRatio = cardWidth / cardHeight;

                                              return GridView.builder(
                                                shrinkWrap: true,
                                                physics: const NeverScrollableScrollPhysics(),
                                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: crossAxisCount,
                                                  crossAxisSpacing: spacing,
                                                  mainAxisSpacing: spacing,
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

                                // Made for You mixes (one row per top genre)
                                ..._buildMadeForYouShelves(),

                                // Songs for You (daily mix)
                                if (_isLoadingRecommendations)
                                  const Padding(
                                    padding: EdgeInsets.all(32.0),
                                    child: Center(child: CircularProgressIndicator()),
                                  )
                                else
                                  HorizontalSongList(
                                    title: 'Songs for You',
                                    songs: _dailyMix,
                                    onPlay: _streamRecommendedVideo,
                                    onAddToQueue: _addRecommendedToQueue,
                                    onDownload: _downloadRecommendedVideo,
                                    onAddToPlaylist: _addRecommendedToPlaylist,
                                    maxItems: 8,
                                    onShowAll: () {
                                      setState(() {
                                        _showMadeForYou = true;
                                      });
                                    },
                                  ),

                                // Because you listened to {artist}
                                ..._buildBecauseShelves(),

                                // Curated playlists
                                _buildCuratedShelf(),

                                // New Releases
                                if (!_isLoadingRecommendations) _buildNewReleasesSection(),

                                // Recommended artists
                                _buildRecommendedArtistsShelf(),

            SizedBox(height: ResponsiveUtils.responsivePlayerBottomPadding(context)),
          ],
        ),
      ),
    );
  }

  /// The Search destination: live YouTube results when a query is present, else a
  /// clean "Browse all" grid of genre + mood category tiles.
  Widget _buildSearchPage() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchResults.isNotEmpty) {
      return ListView.separated(
        padding: ResponsiveUtils.responsiveHorizontalPadding(context).add(const EdgeInsets.symmetric(vertical: 8)),
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
      );
    }
    if (_searchController.text.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No results found',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
            ),
            const SizedBox(height: 8),
            Text('Try a different search term', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }
    return _buildBrowseAll();
  }

  Widget _buildBrowseAll() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(
              left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
              right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
              top: 16,
              bottom: 2,
            ),
            child: Text(
              'Browse all',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
            ),
          ),
          const SectionHeader(title: 'Genres'),
          _browseGrid(
            itemCount: _genres.length,
            itemBuilder: (context, index) => BrowseCategoryCard(
              label: _genres[index],
              onTap: () => _openGenre(_genres[index]),
            ),
          ),
          if (_moods.isNotEmpty) ...[
            const SectionHeader(title: 'Moods'),
            _browseGrid(
              itemCount: _moods.length,
              itemBuilder: (context, index) {
                final mood = _moods[index];
                return BrowseCategoryCard(
                  label: mood.title,
                  imageUrl: mood.thumbnail,
                  onTap: () => _openMood(mood),
                );
              },
            ),
          ],
          SizedBox(height: ResponsiveUtils.responsivePlayerBottomPadding(context)),
        ],
      ),
    );
  }

  /// Chunky, well-spaced category grid used by the Search "Browse all" surface.
  Widget _browseGrid({required int itemCount, required IndexedWidgetBuilder itemBuilder}) {
    return Padding(
      padding: ResponsiveUtils.responsiveHorizontalPadding(context),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: ResponsiveUtils.responsiveValue<int>(context, compact: 2, medium: 3, expanded: 4),
          crossAxisSpacing: ResponsiveUtils.responsiveValue<double>(context, compact: 14, medium: 16, expanded: 18),
          mainAxisSpacing: ResponsiveUtils.responsiveValue<double>(context, compact: 14, medium: 16, expanded: 18),
          childAspectRatio: 1.5,
        ),
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      ),
    );
  }

  // ---- Discovery shelf builders -------------------------------------------

  List<Widget> _buildMadeForYouShelves() {
    return _mixes.where((m) => m.tracks.isNotEmpty).map((mix) {
      return HorizontalSongList(
        title: mix.title,
        songs: mix.tracks.map(_trackToVideo).toList(),
        onPlay: _streamRecommendedVideo,
        onAddToQueue: _addRecommendedToQueue,
        onDownload: _downloadRecommendedVideo,
        onAddToPlaylist: _addRecommendedToPlaylist,
        maxItems: 10,
        onShowAll: () => _openMixShowAll(mix),
      );
    }).toList();
  }

  List<Widget> _buildBecauseShelves() {
    return _becauseRows.where((r) => r.tracks.isNotEmpty).map((row) {
      return HorizontalSongList(
        title: row.title,
        songs: row.tracks.map(_trackToVideo).toList(),
        onPlay: _streamRecommendedVideo,
        onAddToQueue: _addRecommendedToQueue,
        onDownload: _downloadRecommendedVideo,
        onAddToPlaylist: _addRecommendedToPlaylist,
        maxItems: 10,
      );
    }).toList();
  }

  Widget _buildCuratedShelf() {
    if (_curated.isEmpty) return const SizedBox.shrink();
    return HorizontalCardRow(
      title: 'Curated playlists',
      itemCount: _curated.length,
      itemWidth: ResponsiveUtils.responsiveHorizontalCardWidth(context),
      labelHeight: 52,
      itemBuilder: (context, index) => PlaylistCard(
        playlist: _curated[index],
        onTap: () => _openSpotifyPlaylist(_curated[index]),
      ),
    );
  }

  Widget _buildRecommendedArtistsShelf() {
    if (_recommendedArtists.isEmpty) return const SizedBox.shrink();
    return HorizontalCardRow(
      title: 'Recommended artists',
      itemCount: _recommendedArtists.length,
      itemWidth: ResponsiveUtils.responsiveHorizontalCardWidth(context),
      labelHeight: 32,
      itemBuilder: (context, index) => ArtistCard(
        artist: _recommendedArtists[index],
        onTap: () => _openArtist(_recommendedArtists[index]),
      ),
    );
  }

  Widget _buildNewReleasesSection() {
    if (_newReleases.isEmpty) return const SizedBox.shrink();

    const maxItems = 8;
    final displayed = _newReleases.length > maxItems
        ? _newReleases.sublist(0, maxItems)
        : _newReleases;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            top: 16,
            bottom: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'New Releases',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_newReleases.length > maxItems)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _showNewReleases = true;
                    });
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'See All',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_forward,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: ResponsiveUtils.responsiveHorizontalListHeight(context),
          child: ListView.separated(
            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
            scrollDirection: Axis.horizontal,
            itemCount: displayed.length,
            separatorBuilder: (context, index) => SizedBox(
              width: ResponsiveUtils.responsiveValue<double>(context, compact: 16, medium: 20, expanded: 24),
            ),
            itemBuilder: (context, index) {
              final release = displayed[index];
              final cardWidth = ResponsiveUtils.responsiveHorizontalCardWidth(context);
              final name = release['name'] as String? ?? '';
              final artist = release['artist'] as String? ?? '';
              final type = release['type'] as String? ?? 'album';
              final releaseDate = release['release_date'] as String? ?? '';
              final thumbnail = release['thumbnail'] as String?;

              return SizedBox(
                width: cardWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: thumbnail != null && thumbnail.isNotEmpty
                              ? Image.network(
                                  thumbnail,
                                  width: cardWidth,
                                  height: cardWidth,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return _buildAlbumPlaceholder(cardWidth);
                                  },
                                )
                              : _buildAlbumPlaceholder(cardWidth),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _openAlbumDetail(release),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.4),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.album,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (releaseDate.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            type == 'single' ? 'Single' : 'Album',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          Text(
                            ' • $releaseDate',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.album,
        size: 48,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Future<void> _playAlbumFirstTrack(String albumId, String albumName, String artist) async {
    try {
      final tracks = await _recommendationService.getAlbumTracks(albumId);
      final tracksWithUrl = tracks.where((t) => t.url != null && t.url!.isNotEmpty).toList();
      if (tracksWithUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No tracks found for "$albumName"'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      final queueItems = tracksWithUrl.map((track) => QueueItem.fromPlaylistTrackLazy(
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        originalUrl: track.url!,
        album: track.album,
        thumbnail: track.thumbnail,
      )).toList();

      _queueService.clearQueue();
      _queueService.addAllToQueue(
        queueItems,
        isPlaylistQueue: true,
        loadStreamingUrl: _loadStreamingUrlForAlbumItem,
      );
      await _queueService.playItem(
        0,
        _playerStateService,
        loadStreamingUrl: _loadStreamingUrlForAlbumItem,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not play album: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<String?> _loadStreamingUrlForAlbumItem(QueueItem item) async {
    final originalUrl = item.originalUrl;
    if (originalUrl == null) return null;

    try {
      String youtubeUrl = originalUrl;

      if (!youtubeUrl.contains('youtube.com') && !youtubeUrl.contains('youtu.be')) {
        final query = '${item.title} ${item.artist}';
        final results = await _apiService.searchYoutube(query);
        if (results.isEmpty) return null;
        final foundUrl = results.first.url;
        if (foundUrl == null || foundUrl.isEmpty) return null;
        youtubeUrl = foundUrl;
      }

      final result = await _apiService.getStreamingUrl(
        url: youtubeUrl,
        title: item.title ?? '',
        artist: item.artist ?? '',
      );
      return result.streamingUrl;
    } catch (e) {
      return null;
    }
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
            height: ResponsiveUtils.responsiveCardHeight(context),
            child: Padding(
              padding: ResponsiveUtils.responsivePadding(context),
              child: Row(
                children: [
                  // Thumbnail/Album Cover on the left
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: item.type == RecentlyPlayedType.playlist
                        ? item.thumbnail != null && item.thumbnail!.isNotEmpty
                            ? Image.network(
                                item.thumbnail!,
                                width: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                                height: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  final size = ResponsiveUtils.responsiveMediumIconSize(context, base: 80);
                                  return Container(
                                    width: size,
                                    height: size,
                                    color: surfaceHover,
                                    child: Icon(
                                      Icons.playlist_play,
                                      size: 32,
                                      color: primaryColor,
                                    ),
                                  );
                                },
                              )
                            : Builder(
                                builder: (context) {
                                  final size = ResponsiveUtils.responsiveMediumIconSize(context, base: 80);
                                  return Container(
                                    width: size,
                                    height: size,
                                    color: surfaceHover,
                                    child: Icon(
                                      Icons.playlist_play,
                                      size: 32,
                                      color: primaryColor,
                                    ),
                                  );
                                },
                              )
                        : item.thumbnail != null
                            ? Image.network(
                                item.thumbnail!,
                                width: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                                height: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return AlbumCover(
                                    filename: item.filename,
                                    title: item.title,
                                    artist: item.artist,
                                    size: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                                  );
                                },
                              )
                            : AlbumCover(
                                filename: item.filename,
                                title: item.title,
                                artist: item.artist,
                                size: ResponsiveUtils.responsiveMediumIconSize(context, base: 80),
                              ),
                  ),
                  const SizedBox(width: 16),
                  // Title and artist on the right
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
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
                                maxLines: ResponsiveUtils.responsiveValue<int>(context, compact: 1, medium: 2, expanded: 2),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (item.artist != null && item.artist!.isNotEmpty) ...[
                          SizedBox(height: ResponsiveUtils.responsiveValue<double>(context, compact: 2, medium: 6, expanded: 6)),
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
      final cleaned = await _apiService.cleanMetadata(
        title: video.title,
        uploader: video.uploader,
        videoId: video.id,
        videoUrl: video.url,
      );

      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
      );

      // Play through the queue (replacing it) so the now-playing bar reflects
      // this song's metadata + artwork even if a playlist was already playing.
      final queueItem = QueueItem(
        id: 'video_${video.id}',
        title: result.title,
        artist: result.artist,
        url: result.streamingUrl,
        originalUrl: video.url,
        thumbnail: video.thumbnail,
      );
      _queueService.clearQueue();
      await _queueService.addAndPlay(queueItem, _playerStateService);
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

  Future<void> _streamRecommendedVideo(VideoInfo video) async {
    try {
      final searchResults = await _apiService.searchYoutube(
        '${video.title} ${video.uploader}',
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not find "${video.title}" on YouTube'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      final ytVideo = searchResults.first;
      final cleaned = await _apiService.cleanMetadata(
        title: ytVideo.title,
        uploader: ytVideo.uploader,
        videoId: ytVideo.id,
        videoUrl: ytVideo.url,
      );

      final result = await _apiService.getStreamingUrl(
        url: ytVideo.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
      );

      // Add to queue so bottom player add-to-playlist/download work
      final queueItem = QueueItem(
        id: 'video_${ytVideo.id}',
        title: result.title,
        artist: result.artist,
        url: result.streamingUrl,
        originalUrl: ytVideo.url,
        thumbnail: video.thumbnail,
      );
      _queueService.clearQueue();
      await _queueService.addAndPlay(queueItem, _playerStateService);
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

  Future<void> _downloadCurrentTrack() async {
    final currentItem = _queueService.currentItem;
    if (currentItem == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No track to download'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      String youtubeUrl = currentItem.originalUrl ?? currentItem.url ?? '';
      if (youtubeUrl.isEmpty ||
          (!youtubeUrl.contains('youtube.com') && !youtubeUrl.contains('youtu.be'))) {
        final searchResults = await _apiService.searchYoutube(
          '${currentItem.title} ${currentItem.artist}',
        );
        if (searchResults.isEmpty) {
          if (mounted) {
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not find "${currentItem.title}" on YouTube'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
        youtubeUrl = searchResults.first.url;
      }

      final cleaned = await _apiService.cleanMetadata(
        title: currentItem.title ?? '',
        uploader: currentItem.artist ?? '',
        videoId: '',
        videoUrl: youtubeUrl,
      );

      final result = await _apiService.downloadAudio(
        url: youtubeUrl,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
        album: cleaned['album'] ?? '',
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

  Future<void> _addCurrentTrackToPlaylist() async {
    final currentItem = _queueService.currentItem;
    if (currentItem == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No track to add to playlist'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      String? urlToStore = currentItem.originalUrl ?? currentItem.url;
      if (urlToStore != null &&
          urlToStore.isNotEmpty &&
          !urlToStore.contains('youtube.com') &&
          !urlToStore.contains('youtu.be')) {
        final youtubeUrl = await _apiService.resolveToYouTubeUrl(
          urlToStore,
          currentItem.title ?? '',
          currentItem.artist,
        );
        urlToStore = youtubeUrl;
      }
      if (urlToStore == null || urlToStore.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not find "${currentItem.title}" on YouTube'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      final track = PlaylistTrack(
        id: currentItem.id,
        title: currentItem.title ?? 'Unknown',
        artist: currentItem.artist,
        album: currentItem.album,
        filename: currentItem.filename ?? '',
        url: urlToStore,
        thumbnail: currentItem.thumbnail,
        duration: null,
      );

      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => PlaylistSelectionDialog(
          playlistService: _playlistService,
          track: track,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to playlist: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<VideoInfo?> _resolveToYouTubeVideo(VideoInfo video) async {
    if (video.url.isNotEmpty &&
        (video.url.contains('youtube.com') || video.url.contains('youtu.be'))) {
      return video;
    }
    try {
      final youtubeUrl = await _apiService.resolveToYouTubeUrl(
        video.url.isNotEmpty ? video.url : null,
        video.title,
        video.uploader,
      );
      if (youtubeUrl == null || youtubeUrl.isEmpty) return null;
      return VideoInfo(
        id: video.id,
        title: video.title,
        uploader: video.uploader,
        duration: video.duration,
        url: youtubeUrl,
        thumbnail: video.thumbnail,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _downloadRecommendedVideo(VideoInfo video) async {
    final resolved = await _resolveToYouTubeVideo(video);
    if (resolved == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not find "${video.title}" on YouTube'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    await _downloadVideo(resolved);
  }

  Future<void> _addRecommendedToPlaylist(VideoInfo video) async {
    final resolved = await _resolveToYouTubeVideo(video);
    if (resolved == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not find "${video.title}" on YouTube'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    await _showAddToPlaylistDialog(resolved);
  }

  Future<void> _addRecommendedToQueue(VideoInfo video) async {
    try {
      final searchResults = await _apiService.searchYoutube(
        '${video.title} ${video.uploader}',
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not find "${video.title}" on YouTube'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      final ytVideo = searchResults.first;
      final cleaned = await _apiService.cleanMetadata(
        title: ytVideo.title,
        uploader: ytVideo.uploader,
        videoId: ytVideo.id,
        videoUrl: ytVideo.url,
      );

      final result = await _apiService.getStreamingUrl(
        url: ytVideo.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
      );

      final queueItem = QueueItem.fromVideoInfo(
        videoId: ytVideo.id,
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

  Future<void> _downloadVideo(VideoInfo video) async {
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      final cleaned = await _apiService.cleanMetadata(
        title: video.title,
        uploader: video.uploader,
        videoId: video.id,
        videoUrl: video.url,
      );

      final result = await _apiService.downloadAudio(
        url: video.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
        album: cleaned['album'] ?? '',
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
    final cleaned = await _apiService.cleanMetadata(
      title: video.title,
      uploader: video.uploader,
      videoId: video.id,
      videoUrl: video.url,
    );

    final track = PlaylistTrack(
      id: video.id,
      title: cleaned['title'] ?? video.title,
      artist: cleaned['artist'] ?? video.uploader,
      album: cleaned['album'],
      filename: '',
      url: video.url,
      thumbnail: video.thumbnail,
      duration: video.duration,
    );

    if (!mounted) return;

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
      final cleaned = await _apiService.cleanMetadata(
        title: video.title,
        uploader: video.uploader,
        videoId: video.id,
        videoUrl: video.url,
      );

      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
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
    _csvProgressTimer?.cancel();
    _csvProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      try {
        final progress = await _apiService.getCsvProgress(filename);
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

  static const List<NavigationDestination> _navDestinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.search),
      selectedIcon: Icon(Icons.search),
      label: 'Search',
    ),
    NavigationDestination(
      icon: Icon(Icons.library_music_outlined),
      selectedIcon: Icon(Icons.library_music),
      label: 'Library',
    ),
  ];

  void _onNavDestinationSelected(int index) {
    FocusScope.of(context).unfocus();
    // Clear any secondary screen pushed onto the content pane so the selected
    // primary destination is revealed.
    _contentNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {
      _showLyrics = false;
      _currentIndex = index;
    });
  }


  @override
  Widget build(BuildContext context) {
    final compact = ResponsiveUtils.isCompact(context);
    final expandedSidebar = ResponsiveUtils.isExpanded(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  // Persistent sidebar (medium/expanded only)
                  if (!compact)
                    SizedBox(
                      width: expandedSidebar ? 220 : 72,
                      child: AppSidebar(
                        selectedIndex: _currentIndex,
                        onSelect: _onNavDestinationSelected,
                        expanded: expandedSidebar,
                        playlists: _sidebarPlaylists,
                        onOpenPlaylist: _openLibraryPlaylist,
                        onCreate: _showCreateOrImportMenu,
                      ),
                    ),
                  // Top bar + current destination
                  Expanded(
                    child: Column(
                      children: [
                        AppTopBar(
                          searchController: _searchController,
                          onSearchTap: _onSearchTap,
                          onSearchSubmitted: _onSearchSubmitted,
                          onSearchChanged: _onSearchChanged,
                          username: widget.authService.username,
                          onProfile: _openProfile,
                          onFriends: _openFriends,
                          onLogout: () async {
                            await widget.authService.logout();
                          },
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              // Nested navigator for the content pane. Its root page
                              // is the current destination (opaque + interactive, and
                              // rebuilt each frame via the pages API); secondary
                              // screens are pushed on top imperatively via _open*.
                              Positioned.fill(
                                child: Navigator(
                                  key: _contentNavigatorKey,
                                  observers: [_contentNavObserver],
                                  pages: [
                                    MaterialPage(
                                      key: const ValueKey('content-root'),
                                      child: _buildCurrentScreen(),
                                    ),
                                  ],
                                  onPopPage: (route, result) => route.didPop(result),
                                ),
                              ),
                              // Lyrics overlay (above content + pushed screens).
                              if (_showLyrics &&
                                  _playerStateService.currentTrackName != null &&
                                  _playerStateService.currentTrackArtist != null)
                                Positioned.fill(child: _buildLyricsOverlay()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Queue panel (right side, above the player)
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
            ),
            // CSV / download progress bars (full width, above the player)
            if (_csvProgress != null && _csvFilename != null)
              CsvProgressBar(
                processed: _csvProgress!.processed,
                notFound: _csvProgress!.notFound,
                total: _csvProgress!.total,
                status: _csvProgress!.status,
                progress: _csvProgress!.progress,
              ),
            if (_downloadProgress != null && _downloadId != null)
              DownloadProgressBar(
                processed: _downloadProgress!.processed,
                failed: _downloadProgress!.failed,
                total: _downloadProgress!.total,
                status: _downloadProgress!.status,
                progress: _downloadProgress!.progress,
              ),
            // Persistent now-playing bar (full width). Listen to BOTH the player
            // state and the queue so track changes (e.g. Next) refresh the bar's
            // artwork/title even when only the queue's currentItem changed.
            ListenableBuilder(
              listenable: Listenable.merge([_playerStateService, _queueService]),
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
                  onLyricsToggle: () {
                    setState(() {
                      _showLyrics = !_showLyrics;
                      if (_showLyrics && _playerStateService.currentTrackName != null && _playerStateService.currentTrackArtist != null) {
                        final currentItem = _queueService.currentItem;
                        final dur = _playerStateService.audioPlayer.duration;
                        _lyricsService.fetchLyrics(
                          _playerStateService.currentTrackName!,
                          _playerStateService.currentTrackArtist ?? '',
                          albumName: currentItem?.album,
                          duration: dur.inSeconds > 0 ? dur.inSeconds : null,
                        );
                      }
                    });
                  },
                  onDownload: _downloadCurrentTrack,
                  onAddToPlaylist: _addCurrentTrackToPlaylist,
                );
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onNavDestinationSelected,
              destinations: _navDestinations,
              labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            )
          : null,
    );
  }

  void _onTrackChanged() {
    // Rebuild the shell so the open lyrics overlay receives the new track's props
    // and refreshes its lyrics + artwork via didUpdateWidget.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _completionSubscription?.cancel();
    _csvProgressTimer?.cancel();
    _downloadProgressTimer?.cancel();
    _searchController.dispose();
    _recentlyPlayedService.removeListener(_onRecentlyPlayedChanged);
    _playerStateService.removeListener(_onTrackChanged);
    _playerStateService.dispose();
    _queueService.dispose();
    super.dispose();
  }
}


