import 'dart:math';
import 'package:flutter/material.dart';
import '../services/playlist_service.dart';
import '../services/api_service.dart';
import '../services/queue_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import 'add_to_playlist_screen.dart';
import '../utils/song_display_utils.dart';
import '../widgets/album_cover.dart';

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
  final Function(String)? onDownloadStart; // Callback to start download progress tracking

  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.playlistService,
    this.playerStateService,
    this.queueService,
    this.onBack,
    this.onDownloadStart,
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
  DateTime? _lastSyncTime;

  @override
  void initState() {
    super.initState();
    _playlist = widget.playlist;
    _loadPlaylist();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (mounted && !_isLoading) {
      final now = DateTime.now();
      if (_lastSyncTime == null || 
          now.difference(_lastSyncTime!).inSeconds >= 2) {
        _lastSyncTime = now;
        _syncDownloadedFiles();
      }
    }
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
        
        // Sync downloaded files with playlist tracks
        _syncDownloadedFiles();
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

  Future<void> _syncDownloadedFiles() async {
    // Check if any tracks need to be updated with downloaded filenames
    final tracksNeedingUpdate = _playlist.tracks.where((track) => 
      track.filename.isEmpty && track.url != null && track.url!.isNotEmpty
    ).toList();
    
    if (tracksNeedingUpdate.isEmpty) return;
    
    try {
      // Get list of downloaded files
      final downloadedFiles = await _apiService.listDownloads();
      if (downloadedFiles.isEmpty) return;
      
      int updateCount = 0;
      final updatedTrackIds = <String>{};
      
      // Match tracks to downloaded files by title
      for (final track in tracksNeedingUpdate) {
        if (updatedTrackIds.contains(track.id)) continue;
        
        // Try to find matching downloaded file
        DownloadedFile? matchingFile;
        final trackTitle = track.title.toLowerCase().trim();
        
        for (final file in downloadedFiles) {
          final fileTitle = file.title?.toLowerCase().trim() ?? '';
          if (fileTitle.isNotEmpty) {
            // Match if titles are similar
            if (fileTitle == trackTitle ||
                fileTitle.contains(trackTitle) ||
                trackTitle.contains(fileTitle)) {
              matchingFile = file;
              break;
            }
          }
        }
        
        if (matchingFile != null) {
          try {
            final updatedTrack = PlaylistTrack(
              id: track.id,
              title: track.title,
              artist: track.artist,
              album: track.album,
              filename: matchingFile.filename,
              url: track.url,
              thumbnail: track.thumbnail,
              duration: track.duration,
            );

            await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
            await widget.playlistService.addTrackToPlaylist(_playlist.id, updatedTrack);
            updatedTrackIds.add(track.id);
            updateCount++;
          } catch (e) {
            print('Error syncing track ${track.title}: $e');
          }
        }
      }
      
      if (updateCount > 0) {
        // Reload playlist to show updated tracks
        await _loadPlaylist();
      }
    } catch (e) {
      print('Error syncing downloaded files: $e');
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
        // Return tracks in original order
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
      // Use batch download API for progress tracking
      final downloads = [
        {
          'url': track.url!,
          'title': track.title,
          'artist': track.artist ?? '',
          'album': track.album ?? '',
          'output_format': 'm4a',
          'embed_thumbnail': true,
        }
      ];

      final result = await _apiService.startBatchDownload(downloads);
      final downloadId = result['download_id'] as String;

      // Start progress tracking if callback is provided
      if (widget.onDownloadStart != null) {
        widget.onDownloadStart!(downloadId);
      }

      // Poll for completion and update playlist
      _waitForDownloadAndUpdate(downloadId, [track]);
    } catch (e) {
      if (mounted) {
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

  Future<void> _waitForDownloadAndUpdate(String downloadId, List<PlaylistTrack> tracks) async {
    // Poll until download is complete
    while (mounted) {
      try {
        final progress = await _apiService.getDownloadProgress(downloadId);
        
        if (progress.isCompleted) {
          // Update tracks with downloaded filenames
          final updatedTrackIds = <String>{};
          int updateCount = 0;
          
          print('Progress completed. Downloads: ${progress.downloads.length}, Tracks: ${tracks.length}');
          
          for (int i = 0; i < progress.downloads.length && i < tracks.length; i++) {
            final downloadResult = progress.downloads[i];
            final track = tracks[i];
            
            if (downloadResult['success'] == true && 
                downloadResult['filename'] != null &&
                downloadResult['filename'].toString().isNotEmpty &&
                !updatedTrackIds.contains(track.id)) {
              
              try {
                final filename = downloadResult['filename'] as String;
                print('Updating track ${track.title} (index $i) with filename: $filename');
                
                final updatedTrack = PlaylistTrack(
                  id: track.id,
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  filename: filename,
                  url: track.url,
                  thumbnail: track.thumbnail,
                  duration: track.duration,
                );

                print('Removing track ${track.id} from playlist');
                await widget.playlistService.removeTrackFromPlaylist(_playlist.id, track.id);
                
                print('Adding updated track ${track.id} to playlist with filename: $filename');
                await widget.playlistService.addTrackToPlaylist(_playlist.id, updatedTrack);
                
                updatedTrackIds.add(track.id);
                updateCount++;
                print('Successfully updated track ${track.title}');
              } catch (e) {
                print('Error updating track ${track.title}: $e');
              }
            } else {
              print('Skipping track ${track.title} (index $i): success=${downloadResult['success']}, filename=${downloadResult['filename']}, alreadyUpdated=${updatedTrackIds.contains(track.id)}');
            }
          }
          
          print('Updated $updateCount out of ${tracks.length} tracks with downloaded filenames');

          // Wait a moment for all updates to complete
          await Future.delayed(const Duration(milliseconds: 300));

          // Reload playlist to show updated tracks
          await _loadPlaylist();

          if (mounted) {
            final successCount = progress.processed;
            final failCount = progress.failed;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  failCount > 0
                      ? 'Downloaded $successCount ${successCount == 1 ? 'track' : 'tracks'}${failCount > 0 ? ' ($failCount failed)' : ''}'
                      : 'Downloaded ${successCount} ${successCount == 1 ? 'track' : 'tracks'}',
                ),
                backgroundColor: failCount > 0 ? Colors.orange : null,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
          }
          break;
        } else if (progress.hasError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Download error: ${progress.status}'),
                backgroundColor: Colors.red,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          break;
        }
        
        // Wait before polling again
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        // If progress is not available, the download might have finished
        await _loadPlaylist();
        break;
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

    try {
      // Prepare batch download requests
      final downloads = tracksToDownload.map((track) => {
        'url': track.url!,
        'title': track.title,
        'artist': track.artist ?? '',
        'album': track.album ?? '',
        'output_format': 'm4a',
        'embed_thumbnail': true,
      }).toList();

      // Start batch download
      final result = await _apiService.startBatchDownload(downloads);
      final downloadId = result['download_id'] as String;

      // Start progress tracking
      if (widget.onDownloadStart != null) {
        widget.onDownloadStart!(downloadId);
      }

      // Wait for download to complete and update playlist
      await _waitForDownloadAndUpdate(downloadId, tracksToDownload);
    } catch (e) {
      if (mounted) {
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
        Navigator.of(context).pop();

        if (queueItems.isNotEmpty) {
          widget.queueService!.clearQueue();
          widget.queueService!.addAllToQueue(queueItems);
          
          // Start playing the first item
          await widget.queueService!.playItem(0, widget.playerStateService!);
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

          // If shuffle is enabled, start playing the first song
          if (shuffle && widget.playerStateService != null) {
            await widget.queueService!.playItem(0, widget.playerStateService!);
          }
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
                          // Title row
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _playlist.name,
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Track count (left) + secondary actions (right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
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
                              const SizedBox(width: 12),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      TextButton.icon(
                                        onPressed: _addSongs,
                                        icon: const Icon(Icons.add, size: 18),
                                        label: const Text('Add songs'),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 20),
                                        onPressed: _renamePlaylist,
                                        tooltip: 'Rename playlist',
                                      ),
                                      if (widget.queueService != null && widget.playerStateService != null)
                                        IconButton(
                                          icon: const Icon(Icons.queue_music, size: 20),
                                          onPressed: _addPlaylistToQueue,
                                          tooltip: 'Add playlist to queue',
                                        ),
                                      IconButton(
                                        icon: const Icon(Icons.download, size: 20),
                                        onPressed: _downloadUndownloadedTracks,
                                        tooltip: 'Download undownloaded tracks',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Play / Shuffle (left) + Sort by (right)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (widget.queueService != null && widget.playerStateService != null)
                                Row(
                                  children: [
                                    FilledButton.icon(
                                      onPressed: _playPlaylist,
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(24),
                                        ),
                                      ),
                                      icon: const Icon(Icons.play_arrow_rounded, size: 26),
                                      label: const Text(
                                        'Play',
                                        style: TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: _shufflePlaylistToQueue,
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(24),
                                        ),
                                      ),
                                      icon: const Icon(Icons.shuffle, size: 22),
                                      label: const Text(
                                        'Shuffle',
                                        style: TextStyle(fontWeight: FontWeight.w500),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                const SizedBox.shrink(),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Sort by:',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                  const SizedBox(width: 8),
                                  DropdownButton<PlaylistSortOption>(
                                    value: _sortOption,
                                    underline: const SizedBox.shrink(),
                                    borderRadius: BorderRadius.circular(12),
                                    onChanged: _changeSortOption,
                                    items: const [
                                      DropdownMenuItem(
                                        value: PlaylistSortOption.defaultOrder,
                                        child: Text('Default'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaylistSortOption.artistName,
                                        child: Text('Artist'),
                                      ),
                                      DropdownMenuItem(
                                        value: PlaylistSortOption.songName,
                                        child: Text('Song'),
                                      ),
                                    ],
                                  ),
                                ],
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
                                          AlbumCover(
                                            filename: track.filename.isNotEmpty ? track.filename : null,
                                            title: track.title,
                                            artist: track.artist,
                                            album: track.album,
                                            size: 40,
                                            backgroundColor: isCurrentlyPlaying 
                                                ? primaryColor.withOpacity(0.2)
                                                : surfaceHover,
                                            iconColor: isCurrentlyPlaying 
                                                ? primaryColor 
                                                : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
