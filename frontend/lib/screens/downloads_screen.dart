import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';

class DownloadsScreen extends StatefulWidget {
  final PlayerStateService playerStateService;
  final QueueService? queueService;
  
  const DownloadsScreen({super.key, required this.playerStateService, this.queueService});

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
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted: ${file.filename}'),
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added to queue: ${getDisplayTitle(file.title, file.filename)}'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
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
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'My Library',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.library_music_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No downloads yet',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Search and download music to see it here',
                              style: Theme.of(context).textTheme.bodySmall,
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
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            itemCount: filteredDownloads.length,
                            separatorBuilder: (context, index) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final file = filteredDownloads[index];
                              final isCurrentlyPlaying = widget.playerStateService.currentTrackUrl?.contains(file.filename) ?? false;
                    
                              return Material(
                                color: isCurrentlyPlaying 
                                    ? primaryColor.withOpacity(0.1) 
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  onTap: () => _playFile(file),
                                  borderRadius: BorderRadius.circular(8),
                                  hoverColor: surfaceHover,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 48,
                                          height: 48,
                                          decoration: BoxDecoration(
                                            color: isCurrentlyPlaying 
                                                ? primaryColor.withOpacity(0.2)
                                                : surfaceHover,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Icon(
                                            Icons.music_note,
                                            color: isCurrentlyPlaying ? primaryColor : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                            size: 24,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                getDisplayTitle(file.title, file.filename),
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


