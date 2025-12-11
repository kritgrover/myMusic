import 'package:flutter/material.dart';
import '../services/queue_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';

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
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;
    final dividerColor = Theme.of(context).dividerColor;
    
    return Container(
      width: 400,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          left: BorderSide(color: dividerColor, width: 1),
        ),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: dividerColor, width: 1),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.queue_music, color: primaryColor, size: 24),
                    const SizedBox(width: 12),
                    Text(
                      'Queue',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${queueService.queueLength}',
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
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
                          Icons.queue_music_outlined,
                          size: 64,
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Queue is empty',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add songs to queue to see them here',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: queueService.queue.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = queueService.queue[index];
                    final isCurrent = index == queueService.currentIndex;

                    return Material(
                      color: isCurrent 
                          ? primaryColor.withOpacity(0.1) 
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () {
                          if (onItemTap != null) {
                            onItemTap!(item);
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        hoverColor: surfaceHover,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isCurrent 
                                      ? primaryColor.withOpacity(0.2)
                                      : surfaceHover,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.music_note,
                                  color: isCurrent ? primaryColor : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      getDisplayTitle(item.title, item.filename),
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: isCurrent ? primaryColor : null,
                                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (item.artist != null && item.artist!.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        item.artist!,
                                        style: Theme.of(context).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
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
                  top: BorderSide(color: dividerColor, width: 1),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    queueService.clearQueue();
                  },
                  child: const Text('Clear Queue'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

