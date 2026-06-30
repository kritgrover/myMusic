import 'package:flutter/material.dart';
import 'api_service.dart';
import 'queue_service.dart';
import 'player_state_service.dart';
import 'playlist_service.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import '../widgets/playlist_selection_dialog.dart';

/// Centralizes the resolve -> clean -> stream/queue/download/add-to-playlist flow
/// for Spotify-sourced [PlaylistTrack]s so every discovery shelf and detail screen
/// behaves identically (clean names, lyrics, download, queue, playlist all intact).
///
/// Playback always resolves the track to a YouTube URL and streams via the backend
/// proxy, exactly like the existing home/genre/made-for-you flows. The clean Spotify
/// title/artist are passed straight through so the bottom player shows clean names.
class TrackPlaybackHelper {
  final ApiService apiService;
  final QueueService queueService;
  final PlayerStateService playerStateService;
  final PlaylistService playlistService;

  TrackPlaybackHelper({
    required this.apiService,
    required this.queueService,
    required this.playerStateService,
    required this.playlistService,
  });

  /// Lazy loader used by queued items: resolves originalUrl (Spotify/empty -> YouTube)
  /// then returns the backend streaming URL. Mirrors home_screen._loadStreamingUrlForAlbumItem.
  Future<String?> loadStreamingUrl(QueueItem item) async {
    final originalUrl = item.originalUrl;
    if (originalUrl == null) return null;
    try {
      String youtubeUrl = originalUrl;
      if (!youtubeUrl.contains('youtube.com') && !youtubeUrl.contains('youtu.be')) {
        final results = await apiService.searchYoutube('${item.title} ${item.artist ?? ''}');
        if (results.isEmpty) return null;
        final found = results.first.url;
        if (found.isEmpty) return null;
        youtubeUrl = found;
      }
      final result = await apiService.getStreamingUrl(
        url: youtubeUrl,
        title: item.title ?? '',
        artist: item.artist ?? '',
      );
      return result.streamingUrl;
    } catch (_) {
      return null;
    }
  }

  /// Play a single track immediately (replaces the queue with just this track).
  Future<void> playTrack(BuildContext context, PlaylistTrack track) async {
    try {
      final yt = await apiService.resolveToYouTubeUrl(track.url, track.title, track.artist);
      if (yt == null || yt.isEmpty) {
        _notFound(context, track.title);
        return;
      }
      final result = await apiService.getStreamingUrl(
        url: yt,
        title: track.title,
        artist: track.artist ?? '',
      );
      final item = QueueItem(
        id: 'track_${track.id}',
        title: result.title,
        artist: result.artist,
        album: track.album,
        url: result.streamingUrl,
        originalUrl: yt,
        thumbnail: track.thumbnail,
      );
      queueService.clearQueue();
      await queueService.addAndPlay(item, playerStateService);
    } catch (e) {
      _error(context, 'Failed to play: $e');
    }
  }

  /// Play a whole list of tracks (lazy streaming-URL loading, like the album flow).
  Future<void> playAll(BuildContext context, List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return;
    try {
      final items = tracks
          .map((t) => QueueItem.fromPlaylistTrackLazy(
                trackId: t.id,
                title: t.title,
                artist: t.artist,
                originalUrl: t.url ?? '',
                album: t.album,
                thumbnail: t.thumbnail,
              ))
          .toList();
      queueService.clearQueue();
      queueService.addAllToQueue(items, isPlaylistQueue: true, loadStreamingUrl: loadStreamingUrl);
      await queueService.playItem(0, playerStateService, loadStreamingUrl: loadStreamingUrl);
    } catch (e) {
      _error(context, 'Could not play: $e');
    }
  }

  Future<void> addToQueue(BuildContext context, PlaylistTrack track, {bool showSnackbar = true}) async {
    try {
      final yt = await apiService.resolveToYouTubeUrl(track.url, track.title, track.artist);
      if (yt == null || yt.isEmpty) {
        if (showSnackbar) _notFound(context, track.title);
        return;
      }
      final result = await apiService.getStreamingUrl(
        url: yt,
        title: track.title,
        artist: track.artist ?? '',
      );
      final item = QueueItem(
        id: 'track_${track.id}',
        title: result.title,
        artist: result.artist,
        album: track.album,
        url: result.streamingUrl,
        originalUrl: yt,
        thumbnail: track.thumbnail,
      );
      queueService.addToQueue(item);
      if (showSnackbar) _info(context, 'Added "${track.title}" to queue');
    } catch (e) {
      if (showSnackbar) _error(context, 'Failed to add to queue: $e');
    }
  }

  Future<void> download(BuildContext context, PlaylistTrack track) async {
    String? yt;
    try {
      yt = await apiService.resolveToYouTubeUrl(track.url, track.title, track.artist);
    } catch (_) {}
    if (yt == null || yt.isEmpty) {
      _notFound(context, track.title);
      return;
    }

    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    try {
      final result = await apiService.downloadAudio(
        url: yt,
        title: track.title,
        artist: track.artist ?? '',
        album: track.album ?? '',
        outputFormat: 'm4a',
        embedThumbnail: true,
      );
      if (context.mounted) {
        Navigator.of(context).pop();
        _info(context, 'Downloaded: ${result.filename}');
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();
        _error(context, 'Download failed: $e');
      }
    }
  }

  Future<void> addToPlaylist(BuildContext context, PlaylistTrack track) async {
    final yt = await apiService.resolveToYouTubeUrl(track.url, track.title, track.artist);
    if (yt == null || yt.isEmpty) {
      _notFound(context, track.title);
      return;
    }
    final playlistTrack = PlaylistTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      filename: '',
      url: yt,
      thumbnail: track.thumbnail,
      duration: track.duration,
    );
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => PlaylistSelectionDialog(
        playlistService: playlistService,
        track: playlistTrack,
      ),
    );
  }

  void _info(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _error(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating),
    );
  }

  void _notFound(BuildContext context, String title) {
    _error(context, 'Could not find "$title" on YouTube');
  }
}
