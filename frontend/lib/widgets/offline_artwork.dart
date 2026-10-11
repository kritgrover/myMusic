import 'package:flutter/material.dart';
import 'offline_artwork_stub.dart'
    if (dart.library.io) 'offline_artwork_io.dart' as platform;

/// Displays cached artwork without making a network request.
class OfflineArtwork extends StatelessWidget {
  const OfflineArtwork({
    super.key,
    this.localArtworkUrl,
    this.size = 48,
    this.borderRadius,
    this.backgroundColor,
    this.iconColor,
  });

  final String? localArtworkUrl;
  final double size;
  final BorderRadius? borderRadius;
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note_rounded,
          size: size * .45,
          color: iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(10),
      child: platform.buildArtwork(localArtworkUrl, size, placeholder),
    );
  }
}
