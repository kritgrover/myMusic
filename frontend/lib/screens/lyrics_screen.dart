import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/lyrics_service.dart';
import '../models/lyrics.dart';

class LyricsScreen extends StatefulWidget {
  final String trackName;
  final String artistName;
  final String? albumName;
  final int? duration;
  final LyricsService lyricsService;
  final bool embedded; // If true, don't show Scaffold/AppBar
  final VoidCallback? onBack; // Callback for back button when embedded

  const LyricsScreen({
    super.key,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    required this.lyricsService,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  @override
  void initState() {
    super.initState();
    // Fetch lyrics when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchLyrics();
    });
  }

  Future<void> _fetchLyrics() async {
    await widget.lyricsService.fetchLyrics(
      widget.trackName,
      widget.artistName,
      albumName: widget.albumName,
      duration: widget.duration,
    );
  }

  Widget _buildContent() {
    return ListenableBuilder(
        listenable: widget.lyricsService,
        builder: (context, _) {
          if (widget.lyricsService.isLoading) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (widget.lyricsService.error != null) {
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
                      widget.lyricsService.error!,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _fetchLyrics,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final lyrics = widget.lyricsService.currentLyrics;
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

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Track info header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lyrics.trackName,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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
                  ],
                ),
              ),
              const Divider(height: 1),
              // Lyrics content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      lyrics.plainLyrics ?? '',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontSize: (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * 2,
                            height: 1.8,
                            letterSpacing: 0.3,
                          ),
                      textAlign: TextAlign.left,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with back button
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Lyrics',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchLyrics,
                  tooltip: 'Refresh lyrics',
                ),
              ],
            ),
          ),
          Expanded(child: _buildContent()),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lyrics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchLyrics,
            tooltip: 'Refresh lyrics',
          ),
        ],
      ),
      body: _buildContent(),
    );
  }
}
