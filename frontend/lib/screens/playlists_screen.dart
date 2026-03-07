import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../config.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/gradient_section_header.dart';
import 'playlist_detail_screen.dart';

class PlaylistsScreen extends StatefulWidget {
  final PlayerStateService? playerStateService;
  final QueueService? queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final Function(String)? onDownloadStart;
  final String? initialPlaylistId; // Playlist to show when screen loads

  const PlaylistsScreen({
    super.key, 
    this.playerStateService, 
    this.queueService, 
    this.recentlyPlayedService,
    this.onDownloadStart,
    this.initialPlaylistId,
  });

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _searchController = TextEditingController();
  List<Playlist> _playlists = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Playlist? _selectedPlaylist;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
    _searchController.addListener(_onSearchChanged);
    // If an initial playlist ID is provided, load it after playlists are loaded
    if (widget.initialPlaylistId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInitialPlaylist();
      });
    }
  }

  Future<void> _loadInitialPlaylist() async {
    if (widget.initialPlaylistId != null) {
      try {
        final playlist = await _playlistService.getPlaylist(widget.initialPlaylistId!);
        if (playlist != null && mounted) {
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
    setState(() {
      _isLoading = true;
    });

    try {
      final playlists = await _playlistService.getAllPlaylists();
      setState(() {
        _playlists = playlists;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load playlists: $e')),
        );
      }
    }
  }

  Future<void> _createPlaylist() async {
    final nameController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Create New Playlist'),
        content: TextField(
          controller: nameController,
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
              if (nameController.text.trim().isNotEmpty) {
                Navigator.of(context).pop(nameController.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

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
    try {
      final query = _searchQuery;
      if (query.isEmpty || query.trim().isEmpty || query.length == 0) {
        return _playlists;
      }
      if (_playlists.isEmpty || _playlists.length == 0) {
        return _playlists;
      }
      try {
        return _playlists.where((playlist) {
          try {
            final name = playlist.name.toLowerCase();
            return name.contains(query);
          } catch (e) {
            return false;
          }
        }).toList();
      } catch (e) {
        return _playlists;
      }
    } catch (e) {
      return _playlists;
    }
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

    if (confirmed == true) {
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
    if (playlist.coverImage!.startsWith('http://') || playlist.coverImage!.startsWith('https://')) {
      return playlist.coverImage;
    }
    // Local cover image
    return '${AppConfig.apiBaseUrl}${playlist.coverImage}';
  }

  void _showPlaylistDetail(Playlist playlist) {
    setState(() {
      _selectedPlaylist = playlist;
    });
  }

  void _hidePlaylistDetail() {
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
    final hasPlaylists = _playlists.isNotEmpty && _playlists.length > 0;
    final hasFilteredResults = filteredPlaylists.isNotEmpty && filteredPlaylists.length > 0;
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
                  hintText: 'Search playlists...',
                  prefixIcon: const Icon(Icons.search, size: 24),
                  suffixIcon: _searchQuery.isNotEmpty && _searchQuery.trim().isNotEmpty && _searchQuery.length > 0
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _searchController.clear();
                          },
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
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
                            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                            itemCount: filteredPlaylists.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 12),
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
                          final coverSize = ResponsiveUtils.responsiveIconSize(context, base: 64);
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
                                      widget.coverImageUrl!,
                                          width: coverSize,
                                          height: coverSize,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) {
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
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
