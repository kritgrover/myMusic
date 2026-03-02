import 'package:flutter/material.dart';
import '../services/album_cover_service.dart';

/// Widget that fetches and displays album covers for tracks
/// Tries: 1) Pre-resolved URL, 2) Embedded artwork from file, 3) iTunes API, 4) Placeholder
class AlbumCover extends StatefulWidget {
  final String? filename; // For downloaded files
  final String? title;
  final String? artist;
  final String? album;
  final String? artworkUrl; // Pre-resolved artwork URL (takes priority)
  final double size;
  final Color? backgroundColor;
  final Color? iconColor;
  final BorderRadius? borderRadius;
  final Function(String?)? onArtworkResolved; // Callback when artwork is resolved

  const AlbumCover({
    super.key,
    this.filename,
    this.title,
    this.artist,
    this.album,
    this.artworkUrl,
    this.size = 40,
    this.backgroundColor,
    this.iconColor,
    this.borderRadius,
    this.onArtworkResolved,
  });

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> {
  final AlbumCoverService _service = AlbumCoverService();
  String? _artworkUrl;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadAlbumCover();
  }

  @override
  void didUpdateWidget(AlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filename != widget.filename ||
        oldWidget.title != widget.title ||
        oldWidget.artist != widget.artist ||
        oldWidget.album != widget.album ||
        oldWidget.artworkUrl != widget.artworkUrl) {
      _loadAlbumCover();
    }
  }

  Future<void> _loadAlbumCover() async {
    final needsFetch = widget.artworkUrl == null || widget.artworkUrl!.isEmpty;
    if (needsFetch) {
      setState(() {
        _isLoading = true;
        _hasError = false;
        _artworkUrl = null;
      });
    }

    final artworkUrl = await _service.resolveArtwork(
      filename: widget.filename,
      title: widget.title,
      artist: widget.artist,
      album: widget.album,
      existingUrl: widget.artworkUrl,
    );

    if (!mounted) return;
    setState(() {
      _artworkUrl = artworkUrl;
      _isLoading = false;
      _hasError = artworkUrl == null;
    });

    widget.onArtworkResolved?.call(artworkUrl);
  }

  @override
  Widget build(BuildContext context) {
    final defaultBgColor = widget.backgroundColor ??
        Theme.of(context).colorScheme.surfaceVariant;
    final defaultIconColor = widget.iconColor ??
        Theme.of(context).colorScheme.onSurface.withOpacity(0.5);
    final defaultBorderRadius = widget.borderRadius ?? BorderRadius.circular(8);

    // Show placeholder while loading or on error
    if (_isLoading || _hasError || _artworkUrl == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: defaultBgColor,
          borderRadius: defaultBorderRadius,
        ),
        child: _isLoading
            ? Center(
                child: SizedBox(
                  width: widget.size * 0.5,
                  height: widget.size * 0.5,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
              )
            : Icon(
                Icons.music_note,
                color: defaultIconColor,
                size: widget.size * 0.5,
              ),
      );
    }

    // Show artwork
    return ClipRRect(
      borderRadius: defaultBorderRadius,
      child: Image.network(
        _artworkUrl!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        // Optimize memory usage
        cacheWidth: widget.size.toInt(),
        cacheHeight: widget.size.toInt(),
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: defaultBgColor,
              borderRadius: defaultBorderRadius,
            ),
            child: Icon(
              Icons.music_note,
              color: defaultIconColor,
              size: widget.size * 0.5,
            ),
          );
        },
      ),
    );
  }
}

