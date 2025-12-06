import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/player_state_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

class DownloadsScreen extends StatefulWidget {
  final PlayerStateService playerStateService;
  
  const DownloadsScreen({super.key, required this.playerStateService});

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

  String _formatDisplayName(String filename) {
    // Remove file extension
    String displayName = filename;
    final extensionPattern = RegExp(r'\.(m4a|mp3)$', caseSensitive: false);
    displayName = displayName.replaceAll(extensionPattern, '');

    final parts = displayName.split(' - ');
    if (parts.isNotEmpty) {
      return parts[0].trim();
    }
    
    return displayName;
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
          final displayName = _formatDisplayName(file.filename).toLowerCase();
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
      await widget.playerStateService.playTrack(file.filename, trackName: file.filename);
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
              backgroundColor: neonBlue,
              behavior: SnackBarBehavior.floating,
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

  @override
  Widget build(BuildContext context) {
    final filteredDownloads = _filteredDownloads;
    final hasDownloads = _downloads.isNotEmpty;
    final hasFilteredResults = filteredDownloads.isNotEmpty;
    
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search downloads...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty && _searchQuery.trim().isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
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
                              Icons.download_done,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No downloads yet',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Search and download music to see it here',
                              style: Theme.of(context).textTheme.bodyMedium,
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
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No results found',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Try a different search term',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: filteredDownloads.length,
                            itemBuilder: (context, index) {
                              final file = filteredDownloads[index];
                              final isCurrentlyPlaying = widget.playerStateService.currentTrackUrl?.contains(file.filename) ?? false;
                    
                    return Column(
                      children: [
                        Material(
                          color: isCurrentlyPlaying 
                              ? neonBlue.withOpacity(0.1) 
                              : Colors.transparent,
                          child: InkWell(
                            onTap: () => _playFile(file),
                            hoverColor: neonBlue.withOpacity(0.15),
                            child: ListTile(
                              leading: Icon(
                                Icons.music_note,
                                color: isCurrentlyPlaying ? neonBlue : null,
                              ),
                              title: Text(
                                _formatDisplayName(file.filename),
                                style: TextStyle(
                                  color: isCurrentlyPlaying ? neonBlue : null,
                                ),
                              ),
                              subtitle: Text(file.formattedSize),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      Icons.play_arrow,
                                      color: isCurrentlyPlaying ? neonBlue : null,
                                    ),
                                    onPressed: () => _playFile(file),
                                    tooltip: 'Play',
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _deleteFile(file),
                                    tooltip: 'Delete',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: Colors.grey[800],
                        ),
                      ],
                            );
                          },
                        ),
          ),
        ),
      ],
    );
  }

}


