import 'package:flutter/material.dart';
import '../services/playlist_service.dart';
import '../services/api_service.dart';
import '../models/playlist.dart';
import '../utils/song_display_utils.dart';

const Color neonBlue = Color(0xFF00D9FF);

class AddToPlaylistScreen extends StatefulWidget {
  final String playlistId;
  final PlaylistService playlistService;

  const AddToPlaylistScreen({
    super.key,
    required this.playlistId,
    required this.playlistService,
  });

  @override
  State<AddToPlaylistScreen> createState() => _AddToPlaylistScreenState();
}

class _AddToPlaylistScreenState extends State<AddToPlaylistScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  List<VideoInfo> _searchResults = [];
  bool _isSearching = false;
  List<DownloadedFile> _downloads = [];
  bool _isLoadingDownloads = false;
  late TabController _tabController;
  Playlist? _playlist;
  bool _isLoadingPlaylist = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadPlaylist();
    _loadDownloads();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoadingPlaylist = true;
    });

    try {
      final playlist = await widget.playlistService.getPlaylist(widget.playlistId);
      setState(() {
        _playlist = playlist;
        _isLoadingPlaylist = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingPlaylist = false;
      });
    }
  }

  Future<void> _loadDownloads() async {
    setState(() {
      _isLoadingDownloads = true;
    });

    try {
      final downloads = await _apiService.listDownloads();
      setState(() {
        _downloads = downloads;
        _isLoadingDownloads = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingDownloads = false;
      });
    }
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      final results = await _apiService.searchYoutube(query, deepSearch: true);
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
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    }
  }

  Future<void> _addVideoToPlaylist(VideoInfo video) async {
    try {
      final track = PlaylistTrack.fromVideoInfo(video);
      await widget.playlistService.addTrackToPlaylist(widget.playlistId, track);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${video.title}" to playlist'),
            backgroundColor: neonBlue,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _addDownloadToPlaylist(DownloadedFile file) async {
    try {
      final track = PlaylistTrack.fromDownloadedFile(file);
      await widget.playlistService.addTrackToPlaylist(widget.playlistId, track);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${getDisplayTitle(file.title, file.filename)}" to playlist'),
            backgroundColor: neonBlue,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final playlistName = _playlist?.name ?? 'Playlist';
    
    return Scaffold(
      appBar: AppBar(
        title: Text('Add Songs to $playlistName'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: neonBlue,
          labelColor: neonBlue,
          unselectedLabelColor: Colors.grey[400],
          tabs: const [
            Tab(icon: Icon(Icons.search), text: 'Search'),
            Tab(icon: Icon(Icons.download), text: 'Downloads'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // Search Tab
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search for music...',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _performSearch,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _performSearch(),
                ),
              ),
              Expanded(
                child: _isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : _searchResults.isEmpty
                        ? Center(
                            child: Text(
                              _searchController.text.isEmpty
                                  ? 'Enter a search query to find music'
                                  : 'No results found',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          )
                        : ListView.builder(
                            itemCount: _searchResults.length,
                            itemBuilder: (context, index) {
                              final video = _searchResults[index];
                              return Column(
                                children: [
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () => _addVideoToPlaylist(video),
                                      hoverColor: neonBlue.withOpacity(0.15),
                                      child: ListTile(
                                        leading: Icon(
                                          Icons.music_video,
                                          color: neonBlue,
                                        ),
                                        title: Text(
                                          video.title,
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        subtitle: Text(
                                          video.uploader,
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            color: Colors.grey[400],
                                          ),
                                        ),
                                        trailing: Icon(
                                          Icons.add_circle_outline,
                                          color: neonBlue,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Colors.grey[800],
                                  ),
                                ],
                              );
                            },
                          ),
              ),
            ],
          ),
          // Downloads Tab
          _isLoadingDownloads
              ? const Center(child: CircularProgressIndicator())
              : _downloads.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.download_done,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No downloads yet',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadDownloads,
                      child: ListView.builder(
                        itemCount: _downloads.length,
                        itemBuilder: (context, index) {
                          final file = _downloads[index];
                          return Column(
                            children: [
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => _addDownloadToPlaylist(file),
                                  hoverColor: neonBlue.withOpacity(0.15),
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.music_note,
                                      color: neonBlue,
                                    ),
                                    title: Text(
                                      getDisplayTitle(file.title, file.filename),
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    subtitle: file.artist != null && file.artist!.isNotEmpty
                                        ? Text(
                                            file.artist!,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                              color: Colors.grey[400],
                                            ),
                                          )
                                        : Text(
                                            file.formattedSize,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                              color: Colors.grey[400],
                                            ),
                                          ),
                                    trailing: Icon(
                                      Icons.add_circle_outline,
                                      color: neonBlue,
                                    ),
                                  ),
                                ),
                              ),
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: Colors.grey[800],
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

