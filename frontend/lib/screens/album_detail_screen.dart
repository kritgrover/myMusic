import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../services/recently_played_service.dart';
import '../services/track_playback_helper.dart';
import '../models/playlist.dart';
import '../models/discovery.dart';
import '../widgets/track_tile.dart';
import 'artist_screen.dart';

/// Tracklist view for a Spotify album (opened from New Releases / artist discography).
/// Reuses TrackPlaybackHelper so play/queue/download/playlist behave like everywhere else.
class AlbumDetailScreen extends StatefulWidget {
  final String albumId;
  final String albumName;
  final String? artist;
  final String? artistId;
  final String? coverUrl;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;

  const AlbumDetailScreen({
    super.key,
    required this.albumId,
    required this.albumName,
    this.artist,
    this.artistId,
    this.coverUrl,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  late final TrackPlaybackHelper _playback;

  List<PlaylistTrack> _tracks = [];
  AlbumInfo? _album;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _playback = TrackPlaybackHelper(
      apiService: ApiService(),
      queueService: widget.queueService,
      playerStateService: widget.playerStateService,
      playlistService: PlaylistService(),
    );
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _recommendationService.getAlbumTracks(widget.albumId),
        _recommendationService.getAlbum(widget.albumId),
      ]);
      final rawTracks = results[0] as List<PlaylistTrack>;
      final album = results[1] as AlbumInfo?;
      // Inject album name + cover so downloads get album metadata and tiles have art.
      final tracks = rawTracks
          .map((t) => PlaylistTrack(
                id: t.id,
                title: t.title,
                artist: t.artist ?? widget.artist,
                album: widget.albumName,
                filename: '',
                url: t.url,
                thumbnail: (t.thumbnail != null && t.thumbnail!.isNotEmpty)
                    ? t.thumbnail
                    : (album?.thumbnail ?? widget.coverUrl),
                duration: t.duration,
              ))
          .toList();
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _album = album;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String? get _cover => _album?.thumbnail ?? widget.coverUrl;
  String? get _artistName => _album?.artist ?? widget.artist;
  String? get _artistId => _album?.artistId ?? widget.artistId;

  void _openArtist() {
    final id = _artistId;
    if (id == null || id.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ArtistScreen(
        artistId: id,
        artistName: _artistName,
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: widget.recentlyPlayedService,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.albumName, overflow: TextOverflow.ellipsis)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: ResponsiveUtils.responsiveHorizontalPadding(context),
              children: [
                const SizedBox(height: 12),
                _buildHeader(context),
                const SizedBox(height: 12),
                if (_tracks.isNotEmpty)
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _playback.playAll(context, _tracks),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play All'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${_tracks.length} tracks',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (_tracks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'No tracks found for this album',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                            ),
                      ),
                    ),
                  )
                else
                  ..._tracks.map((t) => TrackTile(
                        track: t,
                        fallbackThumbnail: _cover,
                        onPlay: () => _playback.playTrack(context, t),
                        onAddToQueue: () => _playback.addToQueue(context, t),
                        onDownload: () => _playback.download(context, t),
                        onAddToPlaylist: () => _playback.addToPlaylist(context, t),
                      )),
                SizedBox(height: ResponsiveUtils.responsivePlayerBottomPadding(context)),
              ],
            ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final cover = _cover;
    final year = (_album?.releaseDate ?? '').split('-').first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: (cover != null && cover.isNotEmpty)
              ? Image.network(
                  cover,
                  width: 140,
                  height: 140,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverPlaceholder(context),
                )
              : _coverPlaceholder(context),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.albumName,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              if ((_artistName ?? '').isNotEmpty)
                InkWell(
                  onTap: (_artistId ?? '').isNotEmpty ? _openArtist : null,
                  child: Text(
                    _artistName!,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: (_artistId ?? '').isNotEmpty
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          fontWeight: FontWeight.w500,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (year.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '${(_album?.type ?? 'album') == 'single' ? 'Single' : 'Album'} • $year',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _coverPlaceholder(BuildContext context) {
    return Container(
      width: 140,
      height: 140,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(Icons.album, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}
