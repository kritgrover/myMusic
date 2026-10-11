import '../services/auth_http_client.dart';
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
import '../widgets/save_music_button.dart';
import '../services/saved_music_service.dart';
import 'album_detail_screen.dart';

/// Artist page: header, popular tracks, discography, and "Fans also like".
class ArtistScreen extends StatefulWidget {
  final String artistId;
  final String? artistName;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final RecommendationService? recommendationService;

  const ArtistScreen({
    super.key,
    required this.artistId,
    this.artistName,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
    this.recommendationService,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  late final RecommendationService _recommendationService;
  late final TrackPlaybackHelper _playback;

  ArtistInfo? _artist;
  List<PlaylistTrack> _topTracks = [];
  List<AlbumInfo> _albums = [];
  List<ArtistInfo> _related = [];
  bool _profileLoading = true;
  bool _albumsLoading = true;
  bool _albumsFailed = false;
  String _releaseFilter = 'all';
  bool _newestFirst = true;

  @override
  void initState() {
    super.initState();
    _recommendationService =
        widget.recommendationService ?? RecommendationService();
    _playback = TrackPlaybackHelper(
      apiService: ApiService(),
      queueService: widget.queueService,
      playerStateService: widget.playerStateService,
      playlistService: PlaylistService(),
    );
    _loadProfile();
    _loadAlbums();
    _loadTopTracks();
    _loadRelated();
  }

  Future<void> _loadProfile() async {
    setState(() => _profileLoading = true);
    try {
      final artist = await _recommendationService.getArtist(widget.artistId);
      if (mounted) setState(() => _artist = artist);
    } catch (_) {
      // A missing profile does not hide an otherwise available discography.
    } finally {
      if (mounted) setState(() => _profileLoading = false);
    }
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _albumsLoading = true;
      _albumsFailed = false;
    });
    try {
      final albums =
          await _recommendationService.getArtistAlbums(widget.artistId);
      if (mounted) setState(() => _albums = albums);
    } catch (_) {
      if (mounted) setState(() => _albumsFailed = true);
    } finally {
      if (mounted) setState(() => _albumsLoading = false);
    }
  }

  Future<void> _loadTopTracks() async {
    try {
      final tracks =
          await _recommendationService.getArtistTopTracks(widget.artistId);
      if (mounted) setState(() => _topTracks = tracks);
    } catch (_) {
      // This optional provider endpoint is unavailable for some catalog accounts.
    }
  }

  Future<void> _loadRelated() async {
    try {
      final related =
          await _recommendationService.getRelatedArtists(widget.artistId);
      if (mounted) setState(() => _related = related);
    } catch (_) {
      // Related artists must not delay or fail the core artist page.
    }
  }

  List<AlbumInfo> get _visibleAlbums {
    final albums = _albums
        .where((album) =>
            _releaseFilter == 'all' || album.releaseGroup == _releaseFilter)
        .toList();
    albums.sort((a, b) {
      final dateOrder = (a.releaseDate ?? '').compareTo(b.releaseDate ?? '');
      return dateOrder == 0
          ? a.name.compareTo(b.name)
          : (_newestFirst ? -dateOrder : dateOrder);
    });
    return albums;
  }

  String get _name => _artist?.name ?? widget.artistName ?? 'Artist';

