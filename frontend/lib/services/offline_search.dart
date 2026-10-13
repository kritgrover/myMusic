import '../models/search_results.dart';
import 'offline_download_service.dart';

SearchResults searchOfflineLibrary(String query) {
  final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
  if (query.trim().isEmpty) return const SearchResults();
  return SearchResults(
    library: OfflineDownloadService.shared.tracks
        .where((track) {
          final text =
              '${track.title} ${track.artist ?? ''} ${track.album ?? ''}'
                  .toLowerCase();
          return words.every(text.contains);
        })
        .map((track) => SearchEntry({
              'id': track.id,
              'kind': 'track',
              'title': track.title,
              'artist': track.artist,
              'album': track.album,
              'duration': track.duration,
              'spotify_id': track.spotifyId,
              'filename': track.filename,
              'url': track.originalUrl,
              'thumbnail': track.thumbnail,
              'provider': 'local',
              'library_origin': 'device',
            }))
        .toList(),
  );
}
