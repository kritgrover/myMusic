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
import '../widgets/artist_card.dart';
import '../widgets/horizontal_card_row.dart';
import 'album_detail_screen.dart';

/// Artist page: header, popular tracks, discography, and "Fans also like".
class ArtistScreen extends StatefulWidget {
  final String artistId;
  final String? artistName;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;

  const ArtistScreen({
    super.key,
    required this.artistId,
    this.artistName,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  final RecommendationService _recommendationService = RecommendationService();
  late final TrackPlaybackHelper _playback;

  ArtistInfo? _artist;
  List<PlaylistTrack> _topTracks = [];
  List<AlbumInfo> _albums = [];
  List<ArtistInfo> _related = [];
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
        _recommendationService.getArtist(widget.artistId),
        _recommendationService.getArtistTopTracks(widget.artistId),
        _recommendationService.getArtistAlbums(widget.artistId),
        _recommendationService.getRelatedArtists(widget.artistId),
      ]);
      if (mounted) {
        setState(() {
          _artist = results[0] as ArtistInfo?;
          _topTracks = results[1] as List<PlaylistTrack>;
          _albums = results[2] as List<AlbumInfo>;
          _related = results[3] as List<ArtistInfo>;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String get _name => _artist?.name ?? widget.artistName ?? 'Artist';

  void _openAlbum(AlbumInfo album) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlbumDetailScreen(
        albumId: album.id,
        albumName: album.name,
        artist: album.artist ?? _name,
        artistId: widget.artistId,
        coverUrl: album.thumbnail,
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: widget.recentlyPlayedService,
      ),
    ));
  }

  void _openArtist(ArtistInfo artist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ArtistScreen(
        artistId: artist.id,
        artistName: artist.name,
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: widget.recentlyPlayedService,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_name, overflow: TextOverflow.ellipsis)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 16),
                _buildHeader(context),
                const SizedBox(height: 8),
                if (_topTracks.isNotEmpty) ...[
                  Padding(
                    padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                    child: Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _playback.playAll(context, _topTracks),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.only(
                      left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
                      bottom: 4,
                    ),
                    child: Text('Popular',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                    child: Column(
                      children: _topTracks
                          .map((t) => TrackTile(
                                track: t,
                                onPlay: () => _playback.playTrack(context, t),
                                onAddToQueue: () => _playback.addToQueue(context, t),
                                onDownload: () => _playback.download(context, t),
                                onAddToPlaylist: () => _playback.addToPlaylist(context, t),
                              ))
                          .toList(),
                    ),
                  ),
                ],
                if (_albums.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  HorizontalCardRow(
                    title: 'Albums & Singles',
                    itemCount: _albums.length,
                    itemWidth: ResponsiveUtils.responsiveHorizontalCardWidth(context),
                    labelHeight: 52,
                    itemBuilder: (context, index) => _buildAlbumCard(context, _albums[index]),
                  ),
                ],
                if (_related.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  HorizontalCardRow(
                    title: 'Fans also like',
                    itemCount: _related.length,
                    itemWidth: ResponsiveUtils.responsiveHorizontalCardWidth(context),
                    labelHeight: 32,
                    itemBuilder: (context, index) => ArtistCard(
                      artist: _related[index],
                      onTap: () => _openArtist(_related[index]),
                    ),
                  ),
                ],
                SizedBox(height: ResponsiveUtils.responsivePlayerBottomPadding(context)),
              ],
            ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final thumb = _artist?.thumbnail;
    final size = ResponsiveUtils.responsiveLargeIconSize(context, base: 140);
    final genres = _artist?.genres ?? const [];
    return Column(
      children: [
        ClipOval(
          child: (thumb != null && thumb.isNotEmpty)
              ? Image.network(
                  thumb,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _avatarPlaceholder(context, size),
                )
              : _avatarPlaceholder(context, size),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: ResponsiveUtils.responsiveHorizontalPadding(context),
          child: Text(
            _name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (_artist?.followers != null) ...[
          const SizedBox(height: 4),
          Text(
            '${_formatCount(_artist!.followers!)} followers',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(
            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
            child: Text(
              genres.take(3).join(' • '),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAlbumCard(BuildContext context, AlbumInfo album) {
    final year = (album.releaseDate ?? '').split('-').first;
    return InkWell(
      onTap: () => _openAlbum(album),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: (album.thumbnail != null && album.thumbnail!.isNotEmpty)
                  ? Image.network(
                      album.thumbnail!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _albumPlaceholder(context),
                    )
                  : _albumPlaceholder(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            year.isNotEmpty ? '${album.type == 'single' ? 'Single' : 'Album'} • $year' : (album.type ?? ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _avatarPlaceholder(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(Icons.person, size: size * 0.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  Widget _albumPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(Icons.album, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
