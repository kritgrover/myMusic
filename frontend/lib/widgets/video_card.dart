import 'package:flutter/material.dart';
import '../services/api_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onStream,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              video.thumbnail,
              width: 80,
              height: 80,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 80,
                  height: 80,
                  color: Colors.grey[900],
                  child: const Icon(Icons.music_note, color: neonBlue),
                );
              },
            ),
          ),
          title: Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                video.uploader,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                video.formattedDuration,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onAddToQueue != null)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onAddToQueue,
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.more_vert),
                          onPressed: onAddToQueue,
                          tooltip: 'Add to queue',
                        ),
                        Positioned(
                          right: 8,
                          top: 8,
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: neonBlue,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.add,
                                size: 12,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (onAddToPlaylist != null)
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: onAddToPlaylist,
                  tooltip: 'Add to playlist',
                ),
              IconButton(
                icon: const Icon(Icons.download),
                onPressed: onDownload,
                tooltip: 'Download',
              ),
            ],
          ),
          isThreeLine: true,
        ),
      ),
    );
  }
}


