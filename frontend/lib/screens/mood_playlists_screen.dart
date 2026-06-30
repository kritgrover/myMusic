import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../models/discovery.dart';
import '../widgets/playlist_card.dart';
import 'spotify_playlist_screen.dart';

/// Grid of playlists for a mood/activity. Tapping a playlist opens the existing
/// SpotifyPlaylistScreen (which handles the tracklist + play/queue/download).
class MoodPlaylistsScreen extends StatefulWidget {
  final String mood;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;

  const MoodPlaylistsScreen({
    super.key,
    required this.mood,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<MoodPlaylistsScreen> createState() => _MoodPlaylistsScreenState();
}

class _MoodPlaylistsScreenState extends State<MoodPlaylistsScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  List<SpotifyPlaylistInfo> _playlists = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final playlists = await _recommendationService.getMoodPlaylists(widget.mood);
      if (mounted) {
        setState(() {
          _playlists = playlists;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openPlaylist(SpotifyPlaylistInfo playlist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SpotifyPlaylistScreen(
        playlistId: playlist.id,
        playlistName: playlist.name,
        coverUrl: playlist.thumbnail,
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: widget.recentlyPlayedService,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.mood)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
              ? Center(
                  child: Text(
                    'No playlists found',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                        ),
                  ),
                )
              : GridView.builder(
                  padding: ResponsiveUtils.responsivePadding(context),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: ResponsiveUtils.responsiveValue<int>(context, compact: 2, medium: 3, expanded: 4),
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: _playlists.length,
                  itemBuilder: (context, index) => PlaylistCard(
                    playlist: _playlists[index],
                    onTap: () => _openPlaylist(_playlists[index]),
                  ),
                ),
            );
  }
}
