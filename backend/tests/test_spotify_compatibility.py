"""Supported Spotify catalog calls, exact identities, and current response shapes."""
import unittest
from unittest.mock import patch

import test_spotify_discography as fixtures


class SpotifyCompatibilityTests(unittest.TestCase):
    setUp = fixtures.SpotifyDiscographyTests.setUp
    album = fixtures.SpotifyDiscographyTests.album
    page = fixtures.SpotifyDiscographyTests.page

    def track(self, number, artist_id='artist', **changes):
        item = dict(id=f'track-{number}', name=f'Song {number}', type='track',
                    artists=[dict(id=artist_id, name='Same name')],
                    album=dict(id=f'album-{number}', name=f'Album {number}',
                               images=[dict(url=f'https://i.scdn.co/image/album-{number}')]),
                    duration_ms=180000)
        item.update(changes)
        return item

    def test_search_artist_page_size_is_ten_and_requested_count_is_preserved(self):
        artists = [dict(id=str(n), name=f'Artist {n}', images=[]) for n in range(15)]
        self.service.sp.search.side_effect = lambda **kw: {'artists': self.page(
            artists[kw['offset']:kw['offset'] + kw['limit']], offset=kw['offset'],
            total=15, next='next' if kw['offset'] == 0 else None)}
        result = self.service.search_artists('metalcore', limit=15)
        self.assertEqual(len(result), 15)
        self.assertEqual([(c.kwargs['limit'], c.kwargs['offset'])
                          for c in self.service.sp.search.call_args_list], [(10, 0), (5, 10)])

    def test_genre_discovery_searches_tracks_without_reading_playlists(self):
        self.service.sp.search.return_value = {'tracks': self.page([self.track(1)])}
        tracks = self.service.get_genre_recommendations('metalcore', limit=20)
        self.assertEqual(tracks[0]['album'], 'Album 1')
        self.assertEqual(tracks[0]['thumbnail'], 'https://i.scdn.co/image/album-1')
        self.assertEqual(tracks[0]['spotify_id'], 'track-1')
        self.assertEqual(self.service.sp.search.call_args.kwargs['type'], 'track')
        self.service.sp.playlist_tracks.assert_not_called()
        self.service.sp._get.assert_not_called()

    def test_artist_track_selection_rejects_same_name_different_artist_id(self):
        self.service.sp.artist.return_value = dict(id='artist', name='Same name', genres=[])
        self.service.sp.search.return_value = {'tracks': self.page([
            self.track(1, 'unrelated'), self.track(2, 'artist')])}
        tracks = self.service.get_artist_top_tracks('artist')
        self.assertEqual([track['id'] for track in tracks], ['track-2'])
        self.service.sp.artist_top_tracks.assert_not_called()

    def test_recommendation_pool_combines_genres_and_verified_artist_tracks(self):
        self.service.sp.artist.return_value = dict(id='artist', name='Same name', genres=['metalcore'])
        self.service.sp.search.side_effect = lambda **kw: {'tracks': self.page([
            self.track(1, 'new-artist') if kw['q'].startswith('genre:') else self.track(2)])}
        result = self.service.get_recommendations(seed_artists=['artist'], limit=20)
        self.assertEqual([track['id'] for track in result], ['track-1', 'track-2'])
        self.service.sp.artist_related_artists.assert_not_called()
        self.service.sp.artist_top_tracks.assert_not_called()
        self.service.sp.recommendations.assert_not_called()

    def test_removed_optional_fields_do_not_break_track_search(self):
        self.service.sp.search.return_value = {'tracks': self.page([self.track(1)])}
        result = self.service.search_track('Song 1', 'Same name')
        self.assertEqual(result['title'], 'Song 1')
        self.assertIsNone(result['preview_url'])
        self.assertEqual(result['artist_ids'], ['artist'])
        self.assertEqual(result['url'], 'https://open.spotify.com/track/track-1')

    def test_new_releases_use_album_search_instead_of_removed_browse_api(self):
        self.service.sp.search.return_value = {'albums': self.page([
            self.album(1, release_date='2026-01-01'), self.album(2, release_date='2026-11-01')])}
        result = self.service.get_new_releases(limit=20)
        self.assertEqual([album['id'] for album in result], ['album-2', 'album-1'])
        self.assertEqual(self.service.sp.search.call_args.kwargs['type'], 'album')
        self.service.sp.new_releases.assert_not_called()

    def test_discography_own_albums_require_exact_artist_credit(self):
        same_name = self.album(1, artists=[dict(id='other', name='Artist')])
        own = self.album(2)
        own.pop('album_group')
        self.service.sp.artist_albums.side_effect = [self.page([same_name, own]), self.page([])]
        result = self.service.get_artist_albums('artist')
        self.assertEqual([album['id'] for album in result], ['album-2'])
        self.assertEqual(result[0]['group'], 'album')

    def test_appearance_requires_verified_track_credit_and_stays_separate(self):
        foreign_artist = [dict(id='other', name='Other artist')]
        compilation = self.album(1, artists=foreign_artist)
        unrelated = self.album(2, artists=foreign_artist)
        self.service.sp.artist_albums.side_effect = [self.page([]), self.page([compilation, unrelated])]
        self.service.sp.album_tracks.side_effect = lambda album_id, **kw: self.page([
            self.track(1, 'artist' if album_id == 'album-1' else 'other')])
        result = self.service.get_artist_albums('artist')
        self.assertEqual([album['id'] for album in result], ['album-1'])
        self.assertEqual(result[0]['group'], 'appears_on')

    def test_playlist_items_use_new_endpoint_and_load_beyond_fifty(self):
        items = [dict(item=self.track(n)) for n in range(55)]
        self.service.sp._get.side_effect = lambda path, **kw: self.page(
            items[kw['offset']:kw['offset'] + kw['limit']], offset=kw['offset'], total=55,
            next='next' if kw['offset'] == 0 else None)
        result = self.service.get_playlist_tracks('playlist')
        self.assertEqual(len(result), 55)
        self.assertEqual(result[-1]['id'], 'track-54')
        self.assertEqual([call.args[0] for call in self.service.sp._get.call_args_list],
                         ['playlists/playlist/items', 'playlists/playlist/items'])
        self.assertEqual([call.kwargs['offset'] for call in self.service.sp._get.call_args_list], [0, 50])
        self.service.sp.playlist_tracks.assert_not_called()

    def test_appearance_credit_stops_after_first_verified_page(self):
        self.service.sp.album_tracks.return_value = self.page(
            [self.track(1)], total=200, next='next')
        self.assertTrue(self.service._album_contains_artist('album', 'artist', 'US', float('inf')))
        self.service.sp.album_tracks.assert_called_once()

    def test_playlist_access_restrictions_are_actionable_and_not_cached(self):
        exception = RuntimeError('private upstream details')
        exception.http_status = 403
        self.service.sp._get.side_effect = exception
        with self.assertRaises(self.module.SpotifyCapabilityError) as raised:
            self.service.get_playlist_tracks('playlist')
        self.assertIn('import a playlist CSV', str(raised.exception))
        self.assertNotIn('private upstream', str(raised.exception))
        self.db.set_cache.assert_not_called()

    def test_playlist_repeated_recordings_are_preserved_across_pages(self):
        self.service.sp._get.side_effect = lambda path, **kw: self.page(
            [dict(item=self.track(1))], offset=kw['offset'], total=2,
            next='next' if kw['offset'] == 0 else None)
        result = self.service.get_playlist_tracks('playlist', limit=1)
        self.assertEqual([track['id'] for track in result], ['track-1', 'track-1'])

    def test_discovery_request_budget_stops_additional_searches(self):
        self.service.sp.search.return_value = {'tracks': self.page([self.track(1)] * 10, total=20, next='next')}
        with patch.object(self.module.time, 'monotonic', side_effect=[0, 0, 20]):
            self.service._search_items('genre:rock', 'track', 20)
        self.assertEqual(self.service.sp.search.call_count, 1)

    def test_catalog_status_does_not_claim_credentials_have_been_validated(self):
        status = self.service.catalog_status()
        self.assertEqual(status['status'], 'configured')
        self.assertEqual(status['authorization'], 'client_credentials')
        self.assertEqual(status['playlist_contents'], 'restricted')


if __name__ == '__main__':
    unittest.main()
