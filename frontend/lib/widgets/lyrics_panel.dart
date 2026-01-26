import 'package:flutter/material.dart';
import '../services/lyrics_service.dart';
import '../models/lyrics.dart';

class LyricsPanel extends StatelessWidget {
  final LyricsService lyricsService;
  final String trackName;
  final String artistName;
  final String? albumName;
  final VoidCallback onClose;

  const LyricsPanel({
    super.key,
    required this.lyricsService,
    required this.trackName,
    required this.artistName,
    this.albumName,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
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
                    Icon(Icons.mic, color: primaryColor, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Lyrics',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          if (trackName.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              trackName,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: () {
                        lyricsService.fetchLyrics(
                          trackName,
                          artistName,
                          albumName: albumName,
                        );
                      },
                      tooltip: 'Refresh lyrics',
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: onClose,
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Lyrics content
          Expanded(
            child: ListenableBuilder(
              listenable: lyricsService,
              builder: (context, _) {
                if (lyricsService.isLoading) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                if (lyricsService.error != null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.music_off,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            lyricsService.error!,
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: () {
                              lyricsService.fetchLyrics(
                                trackName,
                                artistName,
                                albumName: albumName,
                              );
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('Try Again'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final lyrics = lyricsService.currentLyrics;
                if (lyrics == null || !lyrics.hasLyrics) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.mic_off,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No lyrics available',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            lyrics?.instrumental == true
                                ? 'This track appears to be instrumental'
                                : 'Lyrics not found for this track',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Track info
                      Text(
                        lyrics.trackName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lyrics.artistName,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                            ),
                      ),
                      if (lyrics.albumName != null && lyrics.albumName!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          lyrics.albumName!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                              ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 24),
                      // Lyrics text
                      SelectableText(
                        lyrics.plainLyrics ?? '',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              height: 1.8,
                              letterSpacing: 0.3,
                            ),
                        textAlign: TextAlign.left,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
