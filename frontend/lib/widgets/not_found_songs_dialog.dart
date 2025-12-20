import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../widgets/video_card.dart';
import '../models/playlist.dart';

class NotFoundSongsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> notFoundSongs;
  final String? playlistId;
  final ApiService apiService;
  final PlaylistService playlistService;

  const NotFoundSongsDialog({
    super.key,
    required this.notFoundSongs,
    this.playlistId,
    required this.apiService,
    required this.playlistService,
  });

  @override
  State<NotFoundSongsDialog> createState() => _NotFoundSongsDialogState();
}

class _NotFoundSongsDialogState extends State<NotFoundSongsDialog> {
  int _currentSongIndex = 0;
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;
  Map<int, VideoInfo?> _selectedSongs = {}; // Track selected song for each not found song

  @override
  void initState() {
    super.initState();
    _searchForCurrentSong();
  }

  Future<void> _searchForCurrentSong() async {
    if (_currentSongIndex >= widget.notFoundSongs.length) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final song = widget.notFoundSongs[_currentSongIndex];
      final title = song['Track Name'] ?? '';
      final artist = song['Artist Name(s)'] ?? '';
      
      String query = title;
      if (artist.isNotEmpty && artist.toLowerCase() != 'unknown') {
        query = '$artist $title';
      }

      final results = await widget.apiService.searchYoutube(query);
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    } catch (e) {
      setState(() {
        _isSearching = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Search failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _selectSong(VideoInfo video) {
    setState(() {
      _selectedSongs[_currentSongIndex] = video;
    });
  }

  void _skipSong() {
    setState(() {
      _selectedSongs[_currentSongIndex] = null;
    });
  }

  Future<void> _nextSong() async {
    if (_currentSongIndex < widget.notFoundSongs.length - 1) {
      setState(() {
        _currentSongIndex++;
      });
      await _searchForCurrentSong();
    }
  }

  void _previousSong() {
    if (_currentSongIndex > 0) {
      setState(() {
        _currentSongIndex--;
      });
      _searchForCurrentSong();
    }
  }

  Future<void> _addSelectedSongsToPlaylist() async {
    if (widget.playlistId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No playlist ID available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      int addedCount = 0;
      for (int i = 0; i < widget.notFoundSongs.length; i++) {
        final selectedVideo = _selectedSongs[i];
        if (selectedVideo != null) {
          try {
            // Get streaming URL
            final result = await widget.apiService.getStreamingUrl(
              url: selectedVideo.url,
              title: selectedVideo.title,
              artist: selectedVideo.uploader,
            );

            // Create playlist track
            final trackJson = {
              'id': selectedVideo.id,
              'title': result.title,
              'artist': result.artist,
              'album': widget.notFoundSongs[i]['Album Name'] ?? '',
              'filename': '',
              'file_path': '',
              'url': selectedVideo.url,
              'thumbnail': selectedVideo.thumbnail,
              'duration': selectedVideo.duration,
            };

            // Add to playlist using direct API call
            await widget.apiService.addSongToPlaylist(
              widget.playlistId!,
              trackJson,
            );
            addedCount++;
          } catch (e) {
            // Continue with next song
          }
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        Navigator.of(context).pop(); // Close this dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added $addedCount song(s) to playlist'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding songs: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSong = widget.notFoundSongs[_currentSongIndex];
    final title = currentSong['Track Name'] ?? 'Unknown';
    final artist = currentSong['Artist Name(s)'] ?? 'Unknown';
    final album = currentSong['Album Name'] ?? '';
    final isLastSong = _currentSongIndex >= widget.notFoundSongs.length - 1;
    final hasSelection = _selectedSongs.containsKey(_currentSongIndex);

    return Dialog(
      child: Container(
        width: 800,
        height: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.warning_amber,
                  color: Colors.orange,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Songs Not Found (${_currentSongIndex + 1}/${widget.notFoundSongs.length})',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Current song info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (artist.isNotEmpty && artist.toLowerCase() != 'unknown') ...[
                    const SizedBox(height: 4),
                    Text(
                      'Artist: $artist',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                  if (album.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Album: $album',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Search results
            Expanded(
              child: _isSearching
                  ? const Center(child: CircularProgressIndicator())
                  : _searchResults.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.search_off,
                                size: 48,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No results found',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _searchResults.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final video = _searchResults[index];
                            final isSelected = _selectedSongs[_currentSongIndex]?.id == video.id;
                            
                            return VideoCard(
                              video: video,
                              onStream: null,
                              onDownload: null,
                              onAddToPlaylist: null,
                              onAddToQueue: null,
                              onTap: () => _selectSong(video),
                              isSelected: isSelected,
                            );
                          },
                        ),
            ),
            const SizedBox(height: 16),
            // Navigation and action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _currentSongIndex > 0 ? _previousSong : null,
                      tooltip: 'Previous',
                    ),
                    Text('${_currentSongIndex + 1}/${widget.notFoundSongs.length}'),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: !isLastSong ? _nextSong : null,
                      tooltip: 'Next',
                    ),
                  ],
                ),
                Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.skip_next),
                      label: const Text('Skip'),
                      onPressed: _skipSong,
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.check),
                      label: Text(isLastSong ? 'Finish & Add' : 'Next'),
                      onPressed: isLastSong
                          ? (_selectedSongs.values.any((v) => v != null))
                              ? _addSelectedSongsToPlaylist
                              : () => Navigator.of(context).pop()
                          : _nextSong,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

