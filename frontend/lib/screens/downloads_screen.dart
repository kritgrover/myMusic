import 'package:flutter/material.dart';
import '../widgets/save_track_button.dart';
import '../utils/responsive_utils.dart';
import '../services/api_service.dart';
import '../services/auth_http_client.dart';
import '../services/saved_music_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/offline_download_service.dart';
import '../services/recently_played_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';
import '../widgets/album_cover.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/gradient_section_header.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';

class DownloadsScreen extends StatefulWidget {
  final PlayerStateService playerStateService;
  final QueueService? queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final ApiService? apiService;
  final SavedMusicService? savedMusicService;
  final OfflineDownloadService? offlineService;

  const DownloadsScreen({
    super.key,
    required this.playerStateService,
    this.queueService,
    this.recentlyPlayedService,
    this.apiService,
    this.savedMusicService,
    this.offlineService,
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  late final ApiService _apiService;
  late final SavedMusicService _savedMusic;
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _searchController = TextEditingController();
  List<DownloadedFile> _downloads = [];
  bool _isLoading = true;
  String _searchQuery = '';
  OfflineDownloadService get _offline =>
      widget.offlineService ?? OfflineDownloadService.shared;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService();
    _savedMusic = widget.savedMusicService ?? SavedMusicService.shared;
    _loadDownloads();
    // Listen to player state changes to update highlighting
    widget.playerStateService.addListener(_onPlayerStateChanged);
    _searchController.addListener(_onSearchChanged);
    _offline.addListener(_onPlayerStateChanged);
  }

  void _onSearchChanged() {
    if (mounted) {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase().trim();
      });
    }
  }

  void _onPlayerStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    widget.playerStateService.removeListener(_onPlayerStateChanged);
    _offline.removeListener(_onPlayerStateChanged);
    super.dispose();
  }

  Future<void> _loadDownloads() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final downloads = await _apiService.listDownloads();
      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load downloads: $e')),
        );
      }
    }
  }

  List<DownloadedFile> get _filteredDownloads {
    final query = _searchQuery;
    if (query.isEmpty || query.trim().isEmpty) {
      return _downloads;
    }
    if (_downloads.isEmpty) {
      return _downloads;
    }
    try {
      return _downloads.where((file) {
        try {
          final displayName =
              getDisplayTitle(file.title, file.filename).toLowerCase();
          final filename = file.filename.toLowerCase();
          return displayName.contains(query) || filename.contains(query);
        } catch (e) {
          return false;
        }
      }).toList();
    } catch (e) {
      return _downloads;
    }
  }

  Future<void> _playFile(DownloadedFile file) async {
    try {
      // Use formatted display name for track name to show proper song name
      final trackName = getDisplayTitle(file.title, file.filename);
      await widget.playerStateService.playTrack(
        file.filename,
        trackName: trackName,
        trackArtist: file.artist,
      );
      // Tracking is now done in PlayerStateService when song starts
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play: $e')),
        );
      }
    }
  }

  Future<void> _deleteFile(DownloadedFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete server copy'),
        content: Text('Delete "${file.filename}" from the server? '
            'Copies saved on your devices will remain available.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final session = AuthHttpClient.shared.cacheScope;
      try {
        await _apiService.deleteDownload(file.filename);
        if (!mounted || session != AuthHttpClient.shared.cacheScope) return;
        await _savedMusic.refreshAfterDownloadDeletion(file.filename);
        if (!mounted || session != AuthHttpClient.shared.cacheScope) return;
        await _loadDownloads();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  Future<void> _addToPlaylist(DownloadedFile file) async {
    try {
      final track = PlaylistTrack.fromDownloadedFile(file);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => PlaylistSelectionDialog(
          playlistService: _playlistService,
          track: track,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to playlist: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _addToQueue(DownloadedFile file) async {
    if (widget.queueService == null) return;

    try {
      final queueItem = QueueItem.fromDownloadedFile(
        filename: file.filename,
        title: file.title,
        artist: file.artist,
      );

      widget.queueService!.addToQueue(queueItem);
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

  QueueItem _offlineItem(DownloadedFile file) => QueueItem.fromDownloadedFile(
        filename: file.filename,
        title: file.title,
        artist: file.artist,
      );

  bool _savedOnDevice(DownloadedFile file) =>
      _offline.tracks.any((track) => track.filename == file.filename);

  bool _savingOnDevice(DownloadedFile file) => _offline.jobs.any((job) =>
      job.track.filename == file.filename &&
      (job.status == OfflineDownloadStatus.queued ||
          job.status == OfflineDownloadStatus.preparing ||
          job.status == OfflineDownloadStatus.downloading));

  Future<void> _saveOnDevice(List<DownloadedFile> files) async {
    final pending = files
        .where((file) => !_savedOnDevice(file) && !_savingOnDevice(file))
        .toList();
    if (pending.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Saving on this device. See Offline library for progress.')));
    try {
      await Future.wait(
          pending.map((file) => _offline.downloadTrack(_offlineItem(file))));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save on this device: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredDownloads = _filteredDownloads;
    final hasDownloads = _downloads.isNotEmpty;
    final hasFilteredResults = filteredDownloads.isNotEmpty;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;

    return Column(
      children: [
        Padding(
          padding: ResponsiveUtils.responsivePadding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GradientSectionHeader(
                title: 'Server files',
                showGradientBar: true,
              ),
              const SizedBox(height: 8),
              const Text(
                  'Music stored on your server. Save songs on this device for offline listening.'),
              if (_offline.isSupported && hasDownloads)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton.icon(
                    onPressed: _offline.isInitialized &&
                            filteredDownloads.any((file) =>
                                !_savedOnDevice(file) && !_savingOnDevice(file))
                        ? () => _saveOnDevice(filteredDownloads)
                        : null,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text(_searchQuery.isEmpty
                        ? 'Save all on this device'
                        : 'Save results on this device'),
                  ),
                ),
              const SizedBox(height: 20),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search your library...',
                  prefixIcon: const Icon(Icons.search, size: 24),
                  suffixIcon:
                      _searchQuery.isNotEmpty && _searchQuery.trim().isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadDownloads,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : !hasDownloads
                    ? EmptyStateWidget(
                        icon: Icons.library_music_outlined,
                        title: 'No downloads yet',
                        subtitle: 'Search and download music to see it here.',
                      )
                    : !hasFilteredResults
                        ? EmptyStateWidget(
                            icon: Icons.search_off,
                            title: 'No results found',
                            subtitle: 'Try a different search term.',
                          )
                        : ListView.separated(
                            padding:
                                ResponsiveUtils.responsiveHorizontalPadding(
                                    context),
                            itemCount: filteredDownloads.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final file = filteredDownloads[index];
                              final isCurrentlyPlaying = widget
                                      .playerStateService.currentTrackUrl
                                      ?.contains(file.filename) ??
                                  false;
                              final trackName =
                                  getDisplayTitle(file.title, file.filename);

                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => _playFile(file),
                                  borderRadius: BorderRadius.circular(12),
                                  hoverColor: surfaceHover.withOpacity(0.5),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      gradient: isCurrentlyPlaying
                                          ? LinearGradient(
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                              colors: [
                                                primaryColor.withOpacity(0.15),
                                                primaryColor.withOpacity(0.06),
                                              ],
                                            )
                                          : null,
                                      color: isCurrentlyPlaying
                                          ? null
                                          : Theme.of(context)
                                              .colorScheme
                                              .surface,
                                      border: isCurrentlyPlaying
                                          ? Border(
                                              left: BorderSide(
                                                  color: primaryColor,
                                                  width: 3),
                                            )
                                          : Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceVariant
                                                  .withOpacity(0.5),
                                              width: 1,
                                            ),
                                    ),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          child: AlbumCover(
                                            filename: file.filename,
                                            title: file.title,
                                            artist: file.artist,
                                            size: ResponsiveUtils
                                                .responsiveIconSize(context,
                                                    base: 48),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                trackName,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyLarge
                                                    ?.copyWith(
                                                      color: isCurrentlyPlaying
                                                          ? primaryColor
                                                          : null,
                                                      fontWeight:
                                                          isCurrentlyPlaying
                                                              ? FontWeight.w600
                                                              : FontWeight.w400,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                file.artist != null &&
                                                        file.artist!.isNotEmpty
                                                    ? file.artist!
                                                    : file.formattedSize,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (MediaQuery.sizeOf(context)
                                                    .width >=
                                                600)
                                              IconButton(
                                                icon: const Icon(
                                                    Icons.playlist_add,
                                                    size: 20),
                                                onPressed: () =>
                                                    _addToPlaylist(file),
                                                tooltip: 'Add to playlist',
                                              ),
                                            if (widget.queueService != null &&
                                                MediaQuery.sizeOf(context)
                                                        .width >=
                                                    600)
                                              IconButton(
                                                icon: const Icon(
                                                    Icons.queue_music,
                                                    size: 20),
                                                onPressed: () =>
                                                    _addToQueue(file),
                                                tooltip: 'Add to queue',
                                              ),
                                            IconButton(
                                              icon: Icon(
                                                Icons.play_arrow,
                                                color: isCurrentlyPlaying
                                                    ? primaryColor
                                                    : null,
                                              ),
                                              onPressed: () => _playFile(file),
                                              tooltip: 'Play',
                                            ),
                                            SaveTrackButton(
                                                track: PlaylistTrack
                                                    .fromDownloadedFile(file),
                                                service: _savedMusic),
                                            if (_offline.isSupported &&
                                                MediaQuery.sizeOf(context)
                                                        .width >=
                                                    600)
                                              IconButton(
                                                icon: Icon(_savedOnDevice(file)
                                                    ? Icons.offline_pin_rounded
                                                    : _savingOnDevice(file)
                                                        ? Icons
                                                            .downloading_rounded
                                                        : Icons
                                                            .download_for_offline_outlined),
                                                tooltip: _savedOnDevice(file)
                                                    ? 'Saved on this device'
                                                    : _savingOnDevice(file)
                                                        ? 'Saving on this device'
                                                        : 'Save on this device',
                                                onPressed: !_offline
                                                            .isInitialized ||
                                                        _savedOnDevice(file) ||
                                                        _savingOnDevice(file)
                                                    ? null
                                                    : () =>
                                                        _saveOnDevice([file]),
                                              ),
                                            if (MediaQuery.sizeOf(context)
                                                    .width <
                                                600)
                                              PopupMenuButton<String>(
                                                tooltip: 'More song actions',
                                                onSelected: (value) {
                                                  switch (value) {
                                                    case 'playlist':
                                                      _addToPlaylist(file);
                                                    case 'queue':
                                                      _addToQueue(file);
                                                    case 'delete':
                                                      _deleteFile(file);
                                                    case 'offline':
                                                      _saveOnDevice([file]);
                                                  }
                                                },
                                                itemBuilder: (_) => [
                                                  if (_offline.isSupported)
                                                    PopupMenuItem(
                                                      value: 'offline',
                                                      enabled: _offline
                                                              .isInitialized &&
                                                          !_savedOnDevice(
                                                              file) &&
                                                          !_savingOnDevice(
                                                              file),
                                                      child: Text(_savedOnDevice(
                                                              file)
                                                          ? 'Saved on this device'
                                                          : _savingOnDevice(
                                                                  file)
                                                              ? 'Saving on this device'
                                                              : 'Save on this device'),
                                                    ),
                                                  const PopupMenuItem(
                                                      value: 'playlist',
                                                      child: Text(
                                                          'Add to playlist')),
                                                  if (widget.queueService !=
                                                      null)
                                                    const PopupMenuItem(
                                                        value: 'queue',
                                                        child: Text(
                                                            'Add to queue')),
                                                  const PopupMenuItem(
                                                      value: 'delete',
                                                      child: Text(
                                                          'Delete server copy')),
                                                ],
                                              ),
                                            if (MediaQuery.sizeOf(context)
                                                    .width >=
                                                600)
                                              IconButton(
                                                icon: const Icon(
                                                    Icons.delete_outline,
                                                    size: 20),
                                                onPressed: () =>
                                                    _deleteFile(file),
                                                tooltip: 'Delete',
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
        ),
      ],
    );
  }
}
