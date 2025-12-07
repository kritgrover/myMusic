import 'package:flutter/material.dart';

/// Shared utility functions for displaying song information consistently across the app

/// Formats a filename to a display name by:
/// - Extracting just the filename if it includes a subdirectory path
/// - Removing file extensions
/// - Removing number prefixes (e.g., "001 - Song Name" -> "Song Name")
/// - Extracting song name from "Song Name - Artist" format
String formatDisplayName(String filename) {
  // Extract just the filename if it includes a subdirectory path
  String displayName = filename.contains('/') 
      ? filename.split('/').last 
      : filename.contains('\\') 
          ? filename.split('\\').last 
          : filename;
  
  // Remove file extension
  final extensionPattern = RegExp(r'\.(m4a|mp3)$', caseSensitive: false);
  displayName = displayName.replaceAll(extensionPattern, '');

  // Check if filename starts with a number pattern (e.g., "001 - " or "1 - ")
  // This indicates a CSV-converted file
  final numberPrefixPattern = RegExp(r'^\d+\s*-\s*');
  if (numberPrefixPattern.hasMatch(displayName)) {
    // For CSV files: "001 - Song Name" -> remove number prefix, return "Song Name"
    displayName = displayName.replaceFirst(numberPrefixPattern, '');
    return displayName.trim();
  } else {
    // For web downloads: "Song Name - Artist" -> return "Song Name"
    final parts = displayName.split(' - ');
    if (parts.isNotEmpty) {
      return parts[0].trim();
    }
    return displayName;
  }
}

/// Gets the display title for a track, formatting it if it appears to be a filename
String getDisplayTitle(String? title, String? filename) {
  if (title == null || title.isEmpty) {
    return filename != null && filename.isNotEmpty 
        ? formatDisplayName(filename)
        : 'Unknown Track';
  }
  
  // If title appears to be a raw filename (contains extensions or path separators), format it
  if (title.contains('.m4a') || title.contains('.mp3') || 
      title.contains('/') || title.contains('\\')) {
    return formatDisplayName(title);
  }
  
  return title;
}

/// Gets the display artist, returning null if empty
String? getDisplayArtist(String? artist) {
  if (artist == null || artist.trim().isEmpty) {
    return null;
  }
  return artist.trim();
}

/// Widget for displaying song information consistently
/// Shows title on top, artist below (if available)
class SongInfoWidget extends StatelessWidget {
  final String? title;
  final String? artist;
  final String? filename; // Used as fallback if title is null
  final TextStyle? titleStyle;
  final TextStyle? artistStyle;
  final int? titleMaxLines;
  final int? artistMaxLines;
  final TextAlign? textAlign;

  const SongInfoWidget({
    super.key,
    this.title,
    this.artist,
    this.filename,
    this.titleStyle,
    this.artistStyle,
    this.titleMaxLines = 1,
    this.artistMaxLines = 1,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final displayTitle = getDisplayTitle(title, filename);
    final displayArtist = getDisplayArtist(artist);

    return Column(
      crossAxisAlignment: textAlign == TextAlign.center 
          ? CrossAxisAlignment.center 
          : textAlign == TextAlign.right 
              ? CrossAxisAlignment.end 
              : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          displayTitle,
          style: titleStyle ?? Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign ?? TextAlign.left,
        ),
        if (displayArtist != null)
          Text(
            displayArtist,
            style: artistStyle ?? Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[400],
            ),
            maxLines: artistMaxLines,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign ?? TextAlign.left,
          ),
      ],
    );
  }
}
