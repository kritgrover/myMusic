import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../services/album_cover_cache.dart';

/// Widget that fetches and displays album covers for tracks
/// Tries: 1) Embedded artwork from file, 2) iTunes API, 3) Placeholder
class AlbumCover extends StatefulWidget {
  final String? filename; // For downloaded files
  final String? title;
  final String? artist;
  final String? album;
  final double size;
  final Color? backgroundColor;
  final Color? iconColor;
  final BorderRadius? borderRadius;

  const AlbumCover({
    super.key,
    this.filename,
    this.title,
    this.artist,
    this.album,
    this.size = 40,
    this.backgroundColor,
    this.iconColor,
    this.borderRadius,
  });

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> {
  final ApiService _apiService = ApiService();
  final AlbumCoverCache _cache = AlbumCoverCache();
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
    // Reload if key properties changed
    if (oldWidget.filename != widget.filename ||
        oldWidget.title != widget.title ||
        oldWidget.artist != widget.artist ||
        oldWidget.album != widget.album) {
      _loadAlbumCover();
    }
  }

  Future<void> _loadAlbumCover() async {
    // Generate cache key
    final cacheKey = AlbumCoverCache.generateKey(
      filename: widget.filename,
      title: widget.title,
      artist: widget.artist,
      album: widget.album,
    );

    // Check cache first
    final cachedUrl = _cache.get(cacheKey);
    if (cachedUrl != null) {
      // Found in cache (null means we cached that there's no artwork)
      setState(() {
        _artworkUrl = cachedUrl.isEmpty ? null : cachedUrl;
        _isLoading = false;
        _hasError = cachedUrl.isEmpty;
      });
      return;
    }

    // Not in cache, fetch it
    setState(() {
      _isLoading = true;
      _hasError = false;
      _artworkUrl = null;
    });

    try {
      String? artworkUrl;

      // Priority 1: Try to get artwork from downloaded file
      if (widget.filename != null && widget.filename!.isNotEmpty) {
        try {
          final fileArtworkUrl = _apiService.getFileArtworkUrl(widget.filename!);
          // Test if the artwork endpoint returns valid data
          final response = await http.get(Uri.parse(fileArtworkUrl));
          if (response.statusCode == 200) {
            artworkUrl = fileArtworkUrl;
          }
        } catch (e) {
          // File artwork not available, continue to iTunes API
        }
      }

      // Priority 2: Try to fetch from iTunes API if file artwork not found
      if (artworkUrl == null && widget.title != null && widget.title!.isNotEmpty) {
        artworkUrl = await _apiService.fetchAlbumCover(
          title: widget.title!,
          artist: widget.artist ?? '',
          album: widget.album ?? '',
        );
      }

      // Cache the result (even if null, to avoid refetching)
      _cache.put(cacheKey, artworkUrl ?? '');

      setState(() {
        _artworkUrl = artworkUrl;
        _isLoading = false;
        _hasError = artworkUrl == null;
      });
    } catch (e) {
      // Cache the failure to avoid repeated attempts
      _cache.put(cacheKey, '');
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
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

