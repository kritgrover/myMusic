import '../services/auth_http_client.dart';
import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import '../services/track_playback_helper.dart';

class MadeForYouScreen extends StatefulWidget {
  final List<VideoInfo> songs;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final VoidCallback? onBack;
  final String title;
  final ApiService? apiService;
  final PlaylistService? playlistService;

  const MadeForYouScreen({
    super.key,
    required this.songs,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
    this.onBack,
    this.title = 'Songs for You',
    this.apiService,
    this.playlistService,
  });

  @override
  State<MadeForYouScreen> createState() => _MadeForYouScreenState();
}

class _MadeForYouScreenState extends State<MadeForYouScreen> {
  late final ApiService _apiService = widget.apiService ?? ApiService();
  late final PlaylistService _playlistService =
      widget.playlistService ?? PlaylistService();

  bool _isDownloaded(VideoInfo song) => (song.filename ?? '').isNotEmpty;
  TrackPlaybackHelper get _playback => TrackPlaybackHelper(
        apiService: _apiService,
        queueService: widget.queueService,
        playerStateService: widget.playerStateService,
        playlistService: _playlistService,
      );

  Future<void> _playTrack(VideoInfo song) =>
      _playback.playTrack(context, PlaylistTrack.fromVideoInfo(song));

  Future<void> _addToQueue(VideoInfo song, {bool showSnackbar = true}) =>
      _playback.addToQueue(context, PlaylistTrack.fromVideoInfo(song),
          showSnackbar: showSnackbar);

  Future<void> _showAddToPlaylistDialog(VideoInfo song) =>
      _playback.addToPlaylist(context, PlaylistTrack.fromVideoInfo(song));

  Future<void> _downloadTrack(VideoInfo song) async {
    if (_isDownloaded(song)) return;
    await _playback.download(context, PlaylistTrack.fromVideoInfo(song));
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
          padding: ResponsiveUtils.responsivePadding(context),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
                tooltip: 'Back',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No recommendations available',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
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
                  padding: EdgeInsets.only(
                    left: ResponsiveUtils.responsiveValue<double>(context,
                        compact: 12, medium: 20, expanded: 24),
                    right: ResponsiveUtils.responsiveValue<double>(context,
                        compact: 12, medium: 20, expanded: 24),
                    top: 8,
                    bottom: 8,
                  ),
                  child: Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _playAll,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play All'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          foregroundColor:
                              Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${widget.songs.length} tracks',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.6),
                            ),
                      ),
                    ],
                  ),
                ),
                // Track list
                Expanded(
                  child: ListView.builder(
                    padding:
                        ResponsiveUtils.responsiveHorizontalPadding(context),
                    itemCount: widget.songs.length,
                    itemBuilder: (context, index) {
                      final song = widget.songs[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4.0),
                        child: InkWell(
                          onTap: () => _playTrack(song),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: song.thumbnail.isNotEmpty
                                      ? Image.network(
                                          AuthHttpClient.shared
                                              .cacheScopedUrl(song.thumbnail),
                                          headers: AuthHttpClient.shared
                                              .authHeadersForUrl(
                                                  song.thumbnail),
                                          width: ResponsiveUtils
                                              .responsiveIconSize(context,
                                                  base: 48),
                                          height: ResponsiveUtils
                                              .responsiveIconSize(context,
                                                  base: 48),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) {
                                            final size = ResponsiveUtils
                                                .responsiveIconSize(context,
                                                    base: 48);
                                            return Container(
                                              width: size,
                                              height: size,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceVariant,
                                              child:
                                                  const Icon(Icons.music_note),
                                            );
                                          },
                                        )
                                      : Container(
                                          width: ResponsiveUtils
                                              .responsiveIconSize(context,
                                                  base: 48),
                                          height: ResponsiveUtils
                                              .responsiveIconSize(context,
                                                  base: 48),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceVariant,
                                          child: const Icon(Icons.music_note),
                                        ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        song.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge,
                                      ),
                                      Text(
                                        song.uploader,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withOpacity(0.6),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow),
                                      tooltip: 'Play',
                                      onPressed: () => _playTrack(song),
                                    ),
                                    PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert),
                                      tooltip: 'More actions',
                                      onSelected: (value) {
                                        switch (value) {
                                          case 'download':
                                            _downloadTrack(song);
                                            break;
                                          case 'playlist':
                                            _showAddToPlaylistDialog(song);
                                            break;
                                          case 'queue':
                                            _addToQueue(song);
                                            break;
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        PopupMenuItem(
                                          value: 'download',
                                          enabled: !_isDownloaded(song),
                                          child: Row(
                                            children: [
                                              Icon(
                                                  _isDownloaded(song)
                                                      ? Icons.download_done
                                                      : Icons.download,
                                                  size: 20),
                                              const SizedBox(width: 12),
                                              Text(_isDownloaded(song)
                                                  ? 'Downloaded'
                                                  : 'Download'),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'playlist',
                                          child: Row(
                                            children: [
                                              Icon(Icons.playlist_add,
                                                  size: 20),
                                              SizedBox(width: 12),
                                              Text('Add to playlist'),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'queue',
                                          child: Row(
                                            children: [
                                              Icon(Icons.queue_music, size: 20),
                                              SizedBox(width: 12),
                                              Text('Add to queue'),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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
