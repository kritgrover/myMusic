import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/api_service.dart';
import 'package:music_downloader/utils/playlist_download_matching.dart';

PlaylistTrack track(String id, String title, String? artist,
        {String filename = ''}) =>
    PlaylistTrack(
      id: id,
      title: title,
      artist: artist,
      filename: filename,
      url: 'https://example.com/$id',
      album: 'Album',
      thumbnail: 'art.jpg',
      duration: 180,
    );

DownloadedFile file(String filename, String title, String artist) =>
    DownloadedFile(
      filename: filename,
      filePath: filename,
      size: 100,
      title: title,
      artist: artist,
    );

void main() {
  test('matches exact title and artist without mutating input or order', () {
    final tracks = [
      track('a', 'Song', 'Singer'),
      track('b', 'Other', 'Singer')
    ];
    final result =
        matchPlaylistDownloads(tracks, [file('song.m4a', ' song ', 'SINGER')]);
    expect(result.map((item) => item.id), ['a', 'b']);
    expect(result.first.filename, 'song.m4a');
    expect(tracks.first.filename, isEmpty);
    expect(result.first.url, tracks.first.url);
    expect(result.first.album, tracks.first.album);
    expect(result.first.thumbnail, tracks.first.thumbnail);
    expect(result.first.duration, tracks.first.duration);
  });

  test('a different artist or a substring title is not a match', () {
    final result = matchPlaylistDownloads([
      track('a', 'Song', 'Singer')
    ], [
      file('cover.m4a', 'Song', 'Cover artist'),
      file('live.m4a', 'Song live', 'Singer'),
    ]);
    expect(result.single.filename, isEmpty);
  });

  test('ambiguous metadata and missing artists are not guessed', () {
    final files = [
      file('one.m4a', 'Song', 'Singer'),
      file('two.m4a', 'Song', 'Singer')
    ];
    expect(
        matchPlaylistDownloads([track('a', 'Song', 'Singer')], files)
            .single
            .filename,
        isEmpty);
    expect(
        matchPlaylistDownloads([track('a', 'Song', null)], files)
            .single
            .filename,
        isEmpty);
  });

  test('existing filenames and confirmed batch results use verified files', () {
    final result = matchPlaylistDownloads([
      track('a', 'Original title', null, filename: 'existing.m4a'),
      track('b', 'Original title', null),
    ], [
      file('existing.m4a', 'Different metadata', 'Singer'),
      file('downloaded.m4a', 'Different metadata', 'Singer'),
    ], confirmedDownloads: {
      'b': 'downloaded.m4a'
    });
    expect(result.map((item) => item.filename),
        ['existing.m4a', 'downloaded.m4a']);
  });

  test('missing files are no longer marked as downloaded', () {
    final result = matchPlaylistDownloads(
        [track('a', 'Song', 'Singer', filename: 'deleted.m4a')], []);
    expect(result.single.filename, isEmpty);
    expect(result.single.url, 'https://example.com/a');
  });
}
