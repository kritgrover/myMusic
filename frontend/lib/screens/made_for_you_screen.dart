import 'package:flutter/material.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import '../widgets/playlist_selection_dialog.dart';

class MadeForYouScreen extends StatefulWidget {
  final List<VideoInfo> songs;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final VoidCallback? onBack;

  const MadeForYouScreen({
    super.key,
    required this.songs,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
    this.onBack,
  });

  @override
  State<MadeForYouScreen> createState() => _MadeForYouScreenState();
}

class _MadeForYouScreenState extends State<MadeForYouScreen> {
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();

  Future<void> _playTrack(VideoInfo song) async {
    try {
      final result = await _apiService.getStreamingUrl(
        url: song.url,
        title: song.title,
        artist: song.uploader,
      );

      await widget.playerStateService.streamTrack(
        result.streamingUrl,
        trackName: result.title,
        trackArtist: result.artist,
        url: song.url,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play: $e')),
        );
      }
    }
  }

  Future<void> _addToQueue(VideoInfo song, {bool showSnackbar = true}) async {
    try {
      final result = await _apiService.getStreamingUrl(
        url: song.url,
        title: song.title,
        artist: song.uploader,
      );

      final queueItem = QueueItem(
        id: song.id,
        title: result.title,
        artist: result.artist,
        url: result.streamingUrl,
        thumbnail: song.thumbnail,
      );

      widget.queueService.addToQueue(queueItem);

      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${song.title}" to queue')),
        );
      }
    } catch (e) {
      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add to queue: $e')),
        );
      }
    }
  }

  Future<void> _showAddToPlaylistDialog(VideoInfo song) async {
    final track = PlaylistTrack.fromVideoInfo(song);
    await showDialog(
      context: context,
      builder: (context) => PlaylistSelectionDialog(
        playlistService: _playlistService,
        track: track,
      ),
    );
  }

  Future<void> _playAll() async {
    if (widget.songs.isEmpty) return;

    // Play first track
    await _playTrack(widget.songs.first);

    // Add rest to queue (silently, without snackbar messages)
    for (int i = 1; i < widget.songs.length && i < 20; i++) {
      await _addToQueue(widget.songs[i], showSnackbar: false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                'Songs for You',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        // Content
        if (widget.songs.isEmpty)
          Expanded(
            child: Center(
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
                    'No recommendations available',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
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
                        '${widget.songs.length} tracks',
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
                    itemCount: widget.songs.length,
                    itemBuilder: (context, index) {
                      final song = widget.songs[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4.0),
                        child: ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: song.thumbnail.isNotEmpty
                                ? Image.network(
                                    song.thumbnail,
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
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            song.uploader,
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
                                onPressed: () => _showAddToPlaylistDialog(song),
                              ),
                              IconButton(
                                icon: const Icon(Icons.queue_music),
                                tooltip: 'Add to queue',
                                onPressed: () => _addToQueue(song),
                              ),
                              IconButton(
                                icon: const Icon(Icons.play_arrow),
                                tooltip: 'Play',
                                onPressed: () => _playTrack(song),
                              ),
                            ],
                          ),
                          onTap: () => _playTrack(song),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
