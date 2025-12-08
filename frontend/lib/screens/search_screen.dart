import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/player_state_service.dart';
import '../services/playlist_service.dart';
import '../widgets/video_card.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../models/playlist.dart';

const Color neonBlue = Color(0xFF00D9FF);

class SearchScreen extends StatefulWidget {
  final PlayerStateService? playerStateService;
  
  const SearchScreen({super.key, this.playerStateService});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _searchController = TextEditingController();
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;
  bool _deepSearch = true;

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
      final results = await _apiService.searchYoutube(query, deepSearch: _deepSearch);
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
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search for music...',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _performSearch,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onSubmitted: (_) => _performSearch(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: _deepSearch,
                    onChanged: (value) {
                      setState(() {
                        _deepSearch = value ?? true;
                      });
                    },
                  ),
                  const Text('Deep Search (slower but more accurate)'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _isSearching
              ? const Center(child: CircularProgressIndicator())
              : _searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _searchController.text.isEmpty
                            ? 'Enter a search query to find music'
                            : 'No results found',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
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
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      // Get streaming URL from backend
      final result = await _apiService.getStreamingUrl(
        url: video.url,
        title: video.title,
        artist: video.uploader,
      );

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        
        // Start streaming
        await widget.playerStateService!.streamTrack(
          result.streamingUrl,
          trackName: result.title,
          trackArtist: result.artist,
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
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
            backgroundColor: neonBlue,
            behavior: SnackBarBehavior.floating,
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
}


