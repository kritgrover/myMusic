import 'dart:math';
import 'package:flutter/material.dart';
import '../services/playlist_service.dart';
import '../services/api_service.dart';
import '../services/queue_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import 'add_to_playlist_screen.dart';
import '../utils/song_display_utils.dart';

enum PlaylistSortOption {
  defaultOrder,
  artistName,
  songName,
}

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  final PlaylistService playlistService;
  final dynamic playerStateService; // Optional, for playing tracks
  final QueueService? queueService;
  final VoidCallback? onBack; // Callback to return to playlists list

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.playlistService,
    this.playerStateService,
    this.queueService,
    this.onBack,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Playlist _playlist;
  bool _isLoading = false;
  bool _showAddSongs = false;
  PlaylistSortOption _sortOption = PlaylistSortOption.defaultOrder;
  final ApiService _apiService = ApiService();

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

  void _addSongs() {
    setState(() {
      _showAddSongs = true;
    });
  }

  void _hideAddSongs() {
    setState(() {
      _showAddSongs = false;
    });
    // Reload playlist when returning from add songs
    _loadPlaylist();
  }

  // Get sorted tracks based on current sort option
  List<PlaylistTrack> get _sortedTracks {
    final tracks = List<PlaylistTrack>.from(_playlist.tracks);
    
    switch (_sortOption) {
      case PlaylistSortOption.defaultOrder:
        // Return tracks in original order (as stored)
        return tracks;
      case PlaylistSortOption.artistName:
        // Sort by artist name, then by song name
        tracks.sort((a, b) {
          final artistA = (a.artist ?? '').toLowerCase();
          final artistB = (b.artist ?? '').toLowerCase();
          if (artistA != artistB) {
            return artistA.compareTo(artistB);
          }
          // If artists are the same, sort by song name
          final titleA = (a.title ?? '').toLowerCase();
          final titleB = (b.title ?? '').toLowerCase();
          return titleA.compareTo(titleB);
        });
        return tracks;
      case PlaylistSortOption.songName:
        // Sort by song name
        tracks.sort((a, b) {
          final titleA = (a.title ?? '').toLowerCase();
          final titleB = (b.title ?? '').toLowerCase();
          return titleA.compareTo(titleB);
        });
        return tracks;
    }
  }

  void _changeSortOption(PlaylistSortOption? newOption) {
    if (newOption != null) {
      setState(() {
        _sortOption = newOption;
      });
    }
  }

  Future<void> _removeTrack(PlaylistTrack track) async {
    try {
      await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
      await _loadPlaylist();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Track removed'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
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

  bool _isTrackDownloaded(PlaylistTrack track) {
    // A track is considered downloaded if it has a non-empty filename
    return track.filename.isNotEmpty;
  }

  Future<void> _downloadTrack(PlaylistTrack track) async {
    if (track.url == null || track.url!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No URL available for download'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      final result = await _apiService.downloadAudio(
        url: track.url!,
        title: track.title,
        artist: track.artist ?? '',
        outputFormat: 'm4a',
        embedThumbnail: true,
      );

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog

        // Update the track in the playlist with the new filename
        final updatedTrack = PlaylistTrack(
          id: track.id,
          title: track.title,
          artist: track.artist,
          album: track.album,
          filename: result.filename,
          url: track.url,
          thumbnail: track.thumbnail,
          duration: track.duration,
        );

        // Remove old track and add updated track
        await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
        await widget.playlistService.addTrackToPlaylist(_playlist.id, updatedTrack);

        // Reload playlist to show updated track
        await _loadPlaylist();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded: ${result.filename}'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _playTrack(PlaylistTrack track) async {
    try {
      if (track.filename.isNotEmpty && widget.playerStateService != null) {
        // Play from downloads - use formatted title and artist
        final displayTitle = getDisplayTitle(track.title, track.filename);
        await widget.playerStateService.playTrack(
          track.filename, 
          trackName: displayTitle,
          trackArtist: track.artist,
        );
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
        // This is a YouTube URL - stream it immediately
        if (widget.playerStateService != null) {
          try {
            final result = await _apiService.getStreamingUrl(
              url: track.url!,
              title: track.title,
              artist: track.artist ?? '',
            );

            // Start streaming immediately - just_audio will handle buffering
            await widget.playerStateService.streamTrack(
              result.streamingUrl,
              trackName: result.title,
              trackArtist: result.artist,
            );
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Stream failed: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Player not available'),
              ),
            );
          }
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
          SnackBar(
            content: const Text('Playlist renamed'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
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

  Future<void> _downloadUndownloadedTracks() async {
    // Find all tracks that need to be downloaded
    final tracksToDownload = _playlist.tracks.where((track) => 
      !_isTrackDownloaded(track) && track.url != null && track.url!.isNotEmpty
    ).toList();

    if (tracksToDownload.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('All tracks are already downloaded'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
      return;
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download Tracks'),
        content: Text(
          'Download ${tracksToDownload.length} ${tracksToDownload.length == 1 ? 'track' : 'tracks'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    int successCount = 0;
    int failCount = 0;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Downloading ${tracksToDownload.length} ${tracksToDownload.length == 1 ? 'track' : 'tracks'}...\nPlease wait',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );

    try {
      for (final track in tracksToDownload) {

        try {
          final result = await _apiService.downloadAudio(
            url: track.url!,
            title: track.title,
            artist: track.artist ?? '',
            outputFormat: 'm4a',
            embedThumbnail: true,
          );

          // Update the track in the playlist with the new filename
          final updatedTrack = PlaylistTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            filename: result.filename,
            url: track.url,
            thumbnail: track.thumbnail,
            duration: track.duration,
          );

          // Remove old track and add updated track
          await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
          await widget.playlistService.addTrackToPlaylist(_playlist.id, updatedTrack);

          successCount++;
        } catch (e) {
          failCount++;
          // Continue with next track
        }
      }

      // Reload playlist to show updated tracks
      await _loadPlaylist();

      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failCount > 0
                  ? 'Downloaded $successCount ${successCount == 1 ? 'track' : 'tracks'}${failCount > 0 ? ' ($failCount failed)' : ''}'
                  : 'Downloaded ${successCount} ${successCount == 1 ? 'track' : 'tracks'}',
            ),
            backgroundColor: failCount > 0 ? Colors.orange : null,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download error: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  Future<void> _addPlaylistToQueue() async {
    await _addPlaylistToQueueInternal(shuffle: false);
  }

  Future<void> _shufflePlaylistToQueue() async {
    await _addPlaylistToQueueInternal(shuffle: true);
  }

  Future<void> _playPlaylist() async {
    if (widget.queueService == null || widget.playerStateService == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Player or queue service not available'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (_playlist.tracks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist is empty'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Preparing playlist...'),
          ],
        ),
      ),
    );

    try {
      // Use sorted tracks
      final tracks = _sortedTracks;

      final queueItems = <QueueItem>[];
      int successCount = 0;
      int failCount = 0;

      for (final track in tracks) {
        try {
          QueueItem? queueItem;

          if (track.filename.isNotEmpty) {
            // Local file
            queueItem = QueueItem.fromDownloadedFile(
              filename: track.filename,
              title: track.title,
              artist: track.artist,
            );
            queueItems.add(queueItem);
            successCount++;
          } else if (track.url != null && track.url!.isNotEmpty) {
            // Need to get streaming URL
            try {
              final result = await _apiService.getStreamingUrl(
                url: track.url!,
                title: track.title,
                artist: track.artist ?? '',
              );

              queueItem = QueueItem.fromPlaylistTrack(
                trackId: track.id,
                title: result.title,
                artist: result.artist,
                streamingUrl: result.streamingUrl,
              );
              queueItems.add(queueItem);
              successCount++;
            } catch (e) {
              failCount++;
              // Continue with next track
            }
          } else {
            failCount++;
          }
        } catch (e) {
          failCount++;
          // Continue with next track
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog

        if (queueItems.isNotEmpty) {
          // Clear the queue first
          widget.queueService!.clearQueue();
          
          // Add all items to queue
          widget.queueService!.addAllToQueue(queueItems);
          
          // Start playing the first item
          await widget.queueService!.playItem(0, widget.playerStateService!);

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                failCount > 0
                    ? 'Playing playlist: $successCount tracks added${failCount > 0 ? ' ($failCount failed)' : ''}'
                    : 'Playing playlist: ${queueItems.length} tracks',
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('No tracks could be added to queue'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to play playlist: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  Future<void> _addPlaylistToQueueInternal({required bool shuffle}) async {
    if (widget.queueService == null) return;

    if (_playlist.tracks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist is empty'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (shuffle) ...[
              const SizedBox(height: 16),
              const Text('Shuffling playlist...'),
            ],
          ],
        ),
      ),
    );

    try {
      // Use sorted tracks and shuffle if needed
      final tracks = List<PlaylistTrack>.from(_sortedTracks);
      if (shuffle) {
        tracks.shuffle(Random());
      }

      final queueItems = <QueueItem>[];
      int successCount = 0;
      int failCount = 0;

      for (final track in tracks) {
        try {
          QueueItem? queueItem;

          if (track.filename.isNotEmpty) {
            // Local file
            queueItem = QueueItem.fromDownloadedFile(
              filename: track.filename,
              title: track.title,
              artist: track.artist,
            );
            queueItems.add(queueItem);
            successCount++;
          } else if (track.url != null && track.url!.isNotEmpty) {
            // Need to get streaming URL
            try {
              final result = await _apiService.getStreamingUrl(
                url: track.url!,
                title: track.title,
                artist: track.artist ?? '',
              );

              queueItem = QueueItem.fromPlaylistTrack(
                trackId: track.id,
                title: result.title,
                artist: result.artist,
                streamingUrl: result.streamingUrl,
              );
              queueItems.add(queueItem);
              successCount++;
            } catch (e) {
              failCount++;
              // Continue with next track
            }
          } else {
            failCount++;
          }
        } catch (e) {
          failCount++;
          // Continue with next track
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog

        if (queueItems.isNotEmpty) {
          // If shuffle is enabled, clear the existing queue first
          if (shuffle) {
            widget.queueService!.clearQueue();
          }
          
          widget.queueService!.addAllToQueue(queueItems);

          // If shuffle is enabled and player service is available, start playing the first song
          if (shuffle && widget.playerStateService != null) {
            await widget.queueService!.playItem(0, widget.playerStateService!);
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                shuffle
                    ? (failCount > 0
                        ? 'Shuffled and added $successCount tracks to queue${failCount > 0 ? ' ($failCount failed)' : ''}'
                        : 'Shuffled and added ${queueItems.length} tracks to queue')
                    : (failCount > 0
                        ? 'Added $successCount tracks to queue${failCount > 0 ? ' ($failCount failed)' : ''}'
                        : 'Added ${queueItems.length} tracks to queue'),
              ),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('No tracks could be added to queue'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to ${shuffle ? 'shuffle and ' : ''}add playlist to queue: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  Future<void> _addToQueue(PlaylistTrack track) async {
    if (widget.queueService == null) return;

    try {
      QueueItem? queueItem;

      if (track.filename.isNotEmpty) {
        // Local file
        queueItem = QueueItem.fromDownloadedFile(
          filename: track.filename,
          title: track.title,
          artist: track.artist,
        );
      } else if (track.url != null && track.url!.isNotEmpty) {
        // Need to get streaming URL
        try {
          final result = await _apiService.getStreamingUrl(
            url: track.url!,
            title: track.title,
            artist: track.artist ?? '',
          );

          queueItem = QueueItem.fromPlaylistTrack(
            trackId: track.id,
            title: result.title,
            artist: result.artist,
            streamingUrl: result.streamingUrl,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to get streaming URL: $e'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No URL or filename available'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      if (queueItem != null) {
        widget.queueService!.addToQueue(queueItem);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Added to queue: ${getDisplayTitle(track.title, track.filename)}'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to queue: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;
    
    // If showing add songs screen, display that instead
    if (_showAddSongs) {
      return AddToPlaylistScreen(
        playlistId: _playlist.id,
        playlistService: widget.playlistService,
        onBack: _hideAddSongs,
      );
    }

    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              // Playlist header
              Container(
                padding: const EdgeInsets.all(24.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    // Back button
                    if (widget.onBack != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: widget.onBack,
                        tooltip: 'Back to playlists',
                      ),
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: primaryColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.playlist_play,
                        size: 40,
                        color: primaryColor,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _playlist.name,
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
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
                              PopupMenuButton<PlaylistSortOption>(
                                icon: const Icon(Icons.sort),
                                tooltip: 'Sort playlist',
                                onSelected: _changeSortOption,
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: PlaylistSortOption.defaultOrder,
                                    child: Row(
                                      children: [
                                        Icon(
                                          _sortOption == PlaylistSortOption.defaultOrder
                                              ? Icons.check
                                              : null,
                                          size: 20,
                                          color: _sortOption == PlaylistSortOption.defaultOrder
                                              ? primaryColor
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                        const Text('Default'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: PlaylistSortOption.artistName,
                                    child: Row(
                                      children: [
                                        Icon(
                                          _sortOption == PlaylistSortOption.artistName
                                              ? Icons.check
                                              : null,
                                          size: 20,
                                          color: _sortOption == PlaylistSortOption.artistName
                                              ? primaryColor
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                        const Text('Sort by Artist'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: PlaylistSortOption.songName,
                                    child: Row(
                                      children: [
                                        Icon(
                                          _sortOption == PlaylistSortOption.songName
                                              ? Icons.check
                                              : null,
                                          size: 20,
                                          color: _sortOption == PlaylistSortOption.songName
                                              ? primaryColor
                                              : null,
                                        ),
                                        const SizedBox(width: 8),
                                        const Text('Sort by Song'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              if (widget.queueService != null && widget.playerStateService != null) ...[
                                IconButton(
                                  icon: const Icon(Icons.play_arrow),
                                  onPressed: _playPlaylist,
                                  tooltip: 'Play playlist',
                                  iconSize: 32,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.shuffle),
                                  onPressed: _shufflePlaylistToQueue,
                                  tooltip: 'Shuffle and add playlist to queue',
                                ),
                                IconButton(
                                  icon: const Icon(Icons.queue_music),
                                  onPressed: _addPlaylistToQueue,
                                  tooltip: 'Add playlist to queue',
                                ),
                              ],
                              IconButton(
                                icon: const Icon(Icons.download),
                                onPressed: _downloadUndownloadedTracks,
                                tooltip: 'Download undownloaded tracks',
                              ),
                            ],
                          ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.music_note,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${_playlist.tracks.length} ${_playlist.tracks.length == 1 ? 'track' : 'tracks'}',
                                  style: Theme.of(context).textTheme.bodyMedium,
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
                          itemCount: _sortedTracks.length,
                          itemBuilder: (context, index) {
                            final track = _sortedTracks[index];
                            final isCurrentlyPlaying = widget.playerStateService != null &&
                                widget.playerStateService.currentTrackUrl?.contains(track.filename ?? '') == true;
                            
                            final displayTitle = getDisplayTitle(track.title, track.filename);
                            
                            return Column(
                              children: [
                                Material(
                                  color: isCurrentlyPlaying 
                                      ? primaryColor.withOpacity(0.1) 
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    onTap: () => _playTrack(track),
                                    borderRadius: BorderRadius.circular(8),
                                    hoverColor: surfaceHover,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: isCurrentlyPlaying 
                                                  ? primaryColor.withOpacity(0.2)
                                                  : surfaceHover,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Icon(
                                              Icons.music_note,
                                              color: isCurrentlyPlaying ? primaryColor : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  displayTitle,
                                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                    fontWeight: isCurrentlyPlaying ? FontWeight.w600 : FontWeight.w400,
                                                    color: isCurrentlyPlaying ? primaryColor : null,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                if (track.artist != null && track.artist!.isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    track.artist!,
                                                    style: Theme.of(context).textTheme.bodySmall,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Add to queue button
                                              if (widget.queueService != null)
                                                IconButton(
                                                  icon: const Icon(Icons.queue_music, size: 20),
                                                  onPressed: () => _addToQueue(track),
                                                  tooltip: 'Add to queue',
                                                ),
                                              // Download status icon
                                              _isTrackDownloaded(track)
                                                  ? IconButton(
                                                      icon: Icon(
                                                        Icons.check_circle,
                                                        color: primaryColor,
                                                        size: 20,
                                                      ),
                                                      onPressed: null,
                                                      tooltip: 'Downloaded',
                                                    )
                                                  : IconButton(
                                                      icon: const Icon(Icons.download_outlined, size: 20),
                                                      onPressed: () => _downloadTrack(track),
                                                      tooltip: 'Download',
                                                    ),
                                              // Delete button
                                              IconButton(
                                                icon: const Icon(Icons.delete_outline, size: 20),
                                                onPressed: () => _removeTrack(track),
                                                tooltip: 'Remove from playlist',
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const Divider(height: 1),
                              ],
                            );
                          },
                        ),
                ),
              ],
        );
  }
}
