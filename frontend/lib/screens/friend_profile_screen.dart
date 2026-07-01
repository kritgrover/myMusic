import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/friends_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import 'spotify_playlist_screen.dart';

/// Shows another user's public profile: header card, follow/unfollow, and their
/// public playlists. Tapping a playlist opens it in [SpotifyPlaylistScreen] (reused
/// via its [trackLoader]) so every play/queue/download/add-to-playlist action works.
class FriendProfileScreen extends StatefulWidget {
  final int userId;
  final String initialUsername;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;

  const FriendProfileScreen({
    super.key,
    required this.userId,
    required this.initialUsername,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  final FriendsService _friendsService = FriendsService();

  FriendProfile? _profile;
  List<Playlist> _playlists = [];
  bool _isLoading = true;
  bool _isFollowBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _friendsService.getUserProfile(widget.userId),
        _friendsService.getUserPlaylists(widget.userId),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as FriendProfile;
        _playlists = results[1] as List<Playlist>;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this profile.';
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleFollow() async {
    final profile = _profile;
    if (profile == null || _isFollowBusy) return;
    setState(() => _isFollowBusy = true);
    final wasFollowing = profile.isFollowing;
    try {
      if (wasFollowing) {
        await _friendsService.unfollow(widget.userId);
      } else {
        await _friendsService.follow(widget.userId);
      }
      if (!mounted) return;
      setState(() {
        _profile = FriendProfile(
          id: profile.id,
          username: profile.username,
          tagline: profile.tagline,
          createdAt: profile.createdAt,
          isFollowing: !wasFollowing,
          publicPlaylistCount: profile.publicPlaylistCount,
        );
        _isFollowBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFollowBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $e')),
      );
    }
  }

  void _openPlaylist(Playlist playlist) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SpotifyPlaylistScreen(
        playlistId: playlist.id,
        playlistName: playlist.name,
        coverUrl: _coverUrlFor(playlist),
        playerStateService: widget.playerStateService,
        queueService: widget.queueService,
        // Intentionally null: a friend's playlist id is not a reopenable Spotify
        // id, so we don't register it as a "recently played playlist" (that would
        // create a dead home-screen tile). Individual songs are still recorded via
        // playerStateService.
        recentlyPlayedService: null,
        trackLoader: () async {
          final full = await _friendsService.getUserPlaylist(widget.userId, playlist.id);
          return full.tracks;
        },
        onSaveToLibrary: () async {
          await _friendsService.savePlaylistToLibrary(widget.userId, playlist.id);
        },
      ),
    ));
  }

  /// Only pass through absolute (http) cover URLs; locally-uploaded covers fall
  /// back to the first track's artwork inside the playlist screen / list tile.
  String? _coverUrlFor(Playlist playlist) {
    final cover = playlist.coverImage;
    if (cover != null && (cover.startsWith('http://') || cover.startsWith('https://'))) {
      return cover;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final username = _profile?.username ?? widget.initialUsername;
    return Scaffold(
      appBar: AppBar(title: Text(username)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildHeader(context, username),
                      const SizedBox(height: 24),
                      Text(
                        'Public playlists',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (_playlists.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'No public playlists yet.',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.6),
                              ),
                            ),
                          ),
                        )
                      else
                        ..._playlists.map((p) => _buildPlaylistTile(context, p)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeader(BuildContext context, String username) {
    final profile = _profile;
    final letter = username.isNotEmpty ? username[0].toUpperCase() : '?';
    return Row(
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            letter,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(username, style: Theme.of(context).textTheme.titleLarge),
              if ((profile?.tagline ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  profile!.tagline,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _isFollowBusy ? null : _toggleFollow,
                icon: Icon(
                  (profile?.isFollowing ?? false)
                      ? Icons.person_remove
                      : Icons.person_add,
                  size: 18,
                ),
                label: Text((profile?.isFollowing ?? false) ? 'Following' : 'Follow'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistTile(BuildContext context, Playlist playlist) {
    final cover = _coverUrlFor(playlist) ??
        (playlist.tracks.isNotEmpty ? playlist.tracks.first.thumbnail : null);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: (cover != null && cover.isNotEmpty)
              ? Image.network(
                  cover,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _coverPlaceholder(context),
                )
              : _coverPlaceholder(context),
        ),
        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${playlist.tracks.length} ${playlist.tracks.length == 1 ? 'track' : 'tracks'}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openPlaylist(playlist),
      ),
    );
  }

  Widget _coverPlaceholder(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Icon(Icons.playlist_play),
    );
  }
}
