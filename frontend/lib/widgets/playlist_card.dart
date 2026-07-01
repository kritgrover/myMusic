import 'package:flutter/material.dart';
import '../models/discovery.dart';

/// A square playlist tile (cover + name + owner) used in curated/mood rows.
/// Tapping opens the existing SpotifyPlaylistScreen for the tracklist. On hover
/// (desktop) an indigo play button reveals in the cover's bottom-right corner.
class PlaylistCard extends StatefulWidget {
  final SpotifyPlaylistInfo playlist;
  final VoidCallback onTap;

  const PlaylistCard({super.key, required this.playlist, required this.onTap});

  @override
  State<PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<PlaylistCard> {
  bool _hover = false;

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.queue_music,
        size: 40,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final hasThumb = playlist.thumbnail != null && playlist.thumbnail!.isNotEmpty;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: hasThumb
                          ? Image.network(
                              playlist.thumbnail!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _placeholder(context),
                            )
                          : _placeholder(context),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: _hover ? 1 : 0,
                      child: Material(
                        color: Theme.of(context).colorScheme.primary,
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.play_arrow, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if ((playlist.owner ?? '').isNotEmpty)
              Text(
                'By ${playlist.owner}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
