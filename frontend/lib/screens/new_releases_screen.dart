import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';

class NewReleasesScreen extends StatelessWidget {
  final List<Map<String, dynamic>> releases;
  final VoidCallback? onBack;
  final Future<void> Function(String albumId, String albumName, String artist)? onPlayAlbum;

  const NewReleasesScreen({
    super.key,
    required this.releases,
    this.onBack,
    this.onPlayAlbum,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: ResponsiveUtils.responsivePadding(context),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack ?? () => Navigator.of(context).pop(),
                tooltip: 'Back',
              ),
              const SizedBox(width: 8),
              Text(
                'New Releases',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (releases.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.album_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No new releases from your artists yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Keep listening to discover new releases',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: GridView.builder(
              padding: ResponsiveUtils.responsiveHorizontalPadding(context).copyWith(
                bottom: ResponsiveUtils.responsivePlayerBottomPadding(context),
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: ResponsiveUtils.responsiveValue<int>(
                  context,
                  compact: 2,
                  medium: 3,
                  expanded: 4,
                ),
                crossAxisSpacing: ResponsiveUtils.responsiveValue<double>(
                  context,
                  compact: 12,
                  medium: 16,
                  expanded: 20,
                ),
                mainAxisSpacing: ResponsiveUtils.responsiveValue<double>(
                  context,
                  compact: 16,
                  medium: 20,
                  expanded: 24,
                ),
                childAspectRatio: 0.75,
              ),
              itemCount: releases.length,
              itemBuilder: (context, index) {
                final release = releases[index];
                final name = release['name'] as String? ?? '';
                final artist = release['artist'] as String? ?? '';
                final type = release['type'] as String? ?? 'album';
                final releaseDate = release['release_date'] as String? ?? '';
                final thumbnail = release['thumbnail'] as String?;
                final albumId = release['id'] as String? ?? '';

                return LayoutBuilder(
                  builder: (context, constraints) {
                    final cardSize = constraints.maxWidth;
                    return GestureDetector(
                  onTap: () => onPlayAlbum?.call(albumId, name, artist),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: thumbnail != null && thumbnail.isNotEmpty
                            ? Image.network(
                                thumbnail,
                                width: cardSize,
                                height: cardSize,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return _buildPlaceholder(context, cardSize);
                                },
                              )
                            : _buildPlaceholder(context, cardSize),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (releaseDate.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              type == 'single' ? 'Single' : 'Album',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            Text(
                              ' • $releaseDate',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildPlaceholder(BuildContext context, double size) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(
        Icons.album,
        size: 48,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
