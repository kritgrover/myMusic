import 'package:flutter/material.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import 'spotify_playlist_screen.dart';

class GenreScreen extends StatefulWidget {
  final String genre;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final bool embedded; // If true, don't show Scaffold/AppBar
  final VoidCallback? onBack; // Callback for back button when embedded

  const GenreScreen({
    super.key,
    required this.genre,
    required this.playerStateService,
    required this.queueService,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends State<GenreScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  List<dynamic> _playlists = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await _recommendationService.getGenrePlaylists(widget.genre);
      if (mounted) {
        setState(() {
          _playlists = playlists;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading playlists: $e')),
        );
      }
    }
  }

  Widget _buildContent() {
    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _playlists.isEmpty
            ? Center(
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
                      'No playlists found',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.85,
                ),
                itemCount: _playlists.length,
                itemBuilder: (context, index) {
                  final playlist = _playlists[index];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => SpotifyPlaylistScreen(
                                playlistId: playlist['id'],
                                playlistName: playlist['name'],
                                coverUrl: playlist['thumbnail'],
                                playerStateService: widget.playerStateService,
                                queueService: widget.queueService,
                              ),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Smaller image
                              AspectRatio(
                                aspectRatio: 1.0,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: playlist['thumbnail'] != null
                                      ? Image.network(
                                          playlist['thumbnail'],
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          errorBuilder: (_, __, ___) => Container(
                                            color: Theme.of(context).colorScheme.surfaceVariant,
                                            child: Icon(
                                              Icons.music_note,
                                              size: 28,
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        )
                                      : Container(
                                          color: Theme.of(context).colorScheme.surfaceVariant,
                                          child: Icon(
                                            Icons.music_note,
                                            size: 28,
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              // Title text
                              Flexible(
                                child: Text(
                                  playlist['name'] ?? 'Unknown Playlist',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Owner text
                              Text(
                                playlist['owner'] ?? '',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
                  '${widget.genre} Playlists',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
        title: Text('${widget.genre} Playlists'),
      ),
      body: _buildContent(),
    );
  }
}

