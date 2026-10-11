import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';
import '../models/playlist.dart';
import '../services/playlist_service.dart';

class PlaylistSelectionDialog extends StatefulWidget {
  final PlaylistService playlistService;
  final PlaylistTrack track;

  const PlaylistSelectionDialog({
    super.key,
    required this.playlistService,
    required this.track,
  });

  @override
  State<PlaylistSelectionDialog> createState() =>
      _PlaylistSelectionDialogState();
}

class _PlaylistSelectionDialogState extends State<PlaylistSelectionDialog> {
  List<Playlist> _playlists = [];
  Set<String> _selectedPlaylistIds = {};
  Set<String> _initialPlaylistIds =
      {}; // Playlists that had the track when dialog opened
  Map<String, Set<String>> _existingTrackIds = {};
  bool _isLoading = true;
  bool _isAdding = false;

  bool get _hasChanges =>
      _selectedPlaylistIds.difference(_initialPlaylistIds).isNotEmpty ||
      _initialPlaylistIds.difference(_selectedPlaylistIds).isNotEmpty;

  bool _matchesTrack(PlaylistTrack track) =>
      (track.id.isNotEmpty && track.id == widget.track.id) ||
      (track.url?.isNotEmpty == true && track.url == widget.track.url) ||
      (track.filename.isNotEmpty &&
          track.filename.replaceAll('\\', '/') ==
              widget.track.filename.replaceAll('\\', '/'));

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final playlists = await widget.playlistService.getAllPlaylists();
      if (!mounted) return;
      // Check which playlists already contain this track
      final existingTrackIds = <String, Set<String>>{};
      for (var playlist in playlists) {
        for (var track in playlist.tracks) {
          if (_matchesTrack(track)) {
            existingTrackIds.putIfAbsent(playlist.id, () => {}).add(track.id);
          }
        }
      }

      setState(() {
        _playlists = playlists;
        _existingTrackIds = existingTrackIds;
        _initialPlaylistIds = existingTrackIds.keys.toSet();
        _selectedPlaylistIds = Set.from(_initialPlaylistIds);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load playlists: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _togglePlaylist(Playlist playlist) {
    if (_isAdding) return;

    setState(() {
      if (_selectedPlaylistIds.contains(playlist.id)) {
        _selectedPlaylistIds.remove(playlist.id);
      } else {
        _selectedPlaylistIds.add(playlist.id);
      }
    });
  }

  Future<void> _confirmAdd() async {
    if (_isAdding || !_hasChanges) return;
    setState(() => _isAdding = true);

    try {
      final toAdd = _selectedPlaylistIds.difference(_initialPlaylistIds);
      final toRemove = _initialPlaylistIds.difference(_selectedPlaylistIds);

      for (final playlistId in toAdd) {
        await widget.playlistService
            .addTrackToPlaylist(playlistId, widget.track);
        // Keep the baseline aligned with every successful request. If a later
        // playlist fails, retries and further selection changes must account
        // for the memberships already saved on the server.
        _initialPlaylistIds.add(playlistId);
        _existingTrackIds[playlistId] = {widget.track.id};
      }
      for (final playlistId in toRemove) {
        // A saved song can have a different stable ID than the copy originally
        // added to a playlist. Remove the actual matched playlist row IDs.
        for (final trackId in _existingTrackIds[playlistId]!.toList()) {
          await widget.playlistService
              .removeTrackFromPlaylist(playlistId, trackId);
          _existingTrackIds[playlistId]!.remove(trackId);
          if (_existingTrackIds[playlistId]!.isEmpty) {
            _initialPlaylistIds.remove(playlistId);
          }
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              toAdd.isEmpty && toRemove.isEmpty
                  ? 'No changes made'
                  : 'Playlist updated',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAdding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update playlist: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceColor = Theme.of(context).colorScheme.surface;
    final surfaceVariant = Theme.of(context).colorScheme.surfaceVariant;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final onSurfaceMuted = onSurface.withOpacity(0.7);

    return Dialog(
      backgroundColor: surfaceColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        width: ResponsiveUtils.responsiveDialogWidth(context),
        constraints: BoxConstraints(
          maxHeight: ResponsiveUtils.responsiveDialogHeight(context),
        ),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: surfaceVariant.withOpacity(0.5),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: primaryColor.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.playlist_add, color: primaryColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add to Playlist',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.track.title,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: onSurfaceMuted,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            // Playlists list
            Flexible(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _playlists.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.playlist_add,
                                  size: 64,
                                  color: onSurfaceMuted,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No playlists yet',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Create a playlist first',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: onSurfaceMuted,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _playlists.length,
                          itemBuilder: (context, index) {
                            final playlist = _playlists[index];
                            final isSelected =
                                _selectedPlaylistIds.contains(playlist.id);

                            return ListTile(
                              leading: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color:
                                    isSelected ? primaryColor : onSurfaceMuted,
                              ),
                              title: Text(playlist.name),
                              subtitle: Text(
                                '${playlist.tracks.length} ${playlist.tracks.length == 1 ? 'track' : 'tracks'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              onTap: () => _togglePlaylist(playlist),
                              enabled: !_isAdding,
                            );
                          },
                        ),
            ),
            // Confirm button
            if (!_playlists.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: (_isLoading || _isAdding || !_hasChanges)
                        ? null
                        : _confirmAdd,
                    icon: _isAdding
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.check, size: 20),
                    label: Text(_isAdding
                        ? 'Saving...'
                        : _initialPlaylistIds.isNotEmpty
                            ? 'Save changes'
                            : 'Add to selected'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
