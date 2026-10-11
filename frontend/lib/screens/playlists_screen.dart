import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/playlist_service.dart';
import '../services/auth_http_client.dart';
import '../models/playlist.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../config.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/gradient_section_header.dart';
import 'playlist_detail_screen.dart';

enum _PlaylistSort { recentlyUpdated, alphabetical, trackCount }

class PlaylistsScreen extends StatefulWidget {
  final PlayerStateService? playerStateService;
  final QueueService? queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final Function(String)? onDownloadStart;
  final String? initialPlaylistId; // Playlist to show when screen loads
  final PlaylistService? playlistService;

  const PlaylistsScreen({
    super.key,
    this.playerStateService,
    this.queueService,
    this.recentlyPlayedService,
    this.onDownloadStart,
    this.initialPlaylistId,
    this.playlistService,
  });

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  late final PlaylistService _playlistService;
  final TextEditingController _searchController = TextEditingController();
  List<Playlist> _playlists = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Playlist? _selectedPlaylist;
  _PlaylistSort _sort = _PlaylistSort.recentlyUpdated;
  String? _loadError;
  int _loadRequestId = 0;
  int _detailRequestId = 0;

  @override
  void initState() {
    super.initState();
    _playlistService = widget.playlistService ?? PlaylistService();
    _loadPlaylists();
    _searchController.addListener(_onSearchChanged);
    _loadInitialPlaylist();
  }

  @override
  void didUpdateWidget(covariant PlaylistsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent clears its one-shot navigation request on the next frame.
    // That acknowledgement must not cancel a playlist that is still loading.
    if (widget.initialPlaylistId != null &&
        oldWidget.initialPlaylistId != widget.initialPlaylistId) {
      _loadInitialPlaylist();
    }
  }

  Future<void> _loadInitialPlaylist() async {
    final requestId = ++_detailRequestId;
    final playlistId = widget.initialPlaylistId;
    if (playlistId != null) {
      try {
        final playlist = await _playlistService.getPlaylist(playlistId);
        if (playlist != null && mounted && requestId == _detailRequestId) {
          setState(() {
            _selectedPlaylist = playlist;
          });
        }
      } catch (e) {
        // Ignore errors
      }
    }
  }

