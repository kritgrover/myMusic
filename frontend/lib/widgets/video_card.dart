import 'package:flutter/material.dart';
import '../services/api_service.dart';

class VideoCard extends StatelessWidget {
  final VideoInfo video;
  final VoidCallback onStream;
  final VoidCallback onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onAddToQueue;

  const VideoCard({
    super.key,
    required this.video,
    required this.onStream,
    required this.onDownload,
    this.onAddToPlaylist,
    this.onAddToQueue,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;
    
    return Card(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onStream,
          borderRadius: BorderRadius.circular(12),
          hoverColor: surfaceHover,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    video.thumbnail,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 80,
                        height: 80,
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
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
                    if (onAddToQueue != null)
                      IconButton(
                        icon: const Icon(Icons.queue_music, size: 20),
                        onPressed: onAddToQueue,
                        tooltip: 'Add to queue',
                      ),
                    if (onAddToPlaylist != null)
                      IconButton(
                        icon: const Icon(Icons.playlist_add, size: 20),
                        onPressed: onAddToPlaylist,
                        tooltip: 'Add to playlist',
                      ),
                    IconButton(
                      icon: const Icon(Icons.download_outlined, size: 20),
                      onPressed: onDownload,
                      tooltip: 'Download',
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


