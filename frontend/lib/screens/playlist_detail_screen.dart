import 'package:flutter/material.dart';
import '../services/playlist_service.dart';
import '../models/playlist.dart';
import 'add_to_playlist_screen.dart';

const Color neonBlue = Color(0xFF00D9FF);

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  final PlaylistService playlistService;
  final dynamic playerStateService; // Optional, for playing tracks

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.playlistService,
    this.playerStateService,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Playlist _playlist;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _playlist = widget.playlist;
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final updatedPlaylist = await widget.playlistService.getPlaylist(_playlist.id);
      if (updatedPlaylist != null) {
        setState(() {
          _playlist = updatedPlaylist;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _addSongs() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddToPlaylistScreen(
          playlistId: _playlist.id,
          playlistService: widget.playlistService,
        ),
      ),
    );

    await _loadPlaylist();
  }

  Future<void> _removeTrack(PlaylistTrack track) async {
    try {
      await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
      await _loadPlaylist();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Track removed'),
            backgroundColor: neonBlue,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _playTrack(PlaylistTrack track) async {
    try {
      if (track.filename.isNotEmpty && widget.playerStateService != null) {
        // Play from downloads
        await widget.playerStateService.playTrack(track.filename, trackName: track.title);
      } else if (track.filename.isNotEmpty) {
        // PlayerStateService not available
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot play: ${track.title}'),
            ),
          );
        }
      } else if (track.url != null) {
        // This is a YouTube URL - would need to download first or handle differently
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please download this track first'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatDisplayName(String title) {
    // Remove file extension
    String displayName = title;
    final extensionPattern = RegExp(r'\.(m4a|mp3)$', caseSensitive: false);
    displayName = displayName.replaceAll(extensionPattern, '');

    // Remove channel/artist information (everything after " - ")
    // Format is typically "Title - Channel/Artist"
    // We only want to show the title
    final parts = displayName.split(' - ');
    if (parts.isNotEmpty) {
      return parts[0].trim();
    }
    
    return displayName;
  }

  Future<void> _renamePlaylist() async {
    final nameController = TextEditingController(text: _playlist.name);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.of(context).pop(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                Navigator.of(context).pop(nameController.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != _playlist.name) {
      try {
        await widget.playlistService.updatePlaylist(_playlist.id, result);
        await _loadPlaylist();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Playlist renamed'),
            backgroundColor: neonBlue,
            behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to rename playlist: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('myMusic'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _renamePlaylist,
            tooltip: 'Rename playlist',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addSongs,
            tooltip: 'Add songs',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Playlist header
                Container(
                  padding: const EdgeInsets.all(24.0),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    border: Border(
                      bottom: BorderSide(
                        color: neonBlue.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: neonBlue.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: neonBlue.withOpacity(0.5),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.playlist_play,
                          size: 40,
                          color: neonBlue,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _playlist.name,
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.music_note,
                                  size: 18,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_playlist.tracks.length} ${_playlist.tracks.length == 1 ? 'track' : 'tracks'}',
                                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Colors.grey[400],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Tracks list
                Expanded(
                  child: _playlist.tracks.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.queue_music,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No tracks in this playlist',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Add songs to get started',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 24),
                              ElevatedButton.icon(
                                onPressed: _addSongs,
                                icon: const Icon(Icons.add),
                                label: const Text('Add Songs'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          itemCount: _playlist.tracks.length,
                          itemBuilder: (context, index) {
                            final track = _playlist.tracks[index];
                            final isCurrentlyPlaying = widget.playerStateService != null &&
                                widget.playerStateService.currentTrackUrl?.contains(track.filename ?? '') == true;
                            
                            return Column(
                              children: [
                                Material(
                                  color: isCurrentlyPlaying 
                                      ? neonBlue.withOpacity(0.1) 
                                      : Colors.transparent,
                                  child: InkWell(
                                    onTap: () => _playTrack(track),
                                    hoverColor: neonBlue.withOpacity(0.15),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: neonBlue.withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(
                                                color: neonBlue.withOpacity(0.3),
                                                width: 1,
                                              ),
                                            ),
                                            child: Icon(
                                              Icons.music_note,
                                              color: isCurrentlyPlaying ? neonBlue : Colors.grey[400],
                                              size: 24,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _formatDisplayName(track.title),
                                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                    fontWeight: FontWeight.w500,
                                                    color: isCurrentlyPlaying ? neonBlue : null,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                if (track.artist != null && track.artist!.isNotEmpty)
                                                  Padding(
                                                    padding: const EdgeInsets.only(top: 4.0),
                                                    child: Text(
                                                      track.artist!,
                                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                        color: Colors.grey[400],
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              Icons.delete_outline,
                                              color: Colors.grey[400],
                                            ),
                                            onPressed: () => _removeTrack(track),
                                            tooltip: 'Remove from playlist',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: Colors.grey[800],
                                  indent: 80,
                                ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
