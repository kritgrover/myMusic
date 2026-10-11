import '../models/playlist.dart';
import '../services/api_service.dart';

/// Associates available files without mutating persisted playlist entries.
/// Metadata matches must be exact, include an artist, and be unambiguous.
List<PlaylistTrack> matchPlaylistDownloads(
  List<PlaylistTrack> tracks,
  List<DownloadedFile> files, {
  Map<String, String> confirmedDownloads = const {},
}) {
  final filenames = files.map((file) => file.filename).toSet();
  return tracks.map((track) {
    final confirmed = confirmedDownloads[track.id];
    var filename = confirmed != null && filenames.contains(confirmed)
        ? confirmed
        : track.filename;
    if (filename.isEmpty || !filenames.contains(filename)) {
      filename = '';
      final title = track.title.trim().toLowerCase();
      final artist = (track.artist ?? '').trim().toLowerCase();
      if (title.isNotEmpty && artist.isNotEmpty) {
        final matches = files
            .where((file) =>
                (file.title ?? '').trim().toLowerCase() == title &&
                (file.artist ?? '').trim().toLowerCase() == artist)
            .toList();
        if (matches.length == 1) filename = matches.single.filename;
      }
    }
    if (filename == track.filename) return track;
    return PlaylistTrack(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      filename: filename,
      url: track.url,
      thumbnail: track.thumbnail,
      duration: track.duration,
    );
  }).toList();
}
