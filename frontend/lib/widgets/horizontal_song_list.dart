import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/api_service.dart'; // For VideoInfo
import 'section_header.dart';

class HorizontalSongList extends StatelessWidget {
  final String title;
  final List<VideoInfo> songs;
  final Function(VideoInfo) onPlay;
  final Function(VideoInfo) onAddToQueue;
  final Function(VideoInfo)? onDownload;
  final Function(VideoInfo)? onAddToPlaylist;
  final VoidCallback? onShowAll;
  final int maxItems;

  const HorizontalSongList({
    super.key,
    required this.title,
    required this.songs,
    required this.onPlay,
    required this.onAddToQueue,
    this.onDownload,
    this.onAddToPlaylist,
    this.onShowAll,
    this.maxItems = 8,
  });

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();

    final displayedSongs = songs.length > maxItems ? songs.sublist(0, maxItems) : songs;
    final showAll = (onShowAll != null && songs.length > maxItems) ? onShowAll : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title, onShowAll: showAll),
        SizedBox(
          height: ResponsiveUtils.responsiveHorizontalListHeight(context),
          child: ListView.separated(
            padding: ResponsiveUtils.responsiveHorizontalPadding(context),
            scrollDirection: Axis.horizontal,
            itemCount: displayedSongs.length,
            separatorBuilder: (context, index) => SizedBox(
              width: ResponsiveUtils.responsiveValue<double>(context, compact: 16, medium: 20, expanded: 24),
            ),
            itemBuilder: (context, index) {
              final song = displayedSongs[index];
              return _SongCard(
                song: song,
                width: ResponsiveUtils.responsiveHorizontalCardWidth(context),
                onPlay: () => onPlay(song),
                onDownload: onDownload != null ? () => onDownload!(song) : null,
                onAddToPlaylist: onAddToPlaylist != null ? () => onAddToPlaylist!(song) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A single square song card with a hover-revealed indigo play button, bold title
/// and muted subtitle. Inline download / add-to-playlist actions are preserved.
class _SongCard extends StatefulWidget {
  final VideoInfo song;
  final double width;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;

  const _SongCard({
    required this.song,
    required this.width,
    required this.onPlay,
    this.onDownload,
    this.onAddToPlaylist,
  });

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hasActions = widget.onDownload != null || widget.onAddToPlaylist != null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPlay,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            widget.song.thumbnail,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                color: Theme.of(context).colorScheme.surfaceVariant,
                                child: const Icon(Icons.music_note, size: 40),
                              );
                            },
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: _hover ? 1 : 0,
                          child: _PlayFab(onTap: widget.onPlay),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                widget.song.uploader,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (hasActions) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onDownload != null)
                      IconButton(
                        icon: const Icon(Icons.download, size: 18),
                        onPressed: widget.onDownload,
                        tooltip: 'Download',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      ),
                    if (widget.onAddToPlaylist != null)
                      IconButton(
                        icon: const Icon(Icons.playlist_add, size: 18),
                        onPressed: widget.onAddToPlaylist,
                        tooltip: 'Add to playlist',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The signature circular play button (indigo accent) shown on card hover.
class _PlayFab extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.play_arrow, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
