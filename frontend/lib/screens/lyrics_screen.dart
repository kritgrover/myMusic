import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'dart:async';
import '../services/lyrics_service.dart';
import '../services/player_state_service.dart';
import '../services/album_cover_service.dart';
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
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  int _highlightedLineIndex = -1;
  int _hoveredLineIndex = -1; // Track which line is being hovered
  List<LrcLine> _syncedLines = [];
  List<String> _plainLines = [];
  String? _artworkUrl;
  final AlbumCoverService _albumCoverService = AlbumCoverService();

  @override
  void initState() {
    super.initState();
    // Fetch lyrics and artwork when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchLyrics();
      _loadArtwork();
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
  void didUpdateWidget(covariant LyricsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackName != widget.trackName ||
        oldWidget.artistName != widget.artistName) {
      _loadArtwork();
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    widget.lyricsService.removeListener(_onLyricsChanged);
    super.dispose();
  }

  Future<void> _loadArtwork() async {
    if (widget.trackName.isEmpty) return;
    try {
      final url = await _albumCoverService.resolveArtwork(
        title: widget.trackName,
        artist: widget.artistName,
        album: widget.albumName ?? '',
      );
      if (mounted) setState(() => _artworkUrl = url);
    } catch (_) {}
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
    // +1 because index 0 is the top spacer
    _itemScrollController.scrollTo(
      index: lineIndex + 1,
      alignment: 0.4, // Slightly above center for better context
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Widget _buildPlaceholderArtwork(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
        size: 24,
      ),
    );
  }

  Widget _buildBackground(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_artworkUrl != null && _artworkUrl!.isNotEmpty)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Transform.scale(
                scale: 1.2,
                child: Image.network(
                  _artworkUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.expand(),
                ),
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [
                  Theme.of(context).colorScheme.secondary.withOpacity(0.15),
                  Theme.of(context).colorScheme.surface,
                ],
              ),
            ),
          ),
        // Dark gradient overlay for readability (lighter to show artwork through)
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.55),
                  Colors.black.withOpacity(0.65),
                  Colors.black.withOpacity(0.75),
                ],
              ),
            ),
          ),
        ),
      ],
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

          // Parse lyrics if not already parsed
          if (_syncedLines.isEmpty && _plainLines.isEmpty) {
            _parseLyrics();
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Track info header with album art
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _artworkUrl != null && _artworkUrl!.isNotEmpty
                          ? Image.network(
                              _artworkUrl!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _buildPlaceholderArtwork(context),
                            )
                          : _buildPlaceholderArtwork(context),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
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
                    if (_syncedLines.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.secondary.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Synced',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.secondary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
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
    final hasSynced = _syncedLines.isNotEmpty;
    final itemCount = hasSynced ? _syncedLines.length : _plainLines.length;

    if (itemCount == 0) {
      return const Center(
        child: Text('No lyrics to display'),
      );
    }

    final baseFontSize = (Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16) * 1.5;
    final viewportHeight = MediaQuery.of(context).size.height;
    final spacerHeight = viewportHeight * 0.4;

    // Spacer items at start and end so first/last lines can scroll to center
    const spacerCount = 2;
    final totalItemCount = spacerCount + itemCount;

    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      itemCount: totalItemCount,
      itemBuilder: (context, index) {
        if (index == 0 || index == totalItemCount - 1) {
          return SizedBox(height: spacerHeight);
        }

        final lineIndex = index - 1;
        final isHighlighted = lineIndex == _highlightedLineIndex;
        final isHovered = lineIndex == _hoveredLineIndex;
        final text = hasSynced ? _syncedLines[lineIndex].text : _plainLines[lineIndex];
        final timestamp = hasSynced ? _syncedLines[lineIndex].timestamp : null;
        final isClickable =
            hasSynced && timestamp != null && widget.playerStateService != null;

        // Progressive opacity: active full, adjacent 70%, distant 35%
        double opacity;
        double fontSize;
        FontWeight fontWeight;
        List<Shadow>? shadows;
        if (hasSynced && _highlightedLineIndex >= 0) {
          final distance = (lineIndex - _highlightedLineIndex).abs();
          if (distance == 0) {
            opacity = 1.0;
            fontSize = baseFontSize * 1.2;
            fontWeight = FontWeight.w700;
            shadows = [
              Shadow(
                color: Theme.of(context).colorScheme.secondary.withOpacity(0.6),
                blurRadius: 20,
                offset: Offset.zero,
              ),
            ];
          } else if (distance <= 2) {
            opacity = 0.7;
            fontSize = baseFontSize;
            fontWeight = FontWeight.normal;
            shadows = null;
          } else {
            opacity = 0.35;
            fontSize = baseFontSize;
            fontWeight = FontWeight.normal;
            shadows = null;
          }
        } else {
          opacity = 0.9;
          fontSize = baseFontSize;
          fontWeight = FontWeight.normal;
          shadows = null;
        }

        if (isHovered && isClickable) {
          opacity = 0.85;
        }

        final textStyle = TextStyle(
          fontSize: fontSize,
          height: 1.8,
          letterSpacing: 0.3,
          color: Colors.white.withOpacity(opacity),
          fontWeight: fontWeight,
          shadows: shadows,
        );

        Widget textWidget = AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          style: textStyle,
          child: isClickable
              ? Text(text, textAlign: TextAlign.center)
              : SelectableText(text, textAlign: TextAlign.center),
        );

        if (isClickable) {
          textWidget = InkWell(
            onTap: () async {
              if (widget.playerStateService != null && timestamp != null) {
                try {
                  await widget.playerStateService!.audioPlayer.seek(timestamp);
                } catch (_) {}
              }
            },
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hoveredLineIndex = lineIndex),
              onExit: (_) => setState(() => _hoveredLineIndex = -1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
                child: textWidget,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: textWidget,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.embedded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      child: Text(
                        'Lyrics',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
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
          )
        : Scaffold(
            appBar: AppBar(
              title: const Text('Lyrics'),
              backgroundColor: Colors.transparent,
              elevation: 0,
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchLyrics,
                  tooltip: 'Refresh lyrics',
                ),
              ],
            ),
            extendBodyBehindAppBar: true,
            body: Stack(
              children: [
                Positioned.fill(child: _buildBackground(context)),
                SafeArea(child: _buildContent()),
              ],
            ),
          );

    if (widget.embedded) {
      return ClipRect(
        child: Stack(
          children: [
            Positioned.fill(child: _buildBackground(context)),
            content,
          ],
        ),
      );
    }

    return content;
  }
}
