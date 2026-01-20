import 'package:flutter/material.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import '../widgets/playlist_selection_dialog.dart';

class GenreScreen extends StatefulWidget {
  final String genre;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final bool embedded; // If true, don't show Scaffold/AppBar
  final VoidCallback? onBack; // Callback for back button when embedded
  final Function(String)? onDownloadStart; // Callback to start download progress tracking

  const GenreScreen({
    super.key,
    required this.genre,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
    this.embedded = false,
    this.onBack,
    this.onDownloadStart,
  });

  @override
  State<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends State<GenreScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  List<PlaylistTrack> _tracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      // Use the new genre recommendations (actual tracks, not playlists!)
      final tracks = await _recommendationService.getGenreTracks(widget.genre);
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading ${widget.genre} tracks: $e')),
        );
      }
    }
  }

  Future<void> _playTrack(PlaylistTrack track) async {
    try {
      // Search YouTube for this track
      final searchResults = await _apiService.searchYoutube(
        '${track.title} ${track.artist ?? ""}',
        durationMin: 0,
        durationMax: 600,
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find "${track.title}" on YouTube')),
          );
        }
        return;
      }

      // Get streaming URL for the first result
      final result = await _apiService.getStreamingUrl(
        url: searchResults.first.url,
        title: track.title,
        artist: track.artist ?? '',
      );

      await widget.playerStateService.streamTrack(
        result.streamingUrl,
        trackName: result.title,
        trackArtist: result.artist,
        url: searchResults.first.url,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play: $e')),
        );
      }
    }
  }

  Future<void> _addToQueue(PlaylistTrack track) async {
    try {
      final searchResults = await _apiService.searchYoutube(
        '${track.title} ${track.artist ?? ""}',
        durationMin: 0,
        durationMax: 600,
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find "${track.title}" on YouTube')),
          );
        }
        return;
      }

      final result = await _apiService.getStreamingUrl(
        url: searchResults.first.url,
        title: track.title,
        artist: track.artist ?? '',
      );

      final queueItem = QueueItem(
        id: searchResults.first.id,
        title: result.title,
        artist: result.artist,
        streamingUrl: result.streamingUrl,
        thumbnail: track.thumbnail,
      );

      widget.queueService.addToQueue(queueItem);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${track.title}" to queue')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add to queue: $e')),
        );
      }
    }
  }

  Future<void> _showAddToPlaylistDialog(PlaylistTrack track) async {
    await showDialog(
      context: context,
      builder: (context) => PlaylistSelectionDialog(
        playlistService: _playlistService,
        track: track,
      ),
    );
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;

    // Play first track
    await _playTrack(_tracks.first);

    // Add rest to queue
    for (int i = 1; i < _tracks.length && i < 20; i++) {
      await _addToQueue(_tracks[i]);
    }
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_off,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No tracks found for ${widget.genre}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadTracks,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTracks,
      child: Column(
        children: [
          // Play All button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _playAll,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play All'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_tracks.length} tracks',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          // Track list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              itemCount: _tracks.length,
              itemBuilder: (context, index) {
                final track = _tracks[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: track.thumbnail != null
                          ? Image.network(
                              track.thumbnail!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 48,
                                height: 48,
                                color: Theme.of(context).colorScheme.surfaceVariant,
                                child: const Icon(Icons.music_note),
                              ),
                            )
                          : Container(
                              width: 48,
                              height: 48,
                              color: Theme.of(context).colorScheme.surfaceVariant,
                              child: const Icon(Icons.music_note),
                            ),
                    ),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.artist ?? 'Unknown Artist',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.playlist_add),
                          tooltip: 'Add to playlist',
                          onPressed: () => _showAddToPlaylistDialog(track),
                        ),
                        IconButton(
                          icon: const Icon(Icons.queue_music),
                          tooltip: 'Add to queue',
                          onPressed: () => _addToQueue(track),
                        ),
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play',
                          onPressed: () => _playTrack(track),
                        ),
                      ],
                    ),
                    onTap: () => _playTrack(track),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with back button
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.genre} Music',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadTracks,
                  tooltip: 'Refresh recommendations',
                ),
              ],
            ),
          ),
          Expanded(child: _buildContent()),
        ],
      );
    }
    
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.genre} Music'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTracks,
            tooltip: 'Refresh recommendations',
          ),
        ],
      ),
      body: _buildContent(),
    );
  }
}

