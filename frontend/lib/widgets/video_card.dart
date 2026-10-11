import '../services/auth_http_client.dart';
import 'package:flutter/material.dart';
import '../models/playlist.dart';
import 'save_track_button.dart';
import '../services/api_service.dart';
import '../utils/responsive_utils.dart';

class VideoCard extends StatelessWidget {
  final VideoInfo video;
  final VoidCallback? onStream;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onTap;
  final bool isSelected;

  const VideoCard({
    super.key,
    required this.video,
    this.onStream,
    this.onDownload,
    this.onAddToPlaylist,
    this.onAddToQueue,
    this.onTap,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;
    final isDownloaded = video.filename?.isNotEmpty ?? false;

    return Card(
      color: isSelected ? primaryColor.withOpacity(0.1) : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap ?? onStream ?? () {},
          borderRadius: BorderRadius.circular(12),
          hoverColor: surfaceHover,
          child: Padding(
            padding: ResponsiveUtils.responsivePadding(context),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    AuthHttpClient.shared.cacheScopedUrl(video.thumbnail),
                    headers: AuthHttpClient.shared
                        .authHeadersForUrl(video.thumbnail),
                    width: ResponsiveUtils.responsiveMediumIconSize(context,
                        base: 80),
                    height: ResponsiveUtils.responsiveMediumIconSize(context,
                        base: 80),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      final size = ResponsiveUtils.responsiveMediumIconSize(
                          context,
                          base: 80);
                      return Container(
                        width: size,
                        height: size,
                        color: surfaceHover,
                        child: Icon(
                          Icons.music_note,
                          color: primaryColor,
                          size: 32,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        video.uploader,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.5),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            video.formattedDuration,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SaveTrackButton(track: PlaylistTrack.fromVideoInfo(video)),
                    if (MediaQuery.sizeOf(context).width < 600)
                      PopupMenuButton<String>(
                        tooltip: 'More song actions',
                        onSelected: (value) {
                          switch (value) {
                            case 'queue':
                              onAddToQueue?.call();
                            case 'playlist':
                              onAddToPlaylist?.call();
                            case 'download':
                              onDownload?.call();
                          }
                        },
                        itemBuilder: (_) => [
                          if (onAddToQueue != null)
                            const PopupMenuItem(
                                value: 'queue', child: Text('Add to queue')),
                          if (onAddToPlaylist != null)
                            const PopupMenuItem(
                                value: 'playlist',
                                child: Text('Add to playlist')),
                          if (onDownload != null)
                            PopupMenuItem(
                                value: 'download',
                                enabled: !isDownloaded,
                                child: Text(
                                    isDownloaded ? 'Downloaded' : 'Download')),
                        ],
                      ),
                    if (MediaQuery.sizeOf(context).width >= 600 &&
                        onAddToQueue != null)
                      IconButton(
                        icon: const Icon(Icons.queue_music, size: 20),
                        onPressed: onAddToQueue,
                        tooltip: 'Add to queue',
                      ),
                    if (MediaQuery.sizeOf(context).width >= 600 &&
                        onAddToPlaylist != null)
                      IconButton(
                        icon: const Icon(Icons.playlist_add, size: 20),
                        onPressed: onAddToPlaylist,
                        tooltip: 'Add to playlist',
                      ),
                    if (MediaQuery.sizeOf(context).width >= 600 &&
                        onDownload != null)
                      IconButton(
                        icon: Icon(
                            isDownloaded
                                ? Icons.download_done
                                : Icons.download_outlined,
                            size: 20),
                        onPressed: isDownloaded ? null : onDownload,
                        tooltip: isDownloaded ? 'Downloaded' : 'Download',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
