import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/saved_music_service.dart';
import 'save_music_button.dart';

class SaveTrackButton extends StatelessWidget {
  final PlaylistTrack track;
  final SavedMusicService? service;
  final bool compact;
  const SaveTrackButton(
      {super.key, required this.track, this.service, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final library = service ?? SavedMusicService.shared;
    return SavedMusicToggleButton(
        service: library,
        kind: SavedMusicKind.tracks,
        itemId: SavedMusicService.trackKey(track),
        onToggle: () => library.toggleTrack(track),
        savedTooltip: 'Remove from Liked Songs',
        unsavedTooltip: 'Save to Liked Songs',
        savedIcon: Icons.favorite,
        unsavedIcon: Icons.favorite_border,
        compact: compact);
  }
}
