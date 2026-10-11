import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/queue_service.dart';
import '../models/queue_item.dart';
import '../utils/song_display_utils.dart';
import 'album_cover.dart';

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
    final theme = Theme.of(context);
    return Container(
      width: ResponsiveUtils.responsivePanelWidth(context),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: ListenableBuilder(
        listenable: queueService,
        builder: (context, _) {
          final queue = queueService.queue;
          final firstUpcoming = queueService.currentIndex + 1;
          final current = queueService.currentItem;
          final upcomingCount = queueService.upcomingCount;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(children: [
                  Expanded(
                      child: Text('Queue', style: theme.textTheme.titleLarge)),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                    tooltip: 'Close queue',
                  ),
                ]),
              ),
              Expanded(
                child: queue.isEmpty
                    ? Center(
                        child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.queue_music,
                                size: 56,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(height: 16),
                            Text('Your queue is empty',
                                style: theme.textTheme.titleMedium),
                            const SizedBox(height: 8),
                            const Text('Add songs to keep the music going.',
                                textAlign: TextAlign.center),
                          ],
                        ),
                      ))
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                        buildDefaultDragHandles: false,
                        itemCount: upcomingCount,
                        onReorder: (oldIndex, newIndex) =>
                            queueService.reorderQueue(
                          oldIndex + firstUpcoming,
                          newIndex + firstUpcoming,
                        ),
                        header: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (current != null) ...[
                              _sectionTitle(context, 'Now playing'),
                              _trackRow(
                                  context, current, queueService.currentIndex,
                                  isCurrent: true),
                            ],
                            _sectionTitle(context, 'Next up · $upcomingCount'),
                            if (upcomingCount == 0)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 20),
                                child: Text(switch (queueService.loopMode) {
                                  LoopMode.queue =>
                                    'The queue will repeat when this track ends.',
                                  LoopMode.single => 'This track will repeat.',
                                  LoopMode.none =>
                                    'Nothing queued next. Add a song or turn on repeat.',
                                }),
                              ),
                          ],
                        ),
                        itemBuilder: (context, index) {
                          final queueIndex = index + firstUpcoming;
                          return KeyedSubtree(
                            key: ValueKey(queueService.entryKeyAt(queueIndex)),
                            child: _trackRow(
                                context, queue[queueIndex], queueIndex,
                                dragIndex: index),
                          );
                        },
                      ),
              ),
              if (upcomingCount > 0)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton(
                    onPressed: queueService.clearUpcoming,
                    child: const Text('Clear upcoming'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 10),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                )),
      );

  Widget _trackRow(
    BuildContext context,
    QueueItem item,
    int index, {
    bool isCurrent = false,
    int? dragIndex,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Material(
      color: isCurrent ? primary.withValues(alpha: 0.1) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 12, right: 0),
        selected: isCurrent,
        selectedColor: primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: onItemTap == null ? null : () => onItemTap!(item),
        leading: AlbumCover(
          filename: item.filename,
          title: item.title,
          artist: item.artist,
          album: item.album,
          artworkUrl: item.thumbnail,
          size: 40,
          onArtworkResolved: (url) {
            final itemIndex = queueService.queue.indexOf(item);
            if (itemIndex >= 0 && item.thumbnail != url) {
              queueService.updateItemAt(itemIndex, item.copyWithThumbnail(url));
            }
          },
        ),
        title: Text(getDisplayTitle(item.title, item.filename),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: item.artist == null || item.artist!.isEmpty
            ? null
            : Text(item.artist!, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: isCurrent
            ? Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Icon(Icons.equalizer,
                    color: primary, semanticLabel: 'Now playing'),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove from queue',
                    onPressed: () => queueService.removeFromQueue(index),
                  ),
                  if (dragIndex != null)
                    ReorderableDragStartListener(
                      index: dragIndex,
                      child: const Tooltip(
                        message: 'Drag to reorder',
                        child: Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                          child: Icon(Icons.drag_handle, size: 20),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
