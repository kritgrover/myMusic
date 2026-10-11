import '../services/auth_http_client.dart';
import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';
import 'save_track_button.dart';
import 'source_selection_dialog.dart';

/// A reusable track row (thumbnail + title/artist + play + overflow menu) used by
/// the album and artist detail screens. Track metadata is already clean (Spotify),
/// so it is shown directly; [fallbackThumbnail] backs album tracks that lack art.
class TrackTile extends StatelessWidget {
  final PlaylistTrack track;
  final int? trackNumber;
  final String? fallbackThumbnail;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onDownload;
  final VoidCallback onAddToPlaylist;
  final VoidCallback? onChangeRecording;
  final ApiService? apiService;
  final String? recordingLabel;

  const TrackTile({
    super.key,
    required this.track,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onDownload,
    required this.onAddToPlaylist,
    this.onChangeRecording,
    this.apiService,
    this.recordingLabel,
    this.trackNumber,
    this.fallbackThumbnail,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = (track.thumbnail != null && track.thumbnail!.isNotEmpty)
        ? track.thumbnail
        : fallbackThumbnail;
    final type =
        VideoInfo.inferRecordingType('${track.title} ${track.album ?? ''}');
    final version = recordingLabel ??
        (type == 'unspecified' ? null : VideoInfo.recordingTypeLabel(type));

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: (thumb != null && thumb.isNotEmpty)
                    ? Image.network(
                        AuthHttpClient.shared.cacheScopedUrl(thumb),
                        headers: AuthHttpClient.shared.authHeadersForUrl(thumb),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(context),
                      )
                    : _placeholder(context),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if ((track.artist ?? '').isNotEmpty)
                      Text(
                        track.artist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                          fontSize: 14,
                        ),
                      ),
                    if (version != null)
                      Text(version,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              )),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SaveTrackButton(track: track),
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    tooltip: 'Play',
                    onPressed: onPlay,
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'More actions',
                    onSelected: (value) {
                      switch (value) {
                        case 'download':
                          onDownload();
                          break;
                        case 'playlist':
                          onAddToPlaylist();
                          break;
                        case 'queue':
                          onAddToQueue();
                          break;
                        case 'recording':
                          if (onChangeRecording != null) {
                            onChangeRecording!();
                          } else {
                            showDialog<bool>(
                              context: context,
                              builder: (_) => SourceSelectionDialog(
                                track: track,
                                apiService: apiService ?? ApiService(),
                              ),
                            );
                          }
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'download',
                        child: Row(children: [
                          Icon(Icons.download, size: 20),
                          SizedBox(width: 12),
                          Text('Download')
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'playlist',
                        child: Row(children: [
                          Icon(Icons.playlist_add, size: 20),
                          SizedBox(width: 12),
                          Text('Add to playlist')
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'queue',
                        child: Row(children: [
                          Icon(Icons.queue_music, size: 20),
                          SizedBox(width: 12),
                          Text('Add to queue')
                        ]),
                      ),
                      if (track.filename.isEmpty)
                        const PopupMenuItem(
                          value: 'recording',
                          child: Row(children: [
                            Icon(Icons.tune, size: 20),
                            SizedBox(width: 12),
                            Text('Change recording'),
                          ]),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: const Icon(Icons.music_note),
    );
  }
}