  void _openAlbum(AlbumInfo album) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlbumDetailScreen(
        albumId: album.id,
        albumName: album.name,
        artist: album.artist ?? _name,
        artistId: album.artistId ?? widget.artistId,
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
      body: CustomScrollView(
        slivers: [
          SliverList(
              delegate: SliverChildListDelegate([
            const SizedBox(height: 16),
            _buildHeader(context),
            if (_profileLoading)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            if (!_profileLoading && _artist == null)
              Center(
                  child: TextButton.icon(
                onPressed: _loadProfile,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry artist details'),
              )),
            Center(
                child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FollowArtistButton(
                        artist: SavedArtist(
                            id: widget.artistId,
                            name: _name,
                            thumbnail: _artist?.thumbnail)))),
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
                  left: ResponsiveUtils.responsiveValue<double>(context,
                      compact: 12, medium: 20, expanded: 24),
                  bottom: 4,
                ),
                child: Text('Popular',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Padding(
                padding: ResponsiveUtils.responsiveHorizontalPadding(context),
                child: Column(
                  children: _topTracks
                      .map((t) => TrackTile(
                            track: t,
                            onPlay: () => _playback.playTrack(context, t),
                            onAddToQueue: () =>
                                _playback.addToQueue(context, t),
                            onDownload: () => _playback.download(context, t),
                            onAddToPlaylist: () =>
                                _playback.addToPlaylist(context, t),
                          ))
                      .toList(),
                ),
              ),
            ],
            _buildDiscographyControls(context),
          ])),
          _buildDiscography(context),
          SliverToBoxAdapter(
              child: Column(children: [
            if (_related.isNotEmpty) ...[
              const SizedBox(height: 8),
              HorizontalCardRow(
                title: 'Fans also like',
                itemCount: _related.length,
                itemWidth:
                    ResponsiveUtils.responsiveHorizontalCardWidth(context),
                labelHeight: 32,
                itemBuilder: (context, index) => ArtistCard(
                  artist: _related[index],
                  onTap: () => _openArtist(_related[index]),
                ),
              ),
            ],
            SizedBox(
                height: ResponsiveUtils.responsivePlayerBottomPadding(context)),
          ])),
        ],
      ),
    );
  }

  Widget _buildDiscographyControls(BuildContext context) {
    const filters = {
      'all': 'All releases',
      'album': 'Albums',
      'single': 'Singles & EPs',
      'compilation': 'Compilations',
      'appears_on': 'Appears on',
    };
    return Padding(
      padding: ResponsiveUtils.responsiveHorizontalPadding(context)
          .add(const EdgeInsets.only(top: 24, bottom: 12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Discography',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Releases available through Spotify’s US catalog.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final filter in filters.entries)
              ChoiceChip(
                label: Text(filter.value),
                selected: _releaseFilter == filter.key,
                onSelected: (_) => setState(() => _releaseFilter = filter.key),
              ),
          ]),
          if (!_albumsLoading && !_albumsFailed && _albums.isNotEmpty)
            Row(children: [
              Expanded(
                  child: Text(
                      '${_visibleAlbums.length} ${_visibleAlbums.length == 1 ? 'release' : 'releases'}',
                      style: Theme.of(context).textTheme.bodySmall)),
              TextButton.icon(
                onPressed: () => setState(() => _newestFirst = !_newestFirst),
                icon: const Icon(Icons.sort, size: 18),
                label: Text(_newestFirst ? 'Newest first' : 'Oldest first'),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _buildDiscography(BuildContext context) {
    if (_albumsLoading) {
      return const SliverToBoxAdapter(
          child: Padding(
        padding: EdgeInsets.all(28),
        child: Center(
            child: Column(children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading discography…'),
        ])),
      ));
    }
    if (_albumsFailed) {
      return SliverToBoxAdapter(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const Text('Could not load this discography. Please try again.',
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: _loadAlbums,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry discography')),
        ]),
      ));
    }
    final albums = _visibleAlbums;
    if (albums.isEmpty) {
      return SliverToBoxAdapter(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
            _albums.isEmpty
                ? 'No releases are available in this catalog right now.'
                : 'No releases in this category.',
            textAlign: TextAlign.center),
      ));
    }
    return SliverPadding(
      padding: ResponsiveUtils.responsiveHorizontalPadding(context),
      sliver: SliverLayoutBuilder(builder: (context, constraints) {
        final columns = (constraints.crossAxisExtent / 175).floor().clamp(2, 6);
        final width =
            (constraints.crossAxisExtent - (columns - 1) * 16) / columns;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: width + 88,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildAlbumCard(context, albums[index]),
            childCount: albums.length,
          ),
        );
      }),
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
                  AuthHttpClient.shared.cacheScopedUrl(thumb),
                  headers: AuthHttpClient.shared.authHeadersForUrl(thumb),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _avatarPlaceholder(context, size),
                )
              : _avatarPlaceholder(context, size),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: ResponsiveUtils.responsiveHorizontalPadding(context),
          child: Text(
            _name,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
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
    final year = album.releaseYear;
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
                      AuthHttpClient.shared.cacheScopedUrl(album.thumbnail!),
                      headers: AuthHttpClient.shared
                          .authHeadersForUrl(album.thumbnail!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _albumPlaceholder(context),
                    )
                  : _albumPlaceholder(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            album.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            year.isNotEmpty
                ? '$year • ${album.releaseTypeLabel}'
                : album.releaseTypeLabel,
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
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person,
          size: size * 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  Widget _albumPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.album,
          size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}
