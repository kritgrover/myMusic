import 'package:flutter/material.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import 'playlist_detail_screen.dart';

class PlaylistsScreen extends StatefulWidget {
  final PlayerStateService? playerStateService;
  final QueueService? queueService;

  const PlaylistsScreen({super.key, this.playerStateService, this.queueService});

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
        onBack: _hidePlaylistDetail,
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
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Playlists',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _createPlaylist,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New Playlist'),
                  ),
                ],
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
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.playlist_add_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No playlists yet',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Create a playlist to organize your music',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _createPlaylist,
                            icon: const Icon(Icons.add),
                            label: const Text('Create Your First Playlist'),
                          ),
                        ],
                      ),
                    )
                  : !hasFilteredResults
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
                          onRefresh: _loadPlaylists,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            itemCount: filteredPlaylists.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final playlist = filteredPlaylists[index];
                              return Card(
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      _showPlaylistDetail(playlist);
                                    },
                                    borderRadius: BorderRadius.circular(12),
                                    hoverColor: surfaceHover,
                                    child: Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 64,
                                            height: 64,
                                            decoration: BoxDecoration(
                                              color: primaryColor.withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Icon(
                                              Icons.playlist_play,
                                              size: 32,
                                              color: primaryColor,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  playlist.name,
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
                                                      '${playlist.tracks.length} ${playlist.tracks.length == 1 ? 'track' : 'tracks'}',
                                                      style: Theme.of(context).textTheme.bodySmall,
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete_outline, size: 20),
                                            onPressed: () => _deletePlaylist(playlist),
                                            tooltip: 'Delete playlist',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}
