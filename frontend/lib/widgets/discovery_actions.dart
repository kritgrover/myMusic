import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../models/queue_item.dart';
import '../services/api_service.dart';

/// Shared actions stay attached to the account-owned Home and its nested routes.
class DiscoveryActionScope extends InheritedWidget {
  final ValueChanged<QueueItem> onStartRadio;
  final ValueChanged<QueueItem> onLessLikeThis;
  final bool Function(QueueItem)? isHidden;

  const DiscoveryActionScope(
      {super.key,
      required super.child,
      required this.onStartRadio,
      required this.onLessLikeThis,
      this.isHidden});

  static DiscoveryActionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DiscoveryActionScope>();

  @override
  bool updateShouldNotify(DiscoveryActionScope oldWidget) =>
      oldWidget.onStartRadio != onStartRadio ||
      oldWidget.onLessLikeThis != onLessLikeThis ||
      oldWidget.isHidden != isHidden;
}

bool recommendationHidden(BuildContext context, PlaylistTrack track) =>
    DiscoveryActionScope.maybeOf(context)
        ?.isHidden
        ?.call(discoveryTrack(track)) ??
    false;

QueueItem discoveryTrack(PlaylistTrack track) => QueueItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      filename: track.filename.isEmpty ? null : track.filename,
      originalUrl: track.url ?? '',
      thumbnail: track.thumbnail,
      duration: track.duration,
      spotifyId: ApiService.spotifyTrackId(track.url, id: track.spotifyId) ??
          ApiService.spotifyTrackId(null, id: track.id),
    );

List<PopupMenuEntry<String>> discoveryMenuItems(BuildContext context) =>
    DiscoveryActionScope.maybeOf(context) == null
        ? []
        : const [
            PopupMenuItem(
                value: 'start_radio',
                child: Row(children: [
                  Icon(Icons.radio, size: 20),
                  SizedBox(width: 12),
                  Flexible(child: Text('Start song radio')),
                ])),
            PopupMenuItem(
                value: 'less_like_this',
                child: Row(children: [
                  Icon(Icons.thumb_down_outlined, size: 20),
                  SizedBox(width: 12),
                  Flexible(child: Text('Less like this')),
                ])),
          ];

bool handleDiscoveryAction(
    BuildContext context, String action, QueueItem track) {
  final scope = DiscoveryActionScope.maybeOf(context);
  if (scope == null) return false;
  switch (action) {
    case 'start_radio':
      scope.onStartRadio(track);
      return true;
    case 'less_like_this':
      scope.onLessLikeThis(track);
      return true;
    default:
      return false;
  }
}

class DiscoveryTrackMenu extends StatelessWidget {
  final PlaylistTrack track;
  final QueueItem? queueItem;
  const DiscoveryTrackMenu({super.key, required this.track, this.queueItem});
  @override
  Widget build(BuildContext context) {
    if (DiscoveryActionScope.maybeOf(context) == null) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<String>(
      tooltip: 'Song discovery options',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 180),
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (action) => handleDiscoveryAction(
          context, action, queueItem ?? discoveryTrack(track)),
      itemBuilder: (_) => discoveryMenuItems(context),
    );
  }
}
