import 'package:flutter/material.dart';
import '../services/queue_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';

const Color neonBlue = Color(0xFF00D9FF);

class QueuePanel extends StatelessWidget {
  final QueueService queueService;
  final VoidCallback onClose;
  final Function(QueueItem)? onItemTap;

  const QueuePanel({
    super.key,
    required this.queueService,
    required this.onClose,
    this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(
          left: BorderSide(color: neonBlue, width: 1),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: neonBlue.withOpacity(0.3), width: 1),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.queue_music, color: neonBlue),
                    const SizedBox(width: 8),
                    Text(
                      'Queue (${queueService.queueLength})',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          // Queue list
          Expanded(
            child: ListenableBuilder(
              listenable: queueService,
              builder: (context, _) {
                if (queueService.queue.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.queue_music,
                          size: 64,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Queue is empty',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add songs to queue to see them here',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: queueService.queue.length,
                  itemBuilder: (context, index) {
                    final item = queueService.queue[index];
                    final isCurrent = index == queueService.currentIndex;

                    return Material(
                      color: isCurrent 
                          ? neonBlue.withOpacity(0.15) 
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          if (onItemTap != null) {
                            onItemTap!(item);
                          }
                        },
                        hoverColor: neonBlue.withOpacity(0.1),
                        child: ListTile(
                          leading: Icon(
                            Icons.music_note,
                            color: isCurrent ? neonBlue : Colors.grey[400],
                          ),
                          title: Text(
                            getDisplayTitle(item.title, item.filename),
                            style: TextStyle(
                              color: isCurrent ? neonBlue : null,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: item.artist != null && item.artist!.isNotEmpty
                              ? Text(
                                  item.artist!,
                                  style: TextStyle(
                                    color: isCurrent 
                                        ? neonBlue.withOpacity(0.8) 
                                        : Colors.grey[400],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCurrent)
                                Icon(
                                  Icons.play_arrow,
                                  color: neonBlue,
                                  size: 20,
                                ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  queueService.removeFromQueue(index);
                                },
                                tooltip: 'Remove from queue',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Footer with clear button
          if (queueService.queue.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: neonBlue.withOpacity(0.3), width: 1),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    queueService.clearQueue();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: neonBlue,
                    side: const BorderSide(color: neonBlue),
                  ),
                  child: const Text('Clear Queue'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

