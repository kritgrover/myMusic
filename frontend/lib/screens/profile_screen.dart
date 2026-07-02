import 'package:flutter/material.dart';
import '../utils/responsive_utils.dart';

import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../services/friends_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../models/queue_item.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../widgets/album_cover.dart';
import '../widgets/empty_state_widget.dart';
import '../widgets/profile_header.dart';
import '../models/playlist.dart';
import 'spotify_playlist_screen.dart';

class ProfileScreen extends StatefulWidget {
  final AuthService authService;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final VoidCallback? onOpenFriends;

  const ProfileScreen({
    super.key,
    required this.authService,
    required this.playerStateService,
    required this.queueService,
    this.onOpenFriends,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ProfileService _profileService = ProfileService();
  final FriendsService _friendsService = FriendsService();
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _taglineController = TextEditingController();

  UserProfile? _profile;
  AnalyticsRecap? _recap;
  List<ProfileHistoryItem> _history = [];
  List<Playlist> _publicPlaylists = [];
  String _selectedPeriod = 'weekly';
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.authService.username ?? '';
    _taglineController.text = widget.authService.tagline;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final profileFuture = _profileService.getProfile();
      final historyFuture = _profileService.getRecentHistory(limit: 20);
      final recapFuture = _profileService.getAnalyticsRecap(period: _selectedPeriod);
      final results = await Future.wait([
        profileFuture,
        historyFuture,
        recapFuture,
      ]);
      final profile = results[0] as UserProfile;
      // The user's own public playlists (same view friends get).
      List<Playlist> publicPlaylists = [];
      try {
        publicPlaylists = await _friendsService.getUserPlaylists(profile.id);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _history = results[1] as List<ProfileHistoryItem>;
        _recap = results[2] as AnalyticsRecap;
        _publicPlaylists = publicPlaylists;
        _usernameController.text = profile.username;
        _taglineController.text = profile.tagline;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load profile data.';
        _isLoading = false;
      });
    }
  }

  Future<void> _reloadRecap() async {
    try {
      final recap = await _profileService.getAnalyticsRecap(period: _selectedPeriod);
      if (!mounted) return;
      setState(() {
        _recap = recap;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load analytics recap.';
      });
    }
  }

  Future<void> _saveProfile() async {
    final username = _usernameController.text.trim();
    final tagline = _taglineController.text.trim();
    if (username.isEmpty) {
      setState(() {
        _error = 'Username cannot be empty.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final updated = await _profileService.updateProfile(
        username: username,
        tagline: tagline,
      );
      await widget.authService.updateProfileCache(
        username: updated.username,
        tagline: updated.tagline,
      );
      if (!mounted) return;
      setState(() {
        _profile = updated;
        _isSaving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not save profile changes.';
        _isSaving = false;
      });
    }
  }

  Future<void> _playTrack(ProfileHistoryItem item) async {
    try {
      // Search YouTube for this track
      final searchResults = await _apiService.searchYoutube(
        '${item.title} ${item.artist}',
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find "${item.title}" on YouTube')),
          );
        }
        return;
      }

      // Get streaming URL for the first result
      final result = await _apiService.getStreamingUrl(
        url: searchResults.first.url,
        title: item.title,
        artist: item.artist,
      );

      await widget.playerStateService.streamTrack(
        result.streamingUrl,
        trackName: result.title,
        trackArtist: result.artist,
        url: searchResults.first.url,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play: $e')),
        );
      }
    }
  }

  Future<void> _addToQueue(ProfileHistoryItem item, {bool showSnackbar = true}) async {
    try {
      // Search YouTube for this track first
      final searchResults = await _apiService.searchYoutube(
        '${item.title} ${item.artist}',
      );

      if (searchResults.isEmpty) {
        if (mounted && showSnackbar) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find "${item.title}" on YouTube')),
          );
        }
        return;
      }

      final cleaned = await _apiService.cleanMetadata(
        title: searchResults.first.title,
        uploader: searchResults.first.uploader,
        videoId: searchResults.first.id,
        videoUrl: searchResults.first.url,
      );

      final result = await _apiService.getStreamingUrl(
        url: searchResults.first.url,
        title: cleaned['title']!,
        artist: cleaned['artist']!,
      );

      final queueItem = QueueItem(
        id: searchResults.first.id,
        title: result.title,
        artist: result.artist,
        url: result.streamingUrl,
        thumbnail: searchResults.first.thumbnail,
      );

      widget.queueService.addToQueue(queueItem);

      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${cleaned['title']}" to queue')),
        );
      }
    } catch (e) {
      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add to queue: $e')),
        );
      }
    }
  }

  Future<void> _showAddToPlaylistDialog(ProfileHistoryItem item) async {
    try {
      // Search YouTube to get VideoInfo-like structure
      final searchResults = await _apiService.searchYoutube(
        '${item.title} ${item.artist}',
      );

      if (searchResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not find "${item.title}" on YouTube')),
          );
        }
        return;
      }

      final videoInfo = searchResults.first;
      final track = PlaylistTrack.fromVideoInfo(videoInfo);
      
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => PlaylistSelectionDialog(
          playlistService: _playlistService,
          track: track,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add to playlist: $e')),
        );
      }
    }
  }

  Future<void> _editProfileDialog() async {
    _usernameController.text = _profile?.username ?? _usernameController.text;
    _taglineController.text = _profile?.tagline ?? _taglineController.text;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _taglineController,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Tagline', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await _saveProfile();
              if (mounted) Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String? _httpCover(Playlist playlist) {
    final cover = playlist.coverImage;
    if (cover != null && (cover.startsWith('http://') || cover.startsWith('https://'))) return cover;
    if (playlist.tracks.isNotEmpty) return playlist.tracks.first.thumbnail;
    return null;
  }

  void _openOwnPublicPlaylist(Playlist playlist) {
    final id = _profile?.id;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SpotifyPlaylistScreen(
        playlistId: playlist.id,
        playlistName: playlist.name,
        coverUrl: _httpCover(playlist),
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        recentlyPlayedService: null,
        trackLoader: id == null
            ? null
            : () async {
                final full = await _friendsService.getUserPlaylist(id, playlist.id);
                return full.tracks;
              },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _profile == null) {
      return EmptyStateWidget(
        icon: Icons.error_outline,
        title: 'Could not load profile',
        subtitle: _error!,
        onAction: _loadData,
        actionLabel: 'Retry',
      );
    }

    final recap = _recap;
    final topGenre = (recap?.topGenres.isNotEmpty ?? false) ? recap!.topGenres.first : '-';
    final topArtist = (recap?.topArtists.isNotEmpty ?? false) ? recap!.topArtists.first.artist : '-';
    final profile = _profile;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          ProfileHeader(
            name: profile?.username ?? '',
            tagline: profile?.tagline ?? '',
            followerCount: profile?.followerCount ?? 0,
            followingCount: profile?.followingCount ?? 0,
            publicPlaylistCount: profile?.publicPlaylistCount ?? 0,
            isSelf: true,
            onEdit: _editProfileDialog,
            onFollowingTap: widget.onOpenFriends,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                // Public playlists
                if (_publicPlaylists.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Public playlists',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: _publicPlaylists
                        .map((p) => _PublicPlaylistTile(
                              name: p.name,
                              trackCount: p.tracks.length,
                              coverUrl: _httpCover(p),
                              onTap: () => _openOwnPublicPlaylist(p),
                            ))
                        .toList(),
                  ),
                ],
                // Recap
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your recap',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                      ),
                    ),
                    _periodChip('Weekly', 'weekly'),
                    const SizedBox(width: 8),
                    _periodChip('Monthly', 'monthly'),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _StatCard(label: 'Plays', value: '${recap?.totals.plays ?? 0}', icon: Icons.play_circle_outline),
                    _StatCard(label: 'Minutes', value: (recap?.totals.minutes ?? 0).toStringAsFixed(1), icon: Icons.timer_outlined),
                    _StatCard(label: 'Unique Artists', value: '${recap?.totals.uniqueArtists ?? 0}', icon: Icons.people_outline),
                    _StatCard(label: 'Top Artist', value: topArtist, icon: Icons.person),
                    _StatCard(label: 'Top Genre', value: topGenre, icon: Icons.music_note),
                  ],
                ),
                // History
                const SizedBox(height: 28),
                Text(
                  'Recent history',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                ),
                const SizedBox(height: 12),
                if (_history.isEmpty)
                  EmptyStateWidget(
                    icon: Icons.history,
                    title: 'No recent history yet',
                    subtitle: 'Start listening and your tracks will appear here.',
                  )
                else
                  ..._history.map((item) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _HistoryListTile(
                        item: item,
                        onPlay: () => _playTrack(item),
                        onAddToQueue: () => _addToQueue(item),
                        onAddToPlaylist: () => _showAddToPlaylistDialog(item),
                        formatTimestamp: _formatTimestamp,
                      ),
                    );
                  }),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _periodChip(String label, String period) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return FilterChip(
      label: Text(label),
      selected: _selectedPeriod == period,
      onSelected: (_) {
        setState(() => _selectedPeriod = period);
        _reloadRecap();
      },
      selectedColor: primaryColor.withOpacity(0.2),
      checkmarkColor: primaryColor,
    );
  }

  String _formatTimestamp(DateTime dateTime) {
    return '${dateTime.year}-${_two(dateTime.month)}-${_two(dateTime.day)} ${_two(dateTime.hour)}:${_two(dateTime.minute)}';
  }

  String _two(int value) => value < 10 ? '0$value' : '$value';

  @override
  void dispose() {
    _usernameController.dispose();
    _taglineController.dispose();
    super.dispose();
  }
}

