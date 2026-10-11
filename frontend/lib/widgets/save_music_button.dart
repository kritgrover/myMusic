import 'package:flutter/material.dart';
import '../services/saved_music_service.dart';

class SaveAlbumButton extends StatelessWidget {
  final SavedAlbum album;
  final SavedMusicService? service;
  const SaveAlbumButton({super.key, required this.album, this.service});
  @override
  Widget build(BuildContext context) {
    final library = service ?? SavedMusicService.shared;
    return SavedMusicToggleButton(
        service: library,
        kind: SavedMusicKind.albums,
        itemId: album.id,
        onToggle: () => library.toggleAlbum(album),
        savedTooltip: 'Remove from saved albums',
        unsavedTooltip: 'Save album',
        savedLabel: 'Saved',
        unsavedLabel: 'Save album',
        savedIcon: Icons.check_circle,
        unsavedIcon: Icons.add_circle_outline);
  }
}

class FollowArtistButton extends StatelessWidget {
  final SavedArtist artist;
  final SavedMusicService? service;
  const FollowArtistButton({super.key, required this.artist, this.service});
  @override
  Widget build(BuildContext context) {
    final library = service ?? SavedMusicService.shared;
    return SavedMusicToggleButton(
        service: library,
        kind: SavedMusicKind.artists,
        itemId: artist.id,
        onToggle: () => library.toggleArtist(artist),
        savedTooltip: 'Unfollow artist',
        unsavedTooltip: 'Follow artist',
        savedLabel: 'Following',
        unsavedLabel: 'Follow',
        savedIcon: Icons.check,
        unsavedIcon: Icons.person_add_alt_1);
  }
}

/// Shared interaction for the three library kinds. The service owns optimistic
/// state and rollback so every visible button updates together.
class SavedMusicToggleButton extends StatefulWidget {
  final SavedMusicService service;
  final SavedMusicKind kind;
  final String itemId;
  final Future<void> Function() onToggle;
  final String savedTooltip;
  final String unsavedTooltip;
  final String? savedLabel;
  final String? unsavedLabel;
  final IconData savedIcon;
  final IconData unsavedIcon;
  final bool compact;
  const SavedMusicToggleButton(
      {super.key,
      required this.service,
      required this.kind,
      required this.itemId,
      required this.onToggle,
      required this.savedTooltip,
      required this.unsavedTooltip,
      required this.savedIcon,
      required this.unsavedIcon,
      this.savedLabel,
      this.unsavedLabel,
      this.compact = false});
  @override
  State<SavedMusicToggleButton> createState() => _SavedMusicToggleButtonState();
}

class _SavedMusicToggleButtonState extends State<SavedMusicToggleButton> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SavedMusicToggleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) _load();
  }

  void _load() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await widget.service.load();
      } catch (_) {
        // Retrying the button loads again and displays any continuing failure.
      }
    });
  }

  Future<void> _toggle() async {
    try {
      await widget.onToggle();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.toString()),
          behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final saved = widget.service.isSaved(widget.kind, widget.itemId);
        final busy = widget.service.isBusy(widget.kind, widget.itemId) ||
            widget.service.isLoading;
        final tooltip = saved ? widget.savedTooltip : widget.unsavedTooltip;
        final icon = busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(saved ? widget.savedIcon : widget.unsavedIcon,
                color: saved ? Theme.of(context).colorScheme.primary : null,
                size: widget.compact ? 20 : 24);
        final label = saved ? widget.savedLabel : widget.unsavedLabel;
        if (label != null) {
          return Tooltip(
              message: tooltip,
              child: OutlinedButton.icon(
                  onPressed: busy ? null : _toggle,
                  icon: icon,
                  label: Text(label)));
        }
        return IconButton(
            tooltip: tooltip,
            onPressed: busy ? null : _toggle,
            icon: icon,
            isSelected: saved,
            constraints: widget.compact
                ? const BoxConstraints.tightFor(width: 36, height: 36)
                : null,
            padding: widget.compact ? EdgeInsets.zero : null,
            visualDensity: widget.compact ? VisualDensity.compact : null);
      });
}
