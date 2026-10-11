import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_downloader/models/playlist.dart';
import 'package:music_downloader/services/playlist_service.dart';
import 'package:music_downloader/widgets/playlist_selection_dialog.dart';

class _Playlists extends PlaylistService {
  final List<Playlist> playlists;
  final List<(String, String)> removed = [];
  final List<(String, PlaylistTrack)> added = [];
  late final Map<String, Set<String>> memberships = {
    for (final playlist in playlists)
      playlist.id: playlist.tracks.map((track) => track.id).toSet(),
  };
  String? failNextRemoval;

  _Playlists(this.playlists);

  @override
  Future<List<Playlist>> getAllPlaylists() async => playlists;

  @override
  Future<void> addTrackToPlaylist(
      String playlistId, PlaylistTrack track) async {
    added.add((playlistId, track));
    memberships[playlistId]!.add(track.id);
  }

  @override
  Future<void> removeTrackFromPlaylist(
      String playlistId, String trackId) async {
    removed.add((playlistId, trackId));
    if (failNextRemoval == playlistId) {
      failNextRemoval = null;
      throw Exception('Temporary playlist failure');
    }
    memberships[playlistId]!.remove(trackId);
  }
}

Playlist _playlist(String id, List<PlaylistTrack> tracks) => Playlist(
      id: id,
      name: id,
      tracks: tracks,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

PlaylistTrack _track(String id, {String? url, String filename = ''}) =>
    PlaylistTrack(
      id: id,
      title: 'Other Private Tone',
      artist: 'Private Fixture',
      filename: filename,
      url: url,
    );

Future<void> _open(
    WidgetTester tester, _Playlists service, PlaylistTrack track) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () => showDialog<bool>(
            context: context,
            builder: (_) => PlaylistSelectionDialog(
                playlistService: service, track: track)),
        child: const Text('Open playlists'),
      );
    })),
  ));
  await tester.tap(find.text('Open playlists'));
  await tester.pumpAndSettle();
}

void main() {
  const source = 'https://www.youtube.com/watch?v=other000001';

  testWidgets('removing the last membership uses actual URL-matched row IDs',
      (tester) async {
    final saved = _track('track_saved_stable_hash', url: source);
    final service = _Playlists([
      _playlist('Private collection', [
        _track('original-source-id', url: source),
        _track('older-duplicate-id', url: source),
      ]),
    ]);
    await _open(tester, service, saved);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
        tester
            .widget<ElevatedButton>(
                find.byWidgetPredicate((widget) => widget is ElevatedButton))
            .onPressed,
        isNull);

    await tester.tap(find.text('Private collection'));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(
        tester
            .widget<ElevatedButton>(
                find.byWidgetPredicate((widget) => widget is ElevatedButton))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(service.removed, [
      ('Private collection', 'original-source-id'),
      ('Private collection', 'older-duplicate-id'),
    ]);
    expect(service.added, isEmpty);
    expect(find.byType(PlaylistSelectionDialog), findsNothing);
    expect(find.text('Playlist updated'), findsOneWidget);
  });

  testWidgets(
      'changing membership adds the saved track and removes matched row',
      (tester) async {
    final saved = _track('track_saved_stable_hash', url: source);
    final service = _Playlists([
      _playlist('Private collection', [_track('original', url: source)]),
      _playlist('New favourites', []),
    ]);
    await _open(tester, service, saved);
    await tester.tap(find.text('Private collection'));
    await tester.tap(find.text('New favourites'));
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(service.removed, [('Private collection', 'original')]);
    expect(service.added.single.$1, 'New favourites');
    expect(service.added.single.$2, same(saved));
  });

  testWidgets('blank source URLs never preselect unrelated tracks',
      (tester) async {
    final saved = _track('saved', url: '');
    final service = _Playlists([
      _playlist('Unrelated collection', [_track('unrelated', url: '')]),
    ]);
    await _open(tester, service, saved);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    await tester.tap(find.text('Unrelated collection'));
    await tester.pump();
    await tester.tap(find.text('Add to selected'));
    await tester.pumpAndSettle();

    expect(service.removed, isEmpty);
    expect(service.added.single.$1, 'Unrelated collection');
    expect(service.added.single.$2.id, 'saved');
  });

  testWidgets('local file matches remain editable when saved IDs differ',
      (tester) async {
    final saved = _track('saved', filename: 'fixture/tone.mp3');
    final service = _Playlists([
      _playlist('Downloaded music', [
        _track('legacy', filename: r'fixture\tone.mp3'),
      ]),
    ]);
    await _open(tester, service, saved);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.text('Downloaded music'));
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(service.removed, [('Downloaded music', 'legacy')]);
    expect(service.added, isEmpty);
  });

  testWidgets(
      'selection changes after partial success use committed membership',
      (tester) async {
    final saved = _track('saved', url: source);
    final service = _Playlists([
      _playlist('Original', [_track('original', url: source)]),
      _playlist('Destination', []),
    ])
      ..failNextRemoval = 'Original';
    await _open(tester, service, saved);
    await tester.tap(find.text('Original'));
    await tester.tap(find.text('Destination'));
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.byType(PlaylistSelectionDialog), findsOneWidget);
    expect(find.textContaining('Temporary playlist failure'), findsOneWidget);
    expect(service.memberships['Destination'], {'saved'});
    expect(service.memberships['Original'], {'original'});

    // The user reverses their intended move after the failure. Destination
    // already succeeded on the server, so this must issue a real removal.
    await tester.tap(find.text('Destination'));
    await tester.tap(find.text('Original'));
    await tester.pump();
    expect(
        tester
            .widget<ElevatedButton>(
                find.byWidgetPredicate((widget) => widget is ElevatedButton))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(service.memberships['Destination'], isEmpty);
    expect(service.memberships['Original'], {'original'});
    expect(service.added.length, 1);
    expect(
        service.removed, [('Original', 'original'), ('Destination', 'saved')]);
    expect(find.byType(PlaylistSelectionDialog), findsNothing);
  });
}
