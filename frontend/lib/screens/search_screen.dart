import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/player_state_service.dart';
import '../services/playlist_service.dart';
import '../services/queue_service.dart';
import '../models/queue_item.dart';
import '../widgets/video_card.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../models/playlist.dart';

class SearchScreen extends StatefulWidget {
  final PlayerStateService? playerStateService;
  final QueueService? queueService;
  
  const SearchScreen({super.key, this.playerStateService, this.queueService});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _searchController = TextEditingController();
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
                textInputAction: TextInputAction.search,
              ),
            ],
          ),
        ),
        Expanded(
          child: _isSearching
              ? const Center(child: CircularProgressIndicator())
              : _searchResults.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _searchController.text.isEmpty
                                ? Icons.search
                                : Icons.search_off,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchController.text.isEmpty
                                ? 'Search for your favorite music'
                                : 'No results found',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          if (_searchController.text.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Try a different search term',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.separated(
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
                          onAddToQueue: widget.queueService != null
                              ? () async {
                                  await _addToQueue(_searchResults[index]);
                                }
                              : null,
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Future<void> _streamVideo(VideoInfo video) async {
    if (widget.playerStateService == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Player not available'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      // Get streaming URL from backend - this is fast, no need for loading dialog
      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: video.title,
        artist: video.uploader,
      );

      // Start streaming immediately - just_audio will handle buffering
      await widget.playerStateService!.streamTrack(
        result.streamingUrl,
        trackName: result.title,
        trackArtist: result.artist,
      );
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
        Navigator.of(context).pop(); // Close loading dialog
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
        Navigator.of(context).pop(); // Close loading dialog
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
    // Convert VideoInfo to PlaylistTrack
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
    if (widget.queueService == null) return;

    try {
      // Get streaming URL
      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: video.title,
        artist: video.uploader,
      );

      // Create queue item
      final queueItem = QueueItem.fromVideoInfo(
        videoId: video.id,
        title: result.title,
        artist: result.artist,
        streamingUrl: result.streamingUrl,
        thumbnail: video.thumbnail,
      );

      // Add to queue
      widget.queueService!.addToQueue(queueItem);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added to queue: ${result.title}'),
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
}


