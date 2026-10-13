import '../services/auth_http_client.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/recommendation_service.dart';
import '../services/player_state_service.dart';
import '../services/api_service.dart';
import '../services/queue_service.dart';
import '../services/offline_download_service.dart';
import '../services/recently_played_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';
import '../utils/download_error_utils.dart';
import '../widgets/album_cover.dart';

enum PlaylistSortOption {
  defaultOrder,
  artistName,
  songName,
}

class SpotifyPlaylistScreen extends StatefulWidget {
  final String playlistId;
  final String playlistName;
  final String? coverUrl;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final bool embedded; // If true, don't show Scaffold/AppBar
  final VoidCallback? onBack; // Callback for back button when embedded
  final Function(String)?
      onDownloadStart; // Callback to start download progress tracking
  /// When provided, tracks are loaded via this callback instead of the Spotify
  /// playlist endpoint. Lets this screen be reused for any "remote" playlist
  /// (e.g. a friend's public playlist) while keeping all the play/queue/download
  /// actions identical.
  final Future<List<PlaylistTrack>> Function()? trackLoader;

  /// When provided, shows a "Save to my playlists" action that calls this callback.
  final Future<void> Function()? onSaveToLibrary;
  final RecommendationService? recommendationService;
  final ApiService? apiService;
  final OfflineDownloadService? offlineService;

  const SpotifyPlaylistScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
    this.coverUrl,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
    this.embedded = false,
    this.onBack,
    this.onDownloadStart,
    this.trackLoader,
    this.onSaveToLibrary,
    this.recommendationService,
    this.apiService,
    this.offlineService,
  });

  @override
  State<SpotifyPlaylistScreen> createState() => _SpotifyPlaylistScreenState();
}

class _SpotifyPlaylistScreenState extends State<SpotifyPlaylistScreen> {
  late final RecommendationService _recommendationService;
  late final ApiService _apiService = widget.apiService ?? ApiService();
  OfflineDownloadService get _offline =>
      widget.offlineService ?? OfflineDownloadService.shared;
  List<PlaylistTrack> _tracks = [];
  bool _isLoading = true;
  bool _loadFailed = false;
  PlaylistSortOption _sortOption = PlaylistSortOption.defaultOrder;

  @override
  void initState() {
    super.initState();
    _recommendationService =
        widget.recommendationService ?? RecommendationService();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    try {
      final tracks = widget.trackLoader != null
          ? await widget.trackLoader!()
          : await _recommendationService
              .getSpotifyPlaylistTracks(widget.playlistId);
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
    }
  }

  // Get sorted tracks based on current sort option
  List<PlaylistTrack> get _sortedTracks {
    final tracks = List<PlaylistTrack>.from(_tracks);

    switch (_sortOption) {
      case PlaylistSortOption.defaultOrder:
        return tracks;
      case PlaylistSortOption.artistName:
        tracks.sort((a, b) {
          final artistA = (a.artist ?? '').toLowerCase();
          final artistB = (b.artist ?? '').toLowerCase();
          if (artistA != artistB) {
            return artistA.compareTo(artistB);
          }
          final titleA = (a.title ?? '').toLowerCase();
          final titleB = (b.title ?? '').toLowerCase();
          return titleA.compareTo(titleB);
        });
        return tracks;
      case PlaylistSortOption.songName:
        tracks.sort((a, b) {
          final titleA = (a.title ?? '').toLowerCase();
          final titleB = (b.title ?? '').toLowerCase();
          return titleA.compareTo(titleB);
        });
        return tracks;
    }
  }

  void _changeSortOption(PlaylistSortOption? newOption) {
    if (newOption != null) {
      setState(() {
        _sortOption = newOption;
      });
    }
  }

  bool _isTrackDownloaded(PlaylistTrack track) {
    if (_offline.isSupported) {
      final spotifyId = ApiService.spotifyTrackId(track.url, id: track.id);
      final source = ApiService.canonicalYouTubeSource(track.url);
      // Match the service's strongest identity so an older recording with the
      // same catalog ID cannot hide a newly selected recording's download.
      final key = track.filename.isNotEmpty
          ? 'file:${track.filename}'
          : source != null
              ? 'source:$source'
              : spotifyId != null
                  ? 'spotify:$spotifyId'
                  : 'id:track_${track.id}';
      return _offline.tracks.any((saved) => saved.sourceKeys.contains(key));
    }
    return track.filename.isNotEmpty;
  }

