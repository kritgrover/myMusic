import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';
import '../services/auth_http_client.dart';
import '../services/player_state_service.dart';
import '../services/playlist_service.dart';
import '../services/queue_service.dart';
import '../services/recently_played_service.dart';
import '../services/saved_music_service.dart';
import '../services/track_playback_helper.dart';
import '../utils/responsive_utils.dart';
import '../widgets/save_music_button.dart';
import '../widgets/save_track_button.dart';
import 'album_detail_screen.dart';
import 'artist_screen.dart';

class SavedMusicScreen extends StatefulWidget {
  final SavedMusicKind kind;
  final PlayerStateService playerStateService;
  final QueueService queueService;
  final RecentlyPlayedService? recentlyPlayedService;
  final SavedMusicService? service;
  const SavedMusicScreen(
      {super.key,
      required this.kind,
      required this.playerStateService,
      required this.queueService,
      this.recentlyPlayedService,
      this.service});
  @override
  State<SavedMusicScreen> createState() => _SavedMusicScreenState();
}

class _SavedMusicScreenState extends State<SavedMusicScreen> {
  late final SavedMusicService _service;
  late final TrackPlaybackHelper _playback;
  SavedMusicKind get _kind => widget.kind;
  String _query = '';
  bool _sortByName = false;
  @override
  void initState() {
    super.initState();
    _service = widget.service ?? SavedMusicService.shared;
    _playback = TrackPlaybackHelper(
        apiService: ApiService(),
        queueService: widget.queueService,
        playerStateService: widget.playerStateService,
        playlistService: PlaylistService());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load({bool force = false}) async {
    try {
      await _service.load(force: force);
    } catch (_) {
      // The visible error panel provides a retry while preserving existing rows.
    }
  }

  String _title(SavedMusicKind kind) => switch (kind) {
        SavedMusicKind.tracks => 'Liked Songs',
        SavedMusicKind.albums => 'Saved Albums',
        SavedMusicKind.artists => 'Followed Artists',
      };
  IconData _icon(SavedMusicKind kind) => switch (kind) {
        SavedMusicKind.tracks => Icons.favorite,
        SavedMusicKind.albums => Icons.album,
        SavedMusicKind.artists => Icons.people_alt,
      };
  bool _matches(String value) =>
      value.toLowerCase().contains(_query.trim().toLowerCase());

  String _countLabel(int count) {
    final noun = switch (_kind) {
      SavedMusicKind.tracks => 'song',
      SavedMusicKind.albums => 'album',
      SavedMusicKind.artists => 'artist',
    };
    return '$count $noun${count == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final tracks = _service.tracks
            .where((track) => _matches('${track.title} ${track.artist ?? ''}'))
            .toList();
        final albums = _service.albums
            .where((album) => _matches('${album.title} ${album.artist ?? ''}'))
            .toList();
        final artists =
            _service.artists.where((artist) => _matches(artist.name)).toList();
        if (_sortByName) {
          tracks.sort(
              (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
          albums.sort(
              (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
          artists.sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
        final count = switch (_kind) {
          SavedMusicKind.tracks => tracks.length,
          SavedMusicKind.albums => albums.length,
          SavedMusicKind.artists => artists.length,
        };
        return Scaffold(
            appBar: AppBar(title: Text(_title(_kind)), actions: [
              IconButton(
                  tooltip: 'Refresh saved music',
                  onPressed:
                      _service.isLoading ? null : () => _load(force: true),
                  icon: const Icon(Icons.refresh)),
            ]),
            body: !_service.isLoaded && _service.error == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding:
                        ResponsiveUtils.responsiveHorizontalPadding(context),
                    children: [
                        const SizedBox(height: 12),
                        Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                gradient: LinearGradient(colors: [
                                  Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.45),
                                  Theme.of(context).colorScheme.surface
                                ])),
                            child: Row(children: [
                              Icon(_icon(_kind),
                                  size: 52,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 20),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text('YOUR LIBRARY',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall),
                                    Text(_title(_kind),
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold)),
                                    Text(_countLabel(count)),
                                  ])),
                            ])),
                        const SizedBox(height: 16),
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  decoration: const InputDecoration(
                                      hintText: 'Search saved music',
                                      prefixIcon: Icon(Icons.search)),
                                  onChanged: (value) =>
                                      setState(() => _query = value))),
                          PopupMenuButton<bool>(
                              tooltip: 'Sort saved music',
                              initialValue: _sortByName,
                              icon: const Icon(Icons.sort),
                              onSelected: (value) =>
                                  setState(() => _sortByName = value),
                              itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: false,
                                        child: Text('Recently saved')),
                                    PopupMenuItem(
                                        value: true, child: Text('Name'))
                                  ]),
                        ]),
                        if (_service.error != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Wrap(
                                  spacing: 12,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(_service.error!),
                                    TextButton.icon(
                                        onPressed: () => _load(force: true),
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('Retry')),
                                  ])),
                        if (_kind == SavedMusicKind.tracks && tracks.isNotEmpty)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: FilledButton.icon(
                                      onPressed: () =>
                                          _playback.playAll(context, tracks),
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('Play Liked Songs')))),
                        if (count == 0 && _service.isLoaded)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 40),
                              child: Column(children: [
                                Icon(_icon(_kind), size: 48),
                                const SizedBox(height: 12),
                                Text(
                                    _query.isNotEmpty
                                        ? 'No saved music matches your search'
                                        : switch (_kind) {
                                            SavedMusicKind.tracks =>
                                              'Your favorites belong here',
                                            SavedMusicKind.albums =>
                                              'Keep your favorite albums close',
                                            SavedMusicKind.artists =>
                                              'Follow the artists you love',
                                          },
                                    textAlign: TextAlign.center,
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                if (_query.isEmpty)
                                  Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                          switch (_kind) {
                                            SavedMusicKind.tracks =>
                                              'Tap the heart on a song to add it to Liked Songs.',
                                            SavedMusicKind.albums =>
                                              'Open an album and choose Save album to find it here.',
                                            SavedMusicKind.artists =>
                                              'Open an artist and choose Follow to find them here.',
                                          },
                                          textAlign: TextAlign.center)),
                              ])),
                        if (_kind == SavedMusicKind.tracks)
                          ...tracks.map(_trackRow),
                        if (_kind == SavedMusicKind.albums)
                          ...albums.map(_albumRow),
                        if (_kind == SavedMusicKind.artists)
                          ...artists.map(_artistRow),
                        SizedBox(
                            height:
                                ResponsiveUtils.responsivePlayerBottomPadding(
                                    context)),
                      ]));
      });

  Widget _art(String? url, IconData icon) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url != null && url.isNotEmpty
          ? Image.network(AuthHttpClient.shared.cacheScopedUrl(url),
              headers: AuthHttpClient.shared.authHeadersForUrl(url),
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  SizedBox(width: 48, height: 48, child: Icon(icon)))
          : SizedBox(width: 48, height: 48, child: Icon(icon)));
  Widget _trackRow(PlaylistTrack track) => ListTile(
      leading: _art(track.thumbnail, Icons.music_note),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.artist ?? '',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _playback.playTrack(context, track),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        SaveTrackButton(track: track, service: _service, compact: true),
        PopupMenuButton<String>(
            tooltip: 'Song actions',
            onSelected: (action) {
              if (action == 'queue') _playback.addToQueue(context, track);
              if (action == 'playlist') _playback.addToPlaylist(context, track);
            },
            itemBuilder: (_) => const [
                  PopupMenuItem(value: 'queue', child: Text('Add to queue')),
                  PopupMenuItem(
                      value: 'playlist', child: Text('Add to playlist')),
                ]),
      ]));
  Widget _albumRow(SavedAlbum album) => ListTile(
      leading: _art(album.thumbnail, Icons.album),
      title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(album.artist ?? '',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: SaveAlbumButton(album: album, service: _service),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AlbumDetailScreen(
              albumId: album.id,
              albumName: album.title,
              artist: album.artist,
              coverUrl: album.thumbnail,
              playerStateService: widget.playerStateService,
              queueService: widget.queueService,
              recentlyPlayedService: widget.recentlyPlayedService))));
  Widget _artistRow(SavedArtist artist) => ListTile(
      leading: _art(artist.thumbnail, Icons.person),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: FollowArtistButton(artist: artist, service: _service),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ArtistScreen(
              artistId: artist.id,
              artistName: artist.name,
              playerStateService: widget.playerStateService,
              queueService: widget.queueService,
              recentlyPlayedService: widget.recentlyPlayedService))));
}
