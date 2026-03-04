import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/api_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';
import '../widgets/album_cover.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/gradient_section_header.dart';

class DownloadsScreen extends StatefulWidget {
  final PlayerStateService playerStateService;
  final QueueService? queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  
  const DownloadsScreen({
    super.key, 
    required this.playerStateService, 
    this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  List<DownloadedFile> _downloads = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadDownloads();
    // Listen to player state changes to update highlighting
    widget.playerStateService.addListener(_onPlayerStateChanged);
    _searchController.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    if (mounted) {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase().trim();
      });
    }
  }

  void _onPlayerStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    widget.playerStateService.removeListener(_onPlayerStateChanged);
    super.dispose();
  }

  Future<void> _loadDownloads() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final downloads = await _apiService.listDownloads();
      setState(() {
        _downloads = downloads;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load downloads: $e')),
        );
      }
    }
  }


  List<DownloadedFile> get _filteredDownloads {
    final query = _searchQuery;
    if (query.isEmpty || query.trim().isEmpty) {
      return _downloads;
    }
    if (_downloads.isEmpty) {
      return _downloads;
    }
    try {
      return _downloads.where((file) {
        try {
          final displayName = getDisplayTitle(file.title, file.filename).toLowerCase();
          final filename = file.filename.toLowerCase();
          return displayName.contains(query) || filename.contains(query);
        } catch (e) {
          return false;
        }
      }).toList();
    } catch (e) {
      return _downloads;
    }
  }

  Future<void> _playFile(DownloadedFile file) async {
    try {
      // Use formatted display name for track name to show proper song name
      final trackName = getDisplayTitle(file.title, file.filename);
      await widget.playerStateService.playTrack(
        file.filename, 
        trackName: trackName,
        trackArtist: file.artist,
      );
      // Tracking is now done in PlayerStateService when song starts
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play: $e')),
        );
      }
    }
  }

  Future<void> _deleteFile(DownloadedFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Song'),
        content: Text('Are you sure you want to delete "${file.filename}"?'),
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
        await _apiService.deleteDownload(file.filename);
        await _loadDownloads();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  Future<void> _addToQueue(DownloadedFile file) async {
    if (widget.queueService == null) return;

    try {
      final queueItem = QueueItem.fromDownloadedFile(
        filename: file.filename,
        title: file.title,
        artist: file.artist,
      );

      widget.queueService!.addToQueue(queueItem);
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

  @override
  Widget build(BuildContext context) {
    final filteredDownloads = _filteredDownloads;
    final hasDownloads = _downloads.isNotEmpty;
    final hasFilteredResults = filteredDownloads.isNotEmpty;
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
                title: 'My Library',
                showGradientBar: true,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search your library...',
                  prefixIcon: const Icon(Icons.search, size: 24),
                  suffixIcon: _searchQuery.isNotEmpty && _searchQuery.trim().isNotEmpty
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
          child: RefreshIndicator(
            onRefresh: _loadDownloads,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : !hasDownloads
                    ? EmptyStateWidget(
                        icon: Icons.library_music_outlined,
                        title: 'No downloads yet',
                        subtitle: 'Search and download music to see it here.',
                      )
                    : !hasFilteredResults
                        ? EmptyStateWidget(
                            icon: Icons.search_off,
                            title: 'No results found',
                            subtitle: 'Try a different search term.',
                          )
                        : ListView.separated(
                            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                            itemCount: filteredDownloads.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final file = filteredDownloads[index];
                              final isCurrentlyPlaying = widget.playerStateService.currentTrackUrl?.contains(file.filename) ?? false;
                              final trackName = getDisplayTitle(file.title, file.filename);

                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => _playFile(file),
                                  borderRadius: BorderRadius.circular(12),
                                  hoverColor: surfaceHover.withOpacity(0.5),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      gradient: isCurrentlyPlaying
                                          ? LinearGradient(
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                              colors: [
                                                primaryColor.withOpacity(0.15),
                                                primaryColor.withOpacity(0.06),
                                              ],
                                            )
                                          : null,
                                      color: isCurrentlyPlaying ? null : Theme.of(context).colorScheme.surface,
                                      border: isCurrentlyPlaying
                                          ? Border(
                                              left: BorderSide(color: primaryColor, width: 3),
                                            )
                                          : Border.all(
                                              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                                              width: 1,
                                            ),
                                    ),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: AlbumCover(
                                            filename: file.filename,
                                            title: file.title,
                                            artist: file.artist,
                                            size: ResponsiveUtils.responsiveIconSize(context, base: 48),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                trackName,
                                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                                  color: isCurrentlyPlaying ? primaryColor : null,
                                                  fontWeight: isCurrentlyPlaying ? FontWeight.w600 : FontWeight.w400,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                file.artist != null && file.artist!.isNotEmpty
                                                    ? file.artist!
                                                    : file.formattedSize,
                                                style: Theme.of(context).textTheme.bodySmall,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (widget.queueService != null)
                                              IconButton(
                                                icon: const Icon(Icons.queue_music, size: 20),
                                                onPressed: () => _addToQueue(file),
                                                tooltip: 'Add to queue',
                                              ),
                                            IconButton(
                                              icon: Icon(
                                                Icons.play_arrow,
                                                color: isCurrentlyPlaying ? primaryColor : null,
                                              ),
                                              onPressed: () => _playFile(file),
                                              tooltip: 'Play',
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline, size: 20),
                                              onPressed: () => _deleteFile(file),
                                              tooltip: 'Delete',
                                            ),
                                          ],
                                        ),
                                      ],
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