  QueueItem _downloadItem(PlaylistTrack track) => QueueItem(
        id: 'track_${track.id}',
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        filename: track.filename,
        originalUrl: track.url,
        thumbnail: track.thumbnail,
        spotifyId: ApiService.spotifyTrackId(track.url, id: track.id),
      );

  void _showDownloadFailure(Object? error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(downloadFailureMessage(error)),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _downloadOffline({PlaylistTrack? track}) async {
    if (!_offline.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Device downloads are not ready. Please retry.'),
      ));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(track == null
          ? 'Saving this playlist on your device. See Offline library for progress.'
          : 'Saving on this device. See Offline library for progress.'),
    ));
    try {
      if (track != null) {
        await _offline.downloadTrack(_downloadItem(track),
            playlistId: widget.playlistId, playlistName: widget.playlistName);
      } else {
        final now = DateTime.now();
        await _offline.downloadPlaylist(Playlist(
          id: widget.playlistId,
          name: widget.playlistName,
          tracks: List.of(_tracks),
          createdAt: now,
          updatedAt: now,
          coverImage: widget.coverUrl,
        ));
      }
      if (!mounted) return;
      final failures = (track == null ? _tracks : [track])
          .map((entry) => _offline.jobFor(_downloadItem(entry)))
          .whereType<OfflineDownloadJob>()
          .where((job) => job.status == OfflineDownloadStatus.failed);
      if (failures.isNotEmpty) _showDownloadFailure(failures.first.error);
    } catch (error) {
      _showDownloadFailure(error);
    }
  }

  Future<Map<String, dynamic>> _serverDownload(PlaylistTrack track) async {
    final source = await _resolveTrackSource(track);
    if (source == null || source.isEmpty) {
      throw StateError('No matching recording found for ${track.title}.');
    }
    final spotifyId = ApiService.spotifyTrackId(track.url, id: track.id);
    return {
      'url': source,
      'title': track.title,
      'artist': track.artist ?? '',
      'album': track.album ?? '',
      if (spotifyId != null) 'spotify_id': spotifyId,
      'output_format': 'm4a',
      'embed_thumbnail': true,
    };
  }

  Future<void> _downloadTrack(PlaylistTrack track) async {
    if (_offline.isSupported) {
      await _downloadOffline(track: track);
      return;
    }

    try {
      final downloads = [await _serverDownload(track)];

      final result = await _apiService.startBatchDownload(downloads);
      final downloadId = result['download_id'] as String;

      // Start progress tracking if callback is provided
      if (widget.onDownloadStart != null) {
        widget.onDownloadStart!(downloadId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download started'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      _showDownloadFailure(e);
    }
  }

  Future<void> _downloadUndownloadedTracks() async {
    if (_offline.isSupported) {
      if (_tracks.isNotEmpty) await _downloadOffline();
      return;
    }
    final tracksToDownload = _tracks
        .where((track) =>
            !_isTrackDownloaded(track) &&
            track.url != null &&
            track.url!.isNotEmpty)
        .toList();

    if (tracksToDownload.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('All tracks are already downloaded'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download Tracks'),
        content: Text(
          'Download ${tracksToDownload.length} ${tracksToDownload.length == 1 ? 'track' : 'tracks'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final downloads = <Map<String, dynamic>>[];
      for (final track in tracksToDownload) {
        downloads.add(await _serverDownload(track));
      }

      final result = await _apiService.startBatchDownload(downloads);
      final downloadId = result['download_id'] as String;

      if (widget.onDownloadStart != null) {
        widget.onDownloadStart!(downloadId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloading ${tracksToDownload.length} tracks...'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      _showDownloadFailure(e);
    }
  }

  Future<void> _saveToLibrary() async {
    if (widget.onSaveToLibrary == null) return;
    try {
      await widget.onSaveToLibrary!();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to your playlists'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save playlist: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<String?> _resolveTrackSource(PlaylistTrack track) =>
      _apiService.resolveToYouTubeUrl(
        track.url,
        track.title,
        track.artist,
        album: track.album,
        duration: track.duration,
        spotifyId: ApiService.spotifyTrackId(track.url, id: track.id),
      );

  Future<void> _playTrack(PlaylistTrack track) async {
    try {
      if (track.filename.isNotEmpty && widget.playerStateService != null) {
        final displayTitle = getDisplayTitle(track.title, track.filename);
        final url =
            (track.url != null && track.url!.isNotEmpty) ? track.url : null;
        await widget.playerStateService.playTrack(
          track.filename,
          trackName: displayTitle,
          trackArtist: track.artist,
          url: url,
          album: track.album,
          duration: track.duration,
          spotifyId: ApiService.spotifyTrackId(track.url, id: track.id),
        );
      } else if (track.url != null && track.url!.isNotEmpty) {
        if (widget.playerStateService != null) {
          try {
            final youtubeUrl = await _resolveTrackSource(track);
            if (youtubeUrl == null)
              throw StateError('No matching recording found');
            if (youtubeUrl.isNotEmpty) {
              final result = await _apiService.getStreamingUrl(
                url: youtubeUrl,
                title: track.title,
                artist: track.artist ?? '',
              );

              await widget.playerStateService.streamTrack(
                result.streamingUrl,
                trackName: result.title,
                trackArtist: result.artist,
                url: youtubeUrl,
                album: track.album,
                duration: track.duration,
                spotifyId: ApiService.spotifyTrackId(track.url, id: track.id),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Stream failed: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _playPlaylist() async {
    if (widget.queueService == null || widget.playerStateService == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Player or queue service not available'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (_tracks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist is empty'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (widget.recentlyPlayedService != null) {
      widget.recentlyPlayedService!.addPlaylist(
        playlistId: widget.playlistId,
        title: widget.playlistName,
        thumbnail: widget.coverUrl,
      );
    }

    try {
      final tracks = _sortedTracks;
      final queueItems = <QueueItem>[];

      // Create queue items immediately without fetching streaming URLs
      for (final track in tracks) {
        if (track.filename.isNotEmpty) {
          // Local file - ready to play
          queueItems.add(QueueItem.fromDownloadedFile(
            filename: track.filename,
            title: track.title,
            artist: track.artist,
            album: track.album,
          ));
        } else if (track.url != null && track.url!.isNotEmpty) {
          // Create item with original URL for lazy loading
          queueItems.add(QueueItem.fromPlaylistTrackLazy(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            originalUrl: track.url!,
            album: track.album,
            thumbnail: track.thumbnail,
            duration: track.duration,
          ));
        }
      }

      if (queueItems.isNotEmpty) {
        widget.queueService!.clearQueue();
        widget.queueService!.addAllToQueue(
          queueItems,
          isPlaylistQueue: true,
          loadStreamingUrl: _loadStreamingUrlForQueueItem,
        );

        if (widget.recentlyPlayedService != null) {
          await widget.recentlyPlayedService!.addPlaylist(
            playlistId: widget.playlistId,
            title: widget.playlistName,
            thumbnail: widget.coverUrl,
          );
        }

        // Start playing first item (will load streaming URL if needed)
        await widget.queueService!.playItem(0, widget.playerStateService!);

        // Preload streaming URLs for next 2 items in background
        _preloadNextStreamingUrls(0, 2);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play playlist: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  Future<void> _addPlaylistToQueue() async {
    await _addPlaylistToQueueInternal(shuffle: false);
  }

  Future<void> _shufflePlaylistToQueue() async {
    await _addPlaylistToQueueInternal(shuffle: true);
  }

  Future<void> _addPlaylistToQueueInternal({required bool shuffle}) async {
    if (widget.queueService == null) return;

    if (_tracks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist is empty'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (widget.recentlyPlayedService != null) {
      widget.recentlyPlayedService!.addPlaylist(
        playlistId: widget.playlistId,
        title: widget.playlistName,
        thumbnail: widget.coverUrl,
      );
    }

    try {
      final tracks = List<PlaylistTrack>.from(_sortedTracks);
      if (shuffle) {
        tracks.shuffle(Random());
      }

      final queueItems = <QueueItem>[];

      // Create queue items immediately without fetching streaming URLs
      for (final track in tracks) {
        if (track.filename.isNotEmpty) {
          // Local file - ready to play
          queueItems.add(QueueItem.fromDownloadedFile(
            filename: track.filename,
            title: track.title,
            artist: track.artist,
            album: track.album,
          ));
        } else if (track.url != null && track.url!.isNotEmpty) {
          // Create item with original URL for lazy loading
          queueItems.add(QueueItem.fromPlaylistTrackLazy(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            originalUrl: track.url!,
            album: track.album,
            thumbnail: track.thumbnail,
            duration: track.duration,
          ));
        }
      }

      if (queueItems.isNotEmpty) {
        if (shuffle) {
          widget.queueService!.clearQueue();
        }

        widget.queueService!.addAllToQueue(
          queueItems,
          isPlaylistQueue: true,
          loadStreamingUrl: _loadStreamingUrlForQueueItem,
        );

        if (shuffle && widget.playerStateService != null) {
          if (widget.recentlyPlayedService != null) {
            await widget.recentlyPlayedService!.addPlaylist(
              playlistId: widget.playlistId,
              title: widget.playlistName,
              thumbnail: widget.coverUrl,
            );
          }
          await widget.queueService!.playItem(0, widget.playerStateService!);

          // Preload streaming URLs for next 2 items in background
          _preloadNextStreamingUrls(0, 2);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Failed to ${shuffle ? 'shuffle and ' : ''}add playlist to queue: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  // Preload streaming URLs for next N items in background
  Future<void> _preloadNextStreamingUrls(int startIndex, int count) async {
    final queue = widget.queueService!.queue;
    final endIndex = (startIndex + count + 1).clamp(0, queue.length);

    for (int i = startIndex + 1; i < endIndex; i++) {
      final item = queue[i];

      // Skip if already has streaming URL or is a local file
      if (item.url != null ||
          item.filename != null ||
          item.originalUrl == null) {
        continue;
      }

      // Load streaming URL in background
      _loadStreamingUrlForItem(item, i).catchError((e) {
        // Silently fail - we'll load it when needed
      });
    }
  }

  // Load streaming URL for a queue item (callback for queue service)
  Future<String?> _loadStreamingUrlForQueueItem(QueueItem item) async {
    try {
      final youtubeUrl = await _apiService.resolveToYouTubeUrl(
        item.originalUrl,
        item.title ?? '',
        item.artist,
        album: item.album,
        duration: item.duration,
        spotifyId: item.spotifyId,
      );
      if (youtubeUrl == null) return null;
      final result = await _apiService.getStreamingUrl(
        url: youtubeUrl,
        title: item.title ?? '',
        artist: item.artist ?? '',
      );
      return result.streamingUrl;
    } catch (_) {
      return null;
    }
  }

  // Load streaming URL for a specific queue item and update it (for background preloading)
  Future<void> _loadStreamingUrlForItem(QueueItem item, int queueIndex) async {
    final streamingUrl = await _loadStreamingUrlForQueueItem(item);
    if (streamingUrl != null) {
      // Update the queue item with streaming URL
      final updatedItem = item.copyWithStreamingUrl(streamingUrl);
      widget.queueService!.updateItemAt(queueIndex, updatedItem);
    }
  }

  Future<void> _addToQueue(PlaylistTrack track) async {
    if (widget.queueService == null) return;

    try {
      QueueItem? queueItem;

      if (track.filename.isNotEmpty) {
        queueItem = QueueItem.fromDownloadedFile(
          filename: track.filename,
          title: track.title,
          artist: track.artist,
          album: track.album,
        );
      } else if (track.url != null && track.url!.isNotEmpty) {
        try {
          final youtubeUrl = await _resolveTrackSource(track);
          if (youtubeUrl == null)
            throw StateError('No matching recording found');
          if (youtubeUrl.isNotEmpty) {
            final result = await _apiService.getStreamingUrl(
              url: youtubeUrl,
              title: track.title,
              artist: track.artist ?? '',
            );

            queueItem = QueueItem.fromPlaylistTrack(
              trackId: track.id,
              title: result.title,
              artist: result.artist,
              streamingUrl: result.streamingUrl,
              originalUrl: youtubeUrl,
              album: track.album,
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to get streaming URL: $e'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No URL or filename available'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      if (queueItem != null) {
        widget.queueService!.addToQueue(queueItem);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to queue: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildContent() {
    if (_loadFailed) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.onBack != null)
              TextButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back')),
            const Icon(Icons.cloud_off_outlined, size: 44),
            const SizedBox(height: 16),
            Text('Playlist tracks are unavailable',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
                widget.trackLoader == null
                    ? 'This catalog connection could not load the tracks in “${widget.playlistName}”. The provider may limit access to playlist contents.'
                    : 'Could not load the tracks in “${widget.playlistName}”. Please try again.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
                onPressed: _loadTracks,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry playlist')),
          ]),
        ),
      );
    }
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;

    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              // Playlist header
              Container(
                padding: ResponsiveUtils.responsivePadding(context),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Back button
                    if (widget.onBack != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: widget.onBack,
                        tooltip: 'Back',
                      ),
                    _PlaylistCoverWidget(
                      coverImageUrl: widget.coverUrl,
                      primaryColor: primaryColor,
                    ),
                    SizedBox(
                        width: ResponsiveUtils.responsiveValue<double>(context,
                            compact: 12, medium: 16, expanded: 20)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Title row
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.playlistName,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Track count (left) + secondary actions (right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.music_note,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withOpacity(0.5),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${_tracks.length} ${_tracks.length == 1 ? 'track' : 'tracks'}',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (widget.queueService != null &&
                                          widget.playerStateService != null)
                                        IconButton(
                                          icon: const Icon(Icons.queue_music,
                                              size: 20),
                                          onPressed: _addPlaylistToQueue,
                                          tooltip: 'Add playlist to queue',
                                        ),
                                      IconButton(
                                        icon: const Icon(Icons.download,
                                            size: 20),
                                        onPressed: _downloadUndownloadedTracks,
                                        tooltip: _offline.isSupported
                                            ? 'Download for offline'
                                            : 'Download undownloaded tracks',
                                      ),
                                      if (widget.onSaveToLibrary != null)
                                        IconButton(
                                          icon: const Icon(
                                              Icons.library_add_outlined,
                                              size: 20),
                                          onPressed: _saveToLibrary,
                                          tooltip: 'Save to my playlists',
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Play / Shuffle (left) + Sort by (right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (widget.queueService != null &&
                                  widget.playerStateService != null)
                                Row(
                                  children: [
                                    FilledButton.icon(
                                      onPressed: _playPlaylist,
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                        ),
                                      ),
                                      icon: const Icon(Icons.play_arrow_rounded,
                                          size: 26),
                                      label: const Text(
                                        'Play',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: _shufflePlaylistToQueue,
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 18, vertical: 11),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                        ),
                                      ),
                                      icon: const Icon(Icons.shuffle, size: 22),
                                      label: const Text(
                                        'Shuffle',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                const SizedBox.shrink(),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Sort by:',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                  const SizedBox(width: 8),
                                  Material(
                                    child: DropdownButton<PlaylistSortOption>(
                                      value: _sortOption,
                                      underline: const SizedBox.shrink(),
                                      borderRadius: BorderRadius.circular(12),
                                      onChanged: _changeSortOption,
                                      items: const [
                                        DropdownMenuItem(
                                          value:
                                              PlaylistSortOption.defaultOrder,
                                          child: Text('Default'),
                                        ),
                                        DropdownMenuItem(
                                          value: PlaylistSortOption.artistName,
                                          child: Text('Artist'),
                                        ),
                                        DropdownMenuItem(
                                          value: PlaylistSortOption.songName,
                                          child: Text('Song'),
                                        ),
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
                  ],
                ),
              ),
              // Tracks list
              Expanded(
                child: _tracks.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.queue_music,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No tracks in this playlist',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        itemCount: _sortedTracks.length,
                        itemBuilder: (context, index) {
                          final track = _sortedTracks[index];
                          final isCurrentlyPlaying =
                              widget.playerStateService != null &&
                                  widget.playerStateService.currentTrackUrl
                                          ?.contains(track.url ?? '') ==
                                      true;

                          final displayTitle =
                              getDisplayTitle(track.title, track.filename);

                          return Column(
                            children: [
                              Material(
                                color: isCurrentlyPlaying
                                    ? primaryColor.withOpacity(0.1)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  onTap: () => _playTrack(track),
                                  borderRadius: BorderRadius.circular(8),
                                  hoverColor: surfaceHover,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    child: Row(
                                      children: [
                                        AlbumCover(
                                          filename: track.filename.isNotEmpty
                                              ? track.filename
                                              : null,
                                          title: track.title,
                                          artist: track.artist,
                                          album: track.album,
                                          artworkUrl: (track.thumbnail !=
                                                      null &&
                                                  !track.thumbnail!.contains(
                                                      'img.youtube.com'))
                                              ? track.thumbnail
                                              : null,
                                          size: ResponsiveUtils
                                              .responsiveIconSize(context,
                                                  base: 40),
                                          backgroundColor: isCurrentlyPlaying
                                              ? primaryColor.withOpacity(0.2)
                                              : surfaceHover,
                                          iconColor: isCurrentlyPlaying
                                              ? primaryColor
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withOpacity(0.5),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                displayTitle,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          isCurrentlyPlaying
                                                              ? FontWeight.w600
                                                              : FontWeight.w400,
                                                      color: isCurrentlyPlaying
                                                          ? primaryColor
                                                          : null,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              if (track.artist != null &&
                                                  track.artist!.isNotEmpty) ...[
                                                const SizedBox(height: 2),
                                                Text(
                                                  track.artist!,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Add to queue button
                                            if (widget.queueService != null)
                                              IconButton(
                                                icon: const Icon(
                                                    Icons.queue_music,
                                                    size: 20),
                                                onPressed: () =>
                                                    _addToQueue(track),
                                                tooltip: 'Add to queue',
                                              ),
                                            // Download status icon
                                            _isTrackDownloaded(track)
                                                ? IconButton(
                                                    icon: Icon(
                                                      Icons.check_circle,
                                                      color: primaryColor,
                                                      size: 20,
                                                    ),
                                                    onPressed: null,
                                                    tooltip: _offline
                                                            .isSupported
                                                        ? 'Saved on this device'
                                                        : 'Downloaded',
                                                  )
                                                : IconButton(
                                                    icon: const Icon(
                                                        Icons.download_outlined,
                                                        size: 20),
                                                    onPressed: () =>
                                                        _downloadTrack(track),
                                                    tooltip: 'Download',
                                                  ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(height: 1),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
  }

  @override
  Widget build(BuildContext context) {
    final content = AnimatedBuilder(
      animation: _offline,
      builder: (context, _) => _buildContent(),
    );
    if (widget.embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlistName),
      ),
      body: content,
    );
  }
}

class _PlaylistCoverWidget extends StatelessWidget {
  final String? coverImageUrl;
  final Color primaryColor;

  const _PlaylistCoverWidget({
    required this.coverImageUrl,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final coverSize =
        ResponsiveUtils.responsiveLargeIconSize(context, base: 160);
    return Container(
      width: coverSize,
      height: coverSize,
      decoration: BoxDecoration(
        color: primaryColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: coverImageUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                AuthHttpClient.shared.cacheScopedUrl(coverImageUrl!),
                headers:
                    AuthHttpClient.shared.authHeadersForUrl(coverImageUrl!),
                width: coverSize,
                height: coverSize,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Icon(
                    Icons.playlist_play,
                    size: coverSize * 0.5,
                    color: primaryColor,
                  );
                },
              ),
            )
          : Icon(
              Icons.playlist_play,
              size: coverSize * 0.5,
              color: primaryColor,
            ),
    );
  }
}
