import 'package:flutter/material.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/api_service.dart';
import '../services/queue_service.dart';
import '../models/playlist.dart';
import '../utils/song_display_utils.dart';
import '../widgets/video_card.dart';

class SpotifyPlaylistScreen extends StatefulWidget {
  final String playlistId;
  final String playlistName;
  final String? coverUrl;
  final PlayerStateService playerStateService;
  final QueueService queueService;

  const SpotifyPlaylistScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
    this.coverUrl,
    required this.playerStateService,
    required this.queueService,
  });

  @override
  State<SpotifyPlaylistScreen> createState() => _SpotifyPlaylistScreenState();
}

class _SpotifyPlaylistScreenState extends State<SpotifyPlaylistScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  final ApiService _apiService = ApiService();
  List<PlaylistTrack> _tracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    try {
      final tracks = await _recommendationService.getSpotifyPlaylistTracks(widget.playlistId);
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
          SnackBar(content: Text('Error loading tracks: $e')),
        );
      }
    }
  }

  Future<void> _playTrack(PlaylistTrack track) async {
    try {
      // Show loading indicator or toast?
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Finding stream...'), duration: Duration(seconds: 1)),
      );

      // Search YouTube for the track
      final query = "${track.title} ${track.artist}";
      final results = await _apiService.searchYoutube(query);
      
      if (results.isNotEmpty) {
        final video = results.first;
        
        // Get streaming URL
        final streamResult = await _apiService.getStreamingUrl(
          url: video.url,
          title: track.title,
          artist: track.artist ?? '',
        );

        if (streamResult.success) {
          await widget.playerStateService.streamTrack(
            streamResult.streamingUrl,
            trackName: track.title,
            trackArtist: track.artist,
            url: video.url,
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Song not found on YouTube')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error playing track: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200.0,
            floating: false,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.playlistName),
              background: widget.coverUrl != null
                  ? Image.network(
                      widget.coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: Colors.grey[900]),
                    )
                  : Container(
                      color: Colors.grey[900],
                      child: const Center(child: Icon(Icons.music_note, size: 64)),
                    ),
            ),
          ),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_tracks.isEmpty)
            const SliverFillRemaining(
              child: Center(child: Text('No tracks found')),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final track = _tracks[index];
                  // Use a simplified list tile or reuse VideoCard if we convert to VideoInfo
                  // Let's use ListTile for simplicity and consistency with PlaylistDetail
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: track.thumbnail != null
                          ? Image.network(
                              track.thumbnail!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.music_note),
                            )
                          : const Icon(Icons.music_note),
                    ),
                    title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(track.artist ?? 'Unknown', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _playTrack(track),
                    ),
                    onTap: () => _playTrack(track),
                  );
                },
                childCount: _tracks.length,
              ),
            ),
        ],
      ),
    );
  }
}

