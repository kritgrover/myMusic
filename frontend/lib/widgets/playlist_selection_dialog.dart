import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/playlist_service.dart';

const Color neonBlue = Color(0xFF00D9FF);

class PlaylistSelectionDialog extends StatefulWidget {
  final PlaylistService playlistService;
  final PlaylistTrack track;

  const PlaylistSelectionDialog({
    super.key,
    required this.playlistService,
    required this.track,
  });

  @override
  State<PlaylistSelectionDialog> createState() => _PlaylistSelectionDialogState();
}

class _PlaylistSelectionDialogState extends State<PlaylistSelectionDialog> {
  List<Playlist> _playlists = [];
  Set<String> _selectedPlaylistIds = {};
  bool _isLoading = true;
  bool _isAdding = false;

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
      // Check which playlists already contain this track
      final Set<String> existingPlaylistIds = {};
      for (var playlist in playlists) {
        for (var track in playlist.tracks) {
          if (track.id == widget.track.id || 
              (track.url != null && widget.track.url != null && track.url == widget.track.url)) {
            existingPlaylistIds.add(playlist.id);
            break;
          }
        }
      }

      setState(() {
        _playlists = playlists;
        _selectedPlaylistIds = existingPlaylistIds;
        _isLoading = false;
      });
    } catch (e) {
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

  Future<void> _togglePlaylist(Playlist playlist) async {
    if (_isAdding) return;

    final isSelected = _selectedPlaylistIds.contains(playlist.id);

    setState(() {
      _isAdding = true;
    });

    try {
      if (isSelected) {
        // Remove from playlist
        await widget.playlistService.removeTrackFromPlaylist(playlist.id, widget.track.id);
        setState(() {
          _selectedPlaylistIds.remove(playlist.id);
        });
      } else {
        // Add to playlist
        await widget.playlistService.addTrackToPlaylist(playlist.id, widget.track);
        setState(() {
          _selectedPlaylistIds.add(playlist.id);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to ${isSelected ? 'remove from' : 'add to'} playlist: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAdding = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        width: double.maxFinite,
        constraints: const BoxConstraints(maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: neonBlue.withOpacity(0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.playlist_add, color: neonBlue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add to Playlist',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.track.title,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[400],
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
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No playlists yet',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Create a playlist first',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.grey[400],
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
                            final isSelected = _selectedPlaylistIds.contains(playlist.id);

                            return ListTile(
                              leading: Icon(
                                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: isSelected ? neonBlue : Colors.grey[400],
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
          ],
        ),
      ),
    );
  }
}

