import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../services/player_state_service.dart';
import '../services/queue_service.dart';
import '../services/api_service.dart';
import '../services/playlist_service.dart';
import '../models/queue_item.dart';
import '../widgets/playlist_selection_dialog.dart';
import '../models/playlist.dart';

class ProfileScreen extends StatefulWidget {
  final AuthService authService;
  final PlayerStateService playerStateService;
  final QueueService queueService;

  const ProfileScreen({
    super.key,
    required this.authService,
    required this.playerStateService,
    required this.queueService,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ProfileService _profileService = ProfileService();
  final ApiService _apiService = ApiService();
  final PlaylistService _playlistService = PlaylistService();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _taglineController = TextEditingController();

  UserProfile? _profile;
  AnalyticsRecap? _recap;
  List<ProfileHistoryItem> _history = [];
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
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _history = results[1] as List<ProfileHistoryItem>;
        _recap = results[2] as AnalyticsRecap;
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

      final result = await _apiService.getStreamingUrl(
        url: searchResults.first.url,
        title: item.title,
        artist: item.artist,
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
          SnackBar(content: Text('Added "${item.title}" to queue')),
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _profile == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final recap = _recap;
    final topGenre = (recap?.topGenres.isNotEmpty ?? false) ? recap!.topGenres.first : '-';
    final topArtist = (recap?.topArtists.isNotEmpty ?? false) ? recap!.topArtists.first.artist : '-';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Your Profile',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: _loadData,
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        child: Text(
                          (_usernameController.text.isNotEmpty ? _usernameController.text[0] : '?').toUpperCase(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _usernameController,
                              decoration: const InputDecoration(labelText: 'Username'),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _taglineController,
                              maxLength: 120,
                              decoration: const InputDecoration(labelText: 'Tagline'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveProfile,
                      child: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save Profile'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'Recap',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              ChoiceChip(
                label: const Text('Weekly'),
                selected: _selectedPeriod == 'weekly',
                onSelected: (_) {
                  setState(() {
                    _selectedPeriod = 'weekly';
                  });
                  _reloadRecap();
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Monthly'),
                selected: _selectedPeriod == 'monthly',
                onSelected: (_) {
                  setState(() {
                    _selectedPeriod = 'monthly';
                  });
                  _reloadRecap();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(label: 'Plays', value: '${recap?.totals.plays ?? 0}'),
              _StatCard(label: 'Minutes', value: (recap?.totals.minutes ?? 0).toStringAsFixed(1)),
              _StatCard(label: 'Unique Artists', value: '${recap?.totals.uniqueArtists ?? 0}'),
              _StatCard(label: 'Top Artist', value: topArtist),
              _StatCard(label: 'Top Genre', value: topGenre),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Recent History',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (_history.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No recent history yet. Start listening and it will appear here.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          else
            ..._history.map((item) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: const Icon(Icons.music_note),
                      ),
                    ),
                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${item.artist} • ${_formatTimestamp(item.playedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.playlist_add, size: 20),
                          tooltip: 'Add to playlist',
                          onPressed: () => _showAddToPlaylistDialog(item),
                        ),
                        IconButton(
                          icon: const Icon(Icons.queue_music, size: 20),
                          tooltip: 'Add to queue',
                          onPressed: () => _addToQueue(item),
                        ),
                        IconButton(
                          icon: const Icon(Icons.play_arrow, size: 20),
                          tooltip: 'Play',
                          onPressed: () => _playTrack(item),
                        ),
                      ],
                    ),
                    onTap: () => _playTrack(item),
                  ),
                ),
              );
            }),
        ],
      ),
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

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