  void _onSearchChanged() {
    if (mounted) {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase().trim();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    if (!mounted) return;
    final requestId = ++_loadRequestId;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final playlists = await _playlistService.getAllPlaylists();
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _playlists = playlists;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _loadRequestId) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Could not load your playlists. Please try again.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load playlists: $e')),
        );
      }
    }
  }

  Future<void> _createPlaylist() async {
    var playlistName = '';

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Create New Playlist'),
        content: TextField(
          onChanged: (value) => playlistName = value,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.of(context).pop(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (playlistName.trim().isNotEmpty) {
                Navigator.of(context).pop(playlistName.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (result != null && result.isNotEmpty) {
      try {
        await _playlistService.createPlaylist(result);
        await _loadPlaylists();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Playlist created'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create playlist: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  List<Playlist> get _filteredPlaylists {
    final playlists = _playlists.where((playlist) {
      if (_searchQuery.isEmpty) return true;
      return playlist.name.toLowerCase().contains(_searchQuery) ||
          playlist.tracks.any((track) =>
              track.title.toLowerCase().contains(_searchQuery) ||
              (track.artist ?? '').toLowerCase().contains(_searchQuery));
    }).toList();
    playlists.sort((a, b) {
      final int comparison;
      switch (_sort) {
        case _PlaylistSort.recentlyUpdated:
          comparison = b.updatedAt.compareTo(a.updatedAt);
          break;
        case _PlaylistSort.alphabetical:
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case _PlaylistSort.trackCount:
          comparison = b.tracks.length.compareTo(a.tracks.length);
          break;
      }
      return comparison != 0 ? comparison : a.id.compareTo(b.id);
    });
    return playlists;
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Are you sure you want to delete "${playlist.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await _playlistService.deletePlaylist(playlist.id);
        await _loadPlaylists();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Playlist deleted'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete playlist: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  String? _getCoverImageUrl(Playlist playlist) {
    if (playlist.coverImage == null) return null;
    if (playlist.coverImage!.startsWith('http://') ||
        playlist.coverImage!.startsWith('https://')) {
      return playlist.coverImage;
    }
    // Local cover image
    return '${AppConfig.apiBaseUrl}${playlist.coverImage}';
  }

  void _showPlaylistDetail(Playlist playlist) {
    _detailRequestId++;
    setState(() {
      _selectedPlaylist = playlist;
    });
  }

  void _hidePlaylistDetail() {
    _detailRequestId++;
    setState(() {
      _selectedPlaylist = null;
    });
    // Reload playlists when returning from detail screen
    _loadPlaylists();
  }

  @override
  Widget build(BuildContext context) {
    // If a playlist is selected, show the detail view
    if (_selectedPlaylist != null) {
      return PlaylistDetailScreen(
        key: ValueKey(_selectedPlaylist!.id),
        playlist: _selectedPlaylist!,
        playlistService: _playlistService,
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: widget.recentlyPlayedService,
        onBack: _hidePlaylistDetail,
        onDownloadStart: widget.onDownloadStart,
      );
    }

    // Otherwise show the playlists list
    final filteredPlaylists = _filteredPlaylists;
    final hasPlaylists = _playlists.isNotEmpty;
    final hasFilteredResults = filteredPlaylists.isNotEmpty;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;

    return Column(
      children: [
        Padding(
          padding: ResponsiveUtils.responsivePadding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GradientSectionHeader(
                title: 'Playlists',
                showGradientBar: true,
                trailing: ElevatedButton.icon(
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Playlist'),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search playlists, songs, or artists',
                  prefixIcon: const Icon(Icons.search, size: 24),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          tooltip: 'Clear playlist search',
                          onPressed: () {
                            _searchController.clear();
                          },
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${filteredPlaylists.length} ${filteredPlaylists.length == 1 ? 'playlist' : 'playlists'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  PopupMenuButton<_PlaylistSort>(
                    tooltip: 'Sort playlists',
                    initialValue: _sort,
                    onSelected: (sort) => setState(() => _sort = sort),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: _PlaylistSort.recentlyUpdated,
                          child: Text('Recently updated')),
                      PopupMenuItem(
                          value: _PlaylistSort.alphabetical,
                          child: Text('Alphabetical')),
                      PopupMenuItem(
                          value: _PlaylistSort.trackCount,
                          child: Text('Most tracks')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(switch (_sort) {
                            _PlaylistSort.recentlyUpdated => 'Recently updated',
                            _PlaylistSort.alphabetical => 'Alphabetical',
                            _PlaylistSort.trackCount => 'Most tracks',
                          }),
                          const SizedBox(width: 8),
                          const Icon(Icons.sort, size: 20),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh playlists',
                    onPressed: _isLoading ? null : _loadPlaylists,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_loadError!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _loadPlaylists,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : !hasPlaylists
                      ? EmptyStateWidget(
                          icon: Icons.playlist_add_outlined,
                          title: 'No playlists yet',
                          subtitle: 'Create a playlist to organize your music.',
                          onAction: _createPlaylist,
                          actionLabel: 'Create Your First Playlist',
                        )
                      : !hasFilteredResults
                          ? EmptyStateWidget(
                              icon: Icons.search_off,
                              title: 'No results found',
                              subtitle: 'Try a different search term.',
                            )
                          : RefreshIndicator(
                              onRefresh: _loadPlaylists,
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    ResponsiveUtils.responsiveHorizontalPadding(
                                        context),
                                itemCount: filteredPlaylists.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (context, index) {
                                  final playlist = filteredPlaylists[index];
                                  return _PlaylistCard(
                                    playlist: playlist,
                                    coverImageUrl: _getCoverImageUrl(playlist),
                                    primaryColor: primaryColor,
                                    surfaceHover: surfaceHover,
                                    onTap: () => _showPlaylistDetail(playlist),
                                    onDelete: () => _deletePlaylist(playlist),
                                  );
                                },
                              ),
                            ),
        ),
      ],
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  final Playlist playlist;
  final String? coverImageUrl;
  final Color primaryColor;
  final Color surfaceHover;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PlaylistCard({
    required this.playlist,
    required this.coverImageUrl,
    required this.primaryColor,
    required this.surfaceHover,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.primaryColor.withOpacity(_isHovered ? 0.15 : 0.06),
            width: 1,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.primaryColor.withOpacity(0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(12),
            hoverColor: widget.surfaceHover.withOpacity(0.5),
            child: Padding(
              padding: ResponsiveUtils.responsivePadding(context),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Builder(
                        builder: (context) {
                          final coverSize = ResponsiveUtils.responsiveIconSize(
                              context,
                              base: 64);
                          return Container(
                            width: coverSize,
                            height: coverSize,
                            decoration: BoxDecoration(
                              color: widget.primaryColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: widget.coverImageUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.network(
                                          AuthHttpClient.shared.cacheScopedUrl(widget.coverImageUrl!),
                                          headers: AuthHttpClient.shared
                                              .authHeadersForUrl(
                                                  widget.coverImageUrl!),
                                          width: coverSize,
                                          height: coverSize,
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                            return Icon(
                                              Icons.playlist_play,
                                              size: 32,
                                              color: widget.primaryColor,
                                            );
                                          },
                                        ),
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            height: 20,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.transparent,
                                                  Colors.black.withOpacity(0.3),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : Icon(
                                    Icons.playlist_play,
                                    size: 32,
                                    color: widget.primaryColor,
                                  ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.playlist.name,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.music_note,
                              size: 14,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.5),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${widget.playlist.tracks.length} ${widget.playlist.tracks.length == 1 ? 'track' : 'tracks'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: widget.onDelete,
                    tooltip: 'Delete playlist',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
