import 'package:flutter/material.dart';

// Shared utility functions for displaying song information consistently across the app
String formatDisplayName(String filename) {
  // Extract just the filename
  String displayName = filename.contains('/') 
      ? filename.split('/').last 
      : filename.contains('\\') 
          ? filename.split('\\').last 
          : filename;
  
  // Remove file extension
  final extensionPattern = RegExp(r'\.(m4a|mp3)$', caseSensitive: false);
  displayName = displayName.replaceAll(extensionPattern, '');

  final numberPrefixPattern = RegExp(r'^\d+\s*-\s*');
  if (numberPrefixPattern.hasMatch(displayName)) {
    // For CSV files: remove number prefix
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

/// Strip common YouTube noise from a title (client-side fallback for uncleaned data).
String _stripYouTubeSuffixes(String text) {
  final ytNoise = RegExp(
    r'\s*[(\[]\s*'
    r'(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s*video|'
    r'official\s+visualizer|lyric\s*video|lyrics?\s*(?:video)?|'
    r'audio|visualizer|music\s+video|'
    r'hd|hq|4k|remastered(?:\s+\d{4})?|explicit)'
    r'\s*[)\]]\s*',
    caseSensitive: false,
  );
  var result = text;
  String prev = '';
  while (result != prev) {
    prev = result;
    result = result.replaceAll(ytNoise, ' ').trim();
  }
  return result;
}

// Gets the display title for a track
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
  
  return _stripYouTubeSuffixes(title);
}

// Gets the display artist, returning null if empty
String? getDisplayArtist(String? artist) {
  if (artist == null || artist.trim().isEmpty) {
    return null;
  }
  return artist.trim();
}

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
