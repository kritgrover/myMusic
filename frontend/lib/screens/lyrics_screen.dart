import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../services/lyrics_service.dart';
import '../services/player_state_service.dart';
import '../models/lyrics.dart';

class LyricsScreen extends StatefulWidget {
  final String trackName;
  final String artistName;
  final String? albumName;
  final int? duration;
  final LyricsService lyricsService;
  final PlayerStateService? playerStateService; // Optional for syncing
  final bool embedded; // If true, don't show Scaffold/AppBar
  final VoidCallback? onBack; // Callback for back button when embedded

  const LyricsScreen({
    super.key,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    required this.lyricsService,
    this.playerStateService,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

// LRC line with timestamp
class LrcLine {
  final Duration timestamp;
  final String text;

  LrcLine(this.timestamp, this.text);
}

class _LyricsScreenState extends State<LyricsScreen> {
  StreamSubscription<Duration>? _positionSubscription;
  Duration _currentPosition = Duration.zero;
  final ScrollController _scrollController = ScrollController();
  int _highlightedLineIndex = -1;
  List<LrcLine> _syncedLines = [];
  List<String> _plainLines = [];

  @override
  void initState() {
    super.initState();
    // Fetch lyrics when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchLyrics();
    });
    
    // Listen to position stream if player service is available
    if (widget.playerStateService != null) {
      _positionSubscription = widget.playerStateService!.audioPlayer.positionStream.listen((position) {
        if (mounted) {
          setState(() {
            _currentPosition = position;
            _updateHighlightedLine();
          });
        }
      });
    }
    
    // Listen to lyrics service changes to re-parse when lyrics are fetched
    widget.lyricsService.addListener(_onLyricsChanged);
  }

  void _onLyricsChanged() {
    if (mounted) {
      _parseLyrics();
      setState(() {
        _highlightedLineIndex = -1; // Reset highlight
      });
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    widget.lyricsService.removeListener(_onLyricsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchLyrics() async {
    await widget.lyricsService.fetchLyrics(
      widget.trackName,
      widget.artistName,
      albumName: widget.albumName,
      duration: widget.duration,
    );
    
    // Parse lyrics after fetching
    if (mounted) {
      _parseLyrics();
    }
  }

  void _parseLyrics() {
    final lyrics = widget.lyricsService.currentLyrics;
    if (lyrics == null) return;

    // Try to parse synced lyrics first
    if (lyrics.hasSyncedLyrics && lyrics.syncedLyrics != null) {
      _syncedLines = _parseLrc(lyrics.syncedLyrics!);
      if (_syncedLines.isNotEmpty) {
        return; // Use synced lyrics
      }
    }

    // Fall back to plain lyrics, split by lines
    if (lyrics.plainLyrics != null && lyrics.plainLyrics!.isNotEmpty) {
      _plainLines = lyrics.plainLyrics!.split('\n').where((line) => line.trim().isNotEmpty).toList();
    }
  }

  List<LrcLine> _parseLrc(String lrcText) {
    final lines = <LrcLine>[];
    final lrcLines = lrcText.split('\n');
    
    for (final line in lrcLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      
      // Parse LRC format: [mm:ss.xx] or [mm:ss] text
      final regex = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]\s*(.*)');
      final match = regex.firstMatch(trimmed);
      
      if (match != null) {
        final minutes = int.tryParse(match.group(1) ?? '0') ?? 0;
        final seconds = int.tryParse(match.group(2) ?? '0') ?? 0;
        final milliseconds = int.tryParse(match.group(3) ?? '0') ?? 0;
        final text = match.group(4)?.trim() ?? '';
        
        if (text.isNotEmpty) {
          // Convert milliseconds (could be 2 or 3 digits)
          final ms = milliseconds < 100 ? milliseconds * 10 : milliseconds;
          final timestamp = Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: ms,
          );
          lines.add(LrcLine(timestamp, text));
        }
      }
    }
    
    // Sort by timestamp
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  void _updateHighlightedLine() {
    if (_syncedLines.isEmpty) {
      // For plain lyrics, estimate based on position and duration
      // This is a simple approximation - could be improved
      return;
    }

    int newIndex = -1;
    for (int i = 0; i < _syncedLines.length; i++) {
      if (_currentPosition >= _syncedLines[i].timestamp) {
        // Check if there's a next line, and if current position is before it
        if (i + 1 < _syncedLines.length) {
          if (_currentPosition < _syncedLines[i + 1].timestamp) {
            newIndex = i;
            break;
          }
        } else {
          // Last line
          newIndex = i;
          break;
        }
      }
    }

    if (newIndex != _highlightedLineIndex && newIndex >= 0) {
      _highlightedLineIndex = newIndex;
      _scrollToLine(newIndex);
    }
  }

  void _scrollToLine(int lineIndex) {
    if (!_scrollController.hasClients) return;
    
    // Calculate line height more accurately
    // Font size: 16 * 1.5 = 24, line height: 24 * 1.8 = 43.2
    // Vertical padding per item: 8.0 * 2 = 16.0
    // Total per line item: ~59 pixels
    const itemHeight = 59.0;
    const listTopPadding = 24.0; // Top vertical padding from ListView
    
    // Calculate the center position of the target line item
    // Position = top padding + (index * item height) + (item height / 2)
    final targetLineCenter = listTopPadding + (lineIndex * itemHeight) + (itemHeight / 2);
    
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewportHeight = _scrollController.position.viewportDimension;
    final currentOffset = _scrollController.offset;
    
    // Calculate where the line center should be relative to viewport
    final desiredOffset = targetLineCenter - viewportHeight / 2;
    final centeredOffset = desiredOffset.clamp(0.0, maxScroll);
    
    // Only scroll if the line is not already reasonably centered (within 20 pixels)
    if ((centeredOffset - currentOffset).abs() > 20.0) {
      _scrollController.animateTo(
        centeredOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
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

          // Parse lyrics if not already parsed
          if (_syncedLines.isEmpty && _plainLines.isEmpty) {
            _parseLyrics();
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
                child: _buildLyricsContent(context),
              ),
            ],
          );
        },
      );
  }

  Widget _buildLyricsContent(BuildContext context) {
    // Use synced lyrics if available, otherwise use plain lyrics
    final hasSynced = _syncedLines.isNotEmpty;
    final itemCount = hasSynced ? _syncedLines.length : _plainLines.length;
    
    if (itemCount == 0) {
      return const Center(
        child: Text('No lyrics to display'),
      );
    }

    // Faint purple color for highlighting (secondaryAccent with low opacity)
    final highlightColor = Theme.of(context).colorScheme.secondary.withOpacity(0.35);
    final baseTextStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontSize: (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * 1.5,
      height: 1.8,
      letterSpacing: 0.3,
    );

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final isHighlighted = index == _highlightedLineIndex;
        final text = hasSynced ? _syncedLines[index].text : _plainLines[index];
        
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: SelectableText(
            text,
            style: baseTextStyle?.copyWith(
              color: isHighlighted 
                  ? highlightColor 
                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.9),
              fontWeight: isHighlighted ? FontWeight.w500 : FontWeight.normal,
            ),
            textAlign: TextAlign.left,
          ),
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
