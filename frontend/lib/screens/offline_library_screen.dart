import 'package:flutter/material.dart';
import '../models/queue_item.dart';
import '../services/offline_download_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../utils/responsive_utils.dart';
import '../widgets/offline_artwork.dart';

/// The device's verified files, independent of the server's download list.
class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({
    super.key,
    required this.playerStateService,
    this.queueService,
    this.offlineService,
    this.onRetryInitialization,
  });

  final PlayerStateService playerStateService;
  final QueueService? queueService;
  final OfflineDownloadService? offlineService;
  final Future<void> Function()? onRetryInitialization;

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  final _search = TextEditingController();
  String? _playlistId;
  String _query = '';

  OfflineDownloadService get _offline =>
      widget.offlineService ?? OfflineDownloadService.shared;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _play(List<OfflineTrack> tracks, {int startIndex = 0}) async {
    try {
      final items = <QueueItem>[];
      for (final track in tracks) {
        final local = await _offline.localQueueItemFor(track.toQueueItem());
        if (local == null) {
          throw StateError('A saved file is unavailable. Download it again.');
        }
        items.add(local);
      }
      if (items.isEmpty) return;
      final queue = widget.queueService;
      if (queue != null) {
        queue.clearQueue();
        queue.addAllToQueue(items, isPlaylistQueue: _playlistId != null);
        await queue.playItem(startIndex, widget.playerStateService);
      } else {
        final item = items[startIndex];
        await widget.playerStateService.playTrack(
          item.filename!,
          trackName: item.title,
          trackArtist: item.artist,
          album: item.album,
          duration: item.duration,
          spotifyId: item.spotifyId,
          url: item.originalUrl,
        );
      }
    } catch (error) {
      _message('Could not play saved music: $error');
    }
  }

  Future<void> _remove(OfflineTrack track) async {
    try {
      await _offline.remove(track.id);
      _message('Removed from this device. Your server library is unchanged.');
    } catch (error) {
      _message('Could not remove local copy: $error');
    }
  }

  Future<void> _retry(OfflineDownloadJob job) async {
    try {
      await _offline.retry(job.id);
    } catch (error) {
      _message('Could not retry download: $error');
    }
  }

  String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([_offline, widget.playerStateService]),
        builder: (context, _) => _buildLibrary(context),
      );

  Widget _buildLibrary(BuildContext context) {
    if (!_offline.isSupported) {
      return _empty(
        context,
        Icons.devices_outlined,
        'Offline listening is available in the app',
        'Use the native app to save music on this device. '
            'Your browser library plays music from the server.',
      );
    }
    if (!_offline.isInitialized) {
      if (_offline.lastError != null) {
        return SingleChildScrollView(
          child: Column(children: [
            _empty(context, Icons.folder_off_outlined,
                'Could not open offline library', _offline.lastError!),
            if (widget.onRetryInitialization != null)
              OutlinedButton.icon(
                onPressed: widget.onRetryInitialization,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
          ]),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final tracks = _offline.tracks;
    final playlists = <String, String>{};
    for (final track in tracks) {
      playlists.addAll(track.playlists);
    }
    final selectedPlaylist =
        playlists.containsKey(_playlistId) ? _playlistId : null;
    final visible = tracks.where((track) {
      if (selectedPlaylist != null &&
          !track.playlists.containsKey(selectedPlaylist)) {
        return false;
      }
      return _query.isEmpty ||
          [track.title, track.artist, track.album]
              .whereType<String>()
              .any((value) => value.toLowerCase().contains(_query));
    }).toList();
    if (selectedPlaylist != null) {
      visible.sort((a, b) => (a.playlistPositions[selectedPlaylist] ?? 0)
          .compareTo(b.playlistPositions[selectedPlaylist] ?? 0));
    }
    final jobs = _offline.jobs
        .where((job) => job.status != OfflineDownloadStatus.complete)
        .toList();
    final colors = Theme.of(context).colorScheme;
    final padding = ResponsiveUtils.responsiveHorizontalPadding(context);

    return CustomScrollView(
      key: const PageStorageKey('offline-library-scroll'),
      slivers: [
        SliverPadding(
          padding: ResponsiveUtils.responsivePadding(context),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.offline_pin_rounded,
                        color: colors.primary, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Offline library',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'} saved on this device · ${_bytes(_offline.totalBytes)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                const Text('Ready to play without an internet connection.'),
                const SizedBox(height: 20),
                TextField(
                  controller: _search,
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search saved songs, artists or albums',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear offline search',
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                if (playlists.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      ChoiceChip(
                        label: const Text('All songs'),
                        selected: selectedPlaylist == null,
                        onSelected: (_) => setState(() => _playlistId = null),
                      ),
                      for (final entry in playlists.entries) ...[
                        const SizedBox(width: 8),
                        ChoiceChip(
                          avatar: const Icon(Icons.playlist_play, size: 18),
                          label: Text(entry.value),
                          selected: selectedPlaylist == entry.key,
                          onSelected: (_) =>
                              setState(() => _playlistId = entry.key),
                        ),
                      ],
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: visible.isEmpty ? null : () => _play(visible),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(_query.isEmpty ? 'Play all' : 'Play results'),
                ),
                if (_offline.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(_offline.lastError!,
                      style: TextStyle(color: colors.error)),
                ],
                if (jobs.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Downloads',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ],
            ),
          ),
        ),
        if (jobs.isNotEmpty)
          SliverPadding(
            padding: padding,
            sliver: SliverList.builder(
              itemCount: jobs.length,
              itemBuilder: (context, index) => _jobCard(context, jobs[index]),
            ),
          ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: _empty(
                context,
                Icons.download_for_offline_outlined,
                'Take your music with you',
                'Choose “Save on this device” in Server files, or '
                    '“Download for offline” in a playlist. Completed songs appear here.'),
          )
        else if (visible.isEmpty)
          SliverToBoxAdapter(
            child: _empty(context, Icons.search_off, 'No saved songs found',
                'Try another title, artist or album, or select a different playlist.'),
          )
        else
          SliverPadding(
            padding: padding.add(const EdgeInsets.only(top: 8, bottom: 24)),
            sliver: SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) => _trackRow(context,
                  visible[index], () => _play(visible, startIndex: index)),
            ),
          ),
      ],
    );
  }

  Widget _empty(
          BuildContext context, IconData icon, String title, String subtitle) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 52, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(subtitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      );

  Widget _jobCard(BuildContext context, OfflineDownloadJob job) {
    final canRetry = job.status == OfflineDownloadStatus.failed ||
        job.status == OfflineDownloadStatus.cancelled;
    final label = switch (job.status) {
      OfflineDownloadStatus.queued => 'Queued',
      OfflineDownloadStatus.preparing => 'Preparing audio',
      OfflineDownloadStatus.downloading => job.progress == null
          ? 'Saving on this device'
          : 'Saving on this device · ${(job.progress! * 100).round()}%',
      OfflineDownloadStatus.failed => 'Download failed',
      OfflineDownloadStatus.cancelled => 'Cancelled',
      OfflineDownloadStatus.complete => 'Saved on this device',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(job.track.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                  ])),
              if (canRetry)
                TextButton(
                    onPressed: () => _retry(job), child: const Text('Retry'))
              else
                IconButton(
                  tooltip: 'Cancel download',
                  onPressed: () => _offline.cancel(job.id),
                  icon: const Icon(Icons.close),
                ),
            ]),
            if (!canRetry) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: job.progress?.clamp(0.0, 1.0)),
            ],
            if (job.error != null &&
                job.status == OfflineDownloadStatus.failed) ...[
              const SizedBox(height: 4),
              Text(job.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _trackRow(
      BuildContext context, OfflineTrack track, VoidCallback play) {
    final currentUrl = widget.playerStateService.currentTrackUrl;
    final playing = currentUrl != null &&
        (Uri.tryParse(currentUrl)?.path.endsWith('/${track.filename}') ??
            false);
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: playing ? colors.primaryContainer : null,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: OfflineArtwork(localArtworkUrl: track.localArtworkUrl),
        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              [track.artist, track.album]
                  .whereType<String>()
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text('${_bytes(track.bytes)} · Saved on this device',
              style: Theme.of(context).textTheme.labelSmall),
        ]),
        onTap: play,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
              tooltip: 'Play ${track.title}',
              onPressed: play,
              icon: Icon(playing
                  ? Icons.equalizer_rounded
                  : Icons.play_arrow_rounded)),
          PopupMenuButton<String>(
            tooltip: 'Options for ${track.title}',
            onSelected: (_) => _remove(track),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'remove', child: Text('Remove from this device')),
            ],
          ),
        ]),
      ),
    );
  }
}