class _PublicPlaylistTile extends StatelessWidget {
  final String name;
  final int trackCount;
  final String? coverUrl;
  final VoidCallback onTap;

  const _PublicPlaylistTile({
    required this.name,
    required this.trackCount,
    required this.onTap,
    this.coverUrl,
  });

  @override
  Widget build(BuildContext context) {
    final width = ResponsiveUtils.responsiveValue<double>(context, compact: 140, medium: 150, expanded: 160);
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: (coverUrl != null && coverUrl!.isNotEmpty)
                    ? Image.network(
                        coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(context),
                      )
                    : _placeholder(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              '$trackCount ${trackCount == 1 ? 'track' : 'tracks'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Icon(Icons.queue_music, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

class _StatCard extends StatefulWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  State<_StatCard> createState() => _StatCardState();
}

class _StatCardState extends State<_StatCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final surfaceVariant = Theme.of(context).colorScheme.surfaceVariant;
    final surface = Theme.of(context).colorScheme.surface;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: SizedBox(
        width: ResponsiveUtils.responsiveValue<double>(context, compact: 140, medium: 155, expanded: 170),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                surfaceVariant.withOpacity(_isHovered ? 0.9 : 0.6),
                surface.withOpacity(0.8),
              ],
            ),
            border: Border.all(
              color: primaryColor.withOpacity(_isHovered ? 0.15 : 0.06),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 18,
                      color: primaryColor.withOpacity(0.8),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryListTile extends StatelessWidget {
  final ProfileHistoryItem item;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onAddToPlaylist;
  final String Function(DateTime) formatTimestamp;

  const _HistoryListTile({
    required this.item,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    required this.formatTimestamp,
  });

  @override
  Widget build(BuildContext context) {
    final surfaceHover = Theme.of(context).colorScheme.surfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(12),
        hoverColor: surfaceHover.withOpacity(0.5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(
              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AlbumCover(
                  title: item.title,
                  artist: item.artist,
                  size: 48,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.artist} • ${formatTimestamp(item.playedAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.playlist_add, size: 20),
                    tooltip: 'Add to playlist',
                    onPressed: onAddToPlaylist,
                  ),
                  IconButton(
                    icon: const Icon(Icons.queue_music, size: 20),
                    tooltip: 'Add to queue',
                    onPressed: onAddToQueue,
                  ),
                  IconButton(
                    icon: const Icon(Icons.play_arrow, size: 20),
                    tooltip: 'Play',
                    onPressed: onPlay,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
