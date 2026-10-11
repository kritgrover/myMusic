"""Catalog pagination never presents the first page as an entire discography."""
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch


class SpotifyDiscographyTests(unittest.TestCase):
    def setUp(self):
        config = types.ModuleType('config')
        config.settings = types.SimpleNamespace(
            SPOTIFY_CLIENT_ID=None, SPOTIFY_CLIENT_SECRET=None)
        database = types.ModuleType('database')
        database.db = MagicMock()
        database.db.get_cache.return_value = None
        path = Path(__file__).resolve().parents[1] / 'spotify_service.py'
        spec = importlib.util.spec_from_file_location('discography_test_service', path)
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'config': config, 'database': database}):
            spec.loader.exec_module(self.module)
        self.service = self.module.spotify_service
        self.service.sp = MagicMock()
        self.db = database.db

    def album(self, number, **changes):
        value = dict(id=f'album-{number}', name=f'Release {number}',
                     artists=[dict(id='artist', name='Artist')],
                     album_type='album', album_group='album',
                     total_tracks=12, release_date=f'{1990 + number}', images=[])
        value.update(changes)
        return value

    def page(self, items, offset=0, total=None, next=None):
        return dict(items=items, offset=offset,
                    total=total if total is not None else offset + len(items), next=next)

    def test_all_release_pages_preserve_editions_and_groups(self):
        albums = [self.album(n) for n in range(24)]
        albums[1] = self.album(1, name='Same title', album_type='single', album_group='single')
        albums[2] = self.album(2, name='Same title', album_group='appears_on')
        albums[3] = self.album(3, album_type='compilation', album_group='compilation')
        # Provider overlaps can repeat IDs, but different editions with the same
        # title must survive deduplication.
        albums.append(albums[0])
        self.service.sp.artist_albums.side_effect = lambda _, **kw: self.page([]) if kw['album_type'] == 'appears_on' else self.page(
            albums[kw['offset']:kw['offset'] + kw['limit']], kw['offset'], len(albums),
            'next' if kw['offset'] + kw['limit'] < len(albums) else None)
        result = self.service.get_artist_albums('artist', limit=20)
        self.assertEqual(len(result), 24)
        self.assertEqual([call.kwargs['offset'] for call in self.service.sp.artist_albums.call_args_list], [0, 10, 20, 0])
        self.assertTrue(all(call.kwargs['limit'] == 10 for call in self.service.sp.artist_albums.call_args_list))
        self.assertTrue(all(call.kwargs['country'] == 'US' for call in self.service.sp.artist_albums.call_args_list))
        self.assertIn('compilation', self.service.sp.artist_albums.call_args_list[0].kwargs['album_type'])
        self.assertEqual(result[0]['id'], 'album-23')
        self.assertEqual(len([album for album in result if album['name'] == 'Same title']), 2)
        self.assertEqual(next(album for album in result if album['id'] == 'album-2')['group'], 'appears_on')
        self.assertEqual(result[0]['artist_id'], 'artist')
        self.assertEqual(result[0]['total_tracks'], 12)
        self.db.set_cache.assert_called_once()

    def test_appearances_are_classified_without_removed_album_group_field(self):
        album = self.album(1)
        appearance = self.album(2)
        album.pop('album_group')
        appearance.pop('album_group')
        self.service.sp.artist_albums.side_effect = [
            self.page([album]), self.page([appearance])]
        result = self.service.get_artist_albums('artist')
        self.assertEqual([release['group'] for release in result], ['appears_on', 'album'])

    def test_later_page_failure_raises_without_caching_partial_releases(self):
        self.service.sp.artist_albums.side_effect = [
            self.page([self.album(1)], total=2, next='next'), RuntimeError('rate limited')]
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service.get_artist_albums('artist')
        self.db.set_cache.assert_not_called()

    def test_missing_next_page_and_repeated_pages_are_explicit_failures(self):
        for pages in ([self.page([self.album(1)], total=2)], [
            self.page([self.album(1)], total=3, next='next'),
            self.page([self.album(1)], offset=1, total=3, next='next')]):
            with self.subTest(pages=pages):
                self.service.sp.artist_albums.side_effect = pages
                with self.assertRaises(self.module.SpotifyCatalogError):
                    self.service.get_artist_albums('artist')
                self.db.set_cache.assert_not_called()

    def test_page_guard_does_not_return_successful_partial_result(self):
        def fetch(offset, size):
            return self.page([self.album(offset)], offset=offset, total=100, next='next')
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service._catalog_pages(fetch, 1, max_pages=2)

    def test_complete_empty_response_is_distinct_from_unavailable_provider(self):
        self.service.sp.artist_albums.return_value = self.page([])
        self.assertEqual(self.service.get_artist_albums('artist'), [])
        self.db.set_cache.assert_called_once()
        self.service.sp = None
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service.get_artist_albums('artist')

    def test_box_set_loads_tracks_after_first_fifty_and_preserves_disc_order(self):
        tracks = [dict(id=f'track-{n}', name=f'Track {n}', artists=[dict(id='artist', name='Artist')],
                       disc_number=1 if n < 50 else 2, track_number=n % 50 + 1,
                       duration_ms=100000, external_urls={'spotify': f'https://open.spotify.com/track/{n}'})
                  for n in range(55)]
        self.service.sp.album_tracks.side_effect = lambda _, **kw: self.page(
            tracks[kw['offset']:kw['offset'] + kw['limit']], kw['offset'], len(tracks),
            'next' if kw['offset'] + kw['limit'] < len(tracks) else None)
        result = self.service.get_album_tracks('box-set')
        self.assertEqual(len(result), 55)
        self.assertEqual([call.kwargs['offset'] for call in self.service.sp.album_tracks.call_args_list], [0, 50])
        self.assertEqual(result[-1]['title'], 'Track 54')
        self.assertEqual(result[-1]['disc_number'], 2)
        self.assertEqual(result[-1]['track_number'], 5)
        self.assertEqual(result[-1]['album_id'], 'box-set')
        self.assertEqual(result[-1]['artist_id'], 'artist')
        self.assertEqual(result[-1]['duration'], 100)

    def test_album_later_page_failure_is_not_cached(self):
        self.service.sp.album_tracks.side_effect = [
            self.page([dict(id='track', name='Track')], total=2, next='next'), RuntimeError('offline')]
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service.get_album_tracks('album')
        self.db.set_cache.assert_not_called()


    def test_unavailable_playlist_contents_are_not_reported_as_empty(self):
        self.service.sp.playlist_tracks.side_effect = RuntimeError('private provider error')
        with self.assertRaises(self.module.SpotifyCatalogError) as raised:
            self.service.get_playlist_tracks('playlist')
        self.assertNotIn('private provider error', str(raised.exception))
        self.db.set_cache.assert_not_called()
        self.service.sp = None
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service.get_playlist_tracks('playlist')

    def test_valid_empty_playlist_remains_distinct_from_invalid_response(self):
        self.service.sp.playlist_tracks.return_value = {'items': []}
        self.assertEqual(self.service.get_playlist_tracks('playlist'), [])
        self.db.set_cache.assert_called_once()
        self.service.sp.playlist_tracks.return_value = {}
        with self.assertRaises(self.module.SpotifyCatalogError):
            self.service.get_playlist_tracks('different-playlist')


if __name__ == '__main__':
    unittest.main()
