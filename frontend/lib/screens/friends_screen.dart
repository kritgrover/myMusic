import 'dart:async';

import 'package:flutter/material.dart';

import '../services/friends_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import 'friend_profile_screen.dart';

/// Find-friends search + the list of users you currently follow.
class FriendsScreen extends StatefulWidget {
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;

  const FriendsScreen({
    super.key,
    required this.playerStateService,
    required this.queueService,
    this.recentlyPlayedService,
  });

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final FriendsService _friendsService = FriendsService();
  final TextEditingController _searchController = TextEditingController();

  Timer? _debounce;
  String _query = '';
  List<PublicUser> _results = [];
  List<PublicUser> _following = [];
  bool _isSearching = false;
  bool _isLoadingFollowing = true;
  final Set<int> _followBusy = {};

  @override
  void initState() {
    super.initState();
    _loadFollowing();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFollowing() async {
    setState(() => _isLoadingFollowing = true);
    try {
      final following = await _friendsService.getFollowing();
      if (!mounted) return;
      setState(() {
        _following = following;
        _isLoadingFollowing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingFollowing = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _isSearching = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    try {
      final results = await _friendsService.searchUsers(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearching = false);
    }
  }

  bool _isFollowed(PublicUser user) {
    if (_following.any((u) => u.id == user.id)) return true;
    return user.isFollowing;
  }

  Future<void> _toggleFollow(PublicUser user) async {
    if (_followBusy.contains(user.id)) return;
    final currentlyFollowing = _isFollowed(user);
    setState(() => _followBusy.add(user.id));
    try {
      if (currentlyFollowing) {
        await _friendsService.unfollow(user.id);
        if (!mounted) return;
        setState(() => _following.removeWhere((u) => u.id == user.id));
      } else {
        await _friendsService.follow(user.id);
        if (!mounted) return;
        setState(() {
          if (!_following.any((u) => u.id == user.id)) {
            _following.insert(0, user.copyWith(isFollowing: true));
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _followBusy.remove(user.id));
    }
  }

  void _openProfile(PublicUser user) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => FriendProfileScreen(
            userId: user.id,
            initialUsername: user.username,
            playerStateService: widget.playerStateService,
            queueService: widget.queueService,
            recentlyPlayedService: widget.recentlyPlayedService,
          ),
        ))
        .then((_) => _loadFollowing());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: _runSearch,
              decoration: InputDecoration(
                hintText: 'Find people by username',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _runSearch('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_query.isNotEmpty) {
      if (_isSearching) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_results.isEmpty) {
        return Center(
          child: Text(
            'No users found for "$_query"',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        );
      }
      return ListView(
        children: _results.map(_buildUserTile).toList(),
      );
    }

    // No query: show the people you follow.
    if (_isLoadingFollowing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_following.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'You\'re not following anyone yet.\nSearch above to find friends.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFollowing,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Following',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          ..._following.map(_buildUserTile),
        ],
      ),
    );
  }

  Widget _buildUserTile(PublicUser user) {
    final letter = user.username.isNotEmpty ? user.username[0].toUpperCase() : '?';
    final followed = _isFollowed(user);
    final busy = _followBusy.contains(user.id);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          letter,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Text(user.username),
      subtitle: user.tagline.isNotEmpty ? Text(user.tagline, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
      trailing: TextButton.icon(
        onPressed: busy ? null : () => _toggleFollow(user),
        icon: Icon(followed ? Icons.check : Icons.person_add, size: 18),
        label: Text(followed ? 'Following' : 'Follow'),
      ),
      onTap: () => _openProfile(user),
    );
  }
}
