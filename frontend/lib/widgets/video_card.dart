import 'package:flutter/material.dart';
import '../services/api_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

class VideoCard extends StatelessWidget {
  final VideoInfo video;
  final VoidCallback onStream;
  final VoidCallback onDownload;

  const VideoCard({
    super.key,
    required this.video,
    required this.onStream,
    required this.onDownload,
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
          trailing: IconButton(
            icon: const Icon(Icons.download),
            onPressed: onDownload,
            tooltip: 'Download',
          ),
          isThreeLine: true,
        ),
      ),
    );
  }
}


