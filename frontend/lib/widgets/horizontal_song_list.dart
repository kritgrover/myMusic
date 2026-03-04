import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../services/api_service.dart'; // For VideoInfo
import 'video_card.dart';

class HorizontalSongList extends StatelessWidget {
  final String title;
  final List<VideoInfo> songs;
  final Function(VideoInfo) onPlay;
  final Function(VideoInfo) onAddToQueue;
  final VoidCallback? onShowAll;
  final int maxItems;

  const HorizontalSongList({
    super.key,
    required this.title,
    required this.songs,
    required this.onPlay,
    required this.onAddToQueue,
    this.onShowAll,
    this.maxItems = 8,
  });

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();

    final displayedSongs = songs.length > maxItems ? songs.sublist(0, maxItems) : songs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            right: ResponsiveUtils.responsiveValue<double>(context, compact: 12, medium: 20, expanded: 24),
            top: 8,
            bottom: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onShowAll != null && songs.length > maxItems)
                TextButton(
                  onPressed: onShowAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Show All',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_forward,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
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
              final cardWidth = ResponsiveUtils.responsiveHorizontalCardWidth(context);
              return SizedBox(
                width: cardWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Square thumbnail with play button overlay
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            song.thumbnail,
                            width: cardWidth,
                            height: cardWidth,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: cardWidth,
                                height: cardWidth,
                                color: Colors.grey[800],
                                child: const Icon(Icons.music_note, size: 48),
                              );
                            },
                          ),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => onPlay(song),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.4),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      song.uploader, // Artist
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

