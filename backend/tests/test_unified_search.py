"""Search privacy, provider failure and recording correction contracts."""

import asyncio
import threading
import time
import types
import unittest
from contextlib import closing
from unittest.mock import patch

from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class UnifiedSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user('search-user', 'unused')
        cls.other = cls.api.db.create_user('search-other', 'unused')
        cls.headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.user['id'], cls.user['username'])}
        cls.other_headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.other['id'], cls.other['username'])}

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        with closing(self.api.db.get_connection()) as connection, connection:
            for table in ('source_preferences', 'saved_library', 'spotify_cache', 'playlist_songs', 'playlists', 'download_owners'):
                connection.execute('DELETE FROM ' + table)
        self.track = {'title': 'Night Drive', 'artist': 'Demo Artist', 'album': 'Evening Signals',
                      'duration': 180, 'spotify_id': 'catalogSong1'}
        self.videos = [
            {'id': 'live0000001', 'title': 'Demo Artist - Night Drive (Live at Home)', 'uploader': 'Demo Artist', 'duration': 180,
             'url': 'https://www.youtube.com/watch?v=live0000001'},
            {'id': 'audio000001', 'title': 'Demo Artist - Night Drive (Official Audio)', 'uploader': 'Demo Artist - Topic', 'duration': 181,
             'url': 'https://www.youtube.com/watch?v=audio000001'},
            {'id': 'remix000001', 'title': 'Demo Artist - Night Drive (Remix)', 'uploader': 'Demo Artist', 'duration': 180,
             'url': 'https://www.youtube.com/watch?v=remix000001'},
        ]

    def test_all_new_endpoints_require_authentication(self):
        self.assertEqual(self.client.get('/search/unified?q=test').status_code, 401)
        self.assertEqual(self.client.get('/search/library?q=test').status_code, 401)
        for method, path in (('post', '/search/resolve'), ('post', '/search/candidates'),
                             ('put', '/search/source'), ('request', '/search/source')):
            response = (self.client.request('DELETE', path, json=self.track) if method == 'request'
                        else getattr(self.client, method)(path, json=self.track))
            self.assertEqual(response.status_code, 401)

    def test_unified_catalog_shapes_and_null_entries(self):
        catalog = {'tracks': {'items': [None, {'id': 'song1', 'name': 'Night Drive',
                    'artists': [{'id': 'artist1', 'name': 'Demo Artist'}],
                    'album': {'id': 'album1', 'name': 'Evening Signals', 'images': []}, 'duration_ms': 180000}]},
                   'artists': {'items': [{'id': 'artist1', 'name': 'Demo Artist'}]},
                   'albums': {'items': [{'id': 'album1', 'name': 'Evening Signals'}]},
                   'playlists': {'items': [None, {'id': 'playlist1', 'name': 'Night Music'}]}}
        client = types.SimpleNamespace(search=lambda **kwargs: catalog)
        with patch.object(self.api.spotify_service, 'sp', client), patch.object(self.api.download_service, 'search_youtube') as videos:
            response = self.client.get('/search/unified?q=night', headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual(body['songs'][0]['duration'], 180)
        self.assertEqual(body['songs'][0]['spotify_id'], 'song1')
        self.assertEqual(body['songs'][0]['recording_type'], 'original')
        self.assertEqual(body['artists'][0]['kind'], 'artist')
        self.assertEqual(body['albums'][0]['kind'], 'album')
        self.assertFalse(body['playlists'][0]['is_local'])
        self.assertIn('Night Drive', body['suggestions'])
        videos.assert_not_called()

    def test_provider_failure_retains_private_account_library(self):
        for user, label in ((self.user, 'My'), (self.other, 'Other')):
            self.api.db.save_library_item(user['id'], 'tracks', label, {'id': label, 'title': label + ' Night Song', 'artist': 'Artist'})
            playlist = self.api.db.create_playlist(user['id'], label + ' Night Playlist')
            self.api.db.add_song_to_playlist(user['id'], playlist['id'], {'id': label + '-track', 'title': label + ' Night Track'})
            filename = label + ' Night.mp3'
            (self.root / 'downloads' / filename).write_bytes(b'fixture')
            self.api.db.claim_download(user['id'], filename)
        with patch.object(self.api.spotify_service, 'sp', None), patch.object(self.api.download_service, 'search_youtube', side_effect=RuntimeError('offline')):
            own = self.client.get('/search/unified?q=night', headers=self.headers).json()
            other = self.client.get('/search/unified?q=night', headers=self.other_headers).json()
        self.assertEqual(len(own['warnings']), 2)
        self.assertTrue({'saved', 'playlist', 'download'} <= {row['library_origin'] for row in own['library']})
        self.assertTrue(all('Other' not in str(row) for row in own['library']))
        self.assertTrue(all('My Night' not in str(row) for row in other['library']))
        self.assertTrue(all('file_path' not in row for row in own['library']))
        self.assertEqual(own['playlists'][0]['provider'], 'local')

    def test_library_search_returns_only_owned_matches_without_external_providers(self):
        self.api.db.save_library_item(self.user['id'], 'tracks', 'local-song',
                                     {'id': 'local-song', 'title': 'Night Drive', 'artist': 'Demo Artist'})
        self.api.db.save_library_item(self.other['id'], 'tracks', 'private-song',
                                     {'id': 'private-song', 'title': 'Night Secret', 'artist': 'Private Artist'})
        self.api.db.create_playlist(self.user['id'], 'Night Playlist')
        with patch.object(self.api.spotify_service, 'sp') as spotify, \
                patch.object(self.api.download_service, 'search_youtube') as videos:
            response = self.client.get('/search/library?q=night', headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIn('local-song', {row['id'] for row in response.json()['library']})
        self.assertNotIn('private-song', {row['id'] for row in response.json()['library']})
        self.assertEqual(response.json()['playlists'][0]['name'], 'Night Playlist')
        spotify.search.assert_not_called()
        videos.assert_not_called()

    def test_source_ranking_avoids_unrequested_versions(self):
        with patch.object(self.api.download_service, 'search_youtube', return_value=self.videos):
            result = self.client.post('/search/candidates', headers=self.headers, json=self.track)
            resolved = self.client.post('/search/resolve', headers=self.headers, json=self.track)
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['candidates'][0]['id'], 'audio000001')
        self.assertEqual(resolved.json()['id'], 'audio000001')
        self.assertFalse(resolved.json()['remembered'])
        self.assertEqual({row['recording_type'] for row in result.json()['candidates']}, {'live', 'remix', 'unspecified'})

    def test_requested_live_version_is_preferred_and_title_live_forever_is_not_live(self):
        from unified_search import rank_candidates, recording_type
        wanted = {**self.track, 'title': 'Night Drive (Live at Home)'}
        self.assertEqual(rank_candidates(wanted, self.videos)[0]['id'], 'live0000001')
        self.assertEqual(recording_type('Live Forever'), 'unspecified')
        self.assertEqual(recording_type('Night Drive - Studio Version'), 'studio')

    def test_automatic_resolution_rejects_known_incompatible_recordings(self):
        cases = (
            ('unwanted live', self.track, self.videos[0]),
            ('unwanted remix', self.track, self.videos[2]),
            ('unverified live', {**self.track, 'recording_type': 'live'}, self.videos[1]),
            ('different artist', self.track, {**self.videos[1], 'title': 'Other Singer - Night Drive (Official Audio)',
                                             'uploader': 'Other Singer', 'duration': 180}),
            ('different title', self.track, {**self.videos[1], 'title': 'Demo Artist - Wrong Song (Official Audio)',
                                            'duration': 180}),
            ('different duration', self.track, {**self.videos[1], 'duration': 500}),
        )
        for label, track, video in cases:
            with self.subTest(case=label):
                # Provider-result caching is public; remove only this fixture's cache between cases.
                with closing(self.api.db.get_connection()) as connection, connection:
                    connection.execute("DELETE FROM spotify_cache WHERE key LIKE 'source-search:v1:%'")
                with patch.object(self.api.download_service, 'search_youtube', return_value=[video]):
                    result = self.client.post('/search/resolve', headers=self.headers, json=track)
                    candidates = self.client.post('/search/candidates', headers=self.headers, json=track)
                self.assertEqual(result.status_code, 409, result.text)
                self.assertEqual(len(candidates.json()['candidates']), 1)
                self.assertFalse(candidates.json()['candidates'][0]['auto_selectable'])

    def test_explicit_source_choice_can_select_a_different_recording(self):
        for remembered in (False, True):
            with self.subTest(remembered=remembered):
                track = {**self.track, 'url': self.videos[0]['url']}
                if remembered:
                    self.client.put('/search/source', headers=self.headers, json=track)
                    track.pop('url')
                result = self.client.post('/search/resolve', headers=self.headers, json=track)
                self.assertEqual(result.status_code, 200, result.text)
                self.assertEqual(result.json()['url'], self.videos[0]['url'])
                self.assertEqual(result.json()['remembered'], remembered)

    def test_preferences_persist_per_account_and_reset_to_ranked_selection(self):
        source = 'https://youtu.be/remix000001?t=22'
        response = self.client.put('/search/source', headers=self.headers, json={**self.track, 'url': source})
        self.assertEqual(response.status_code, 200, response.text)
        from database import Database
        with patch.object(self.api, 'db', Database()), patch.object(self.api.download_service, 'search_youtube', return_value=self.videos):
            own = self.client.post('/search/resolve', headers=self.headers, json=self.track).json()
            other = self.client.post('/search/resolve', headers=self.other_headers, json=self.track).json()
            self.assertEqual(own['id'], 'remix000001')
            self.assertTrue(own['remembered'])
            self.assertEqual(other['id'], 'audio000001')
            self.assertFalse(other['remembered'])
            deleted = self.client.request('DELETE', '/search/source', headers=self.headers, json=self.track)
            self.assertEqual(deleted.json(), {'remembered': False})
            automatic = self.client.post('/search/resolve', headers=self.headers, json=self.track).json()
            self.assertEqual(automatic['id'], 'audio000001')

    def test_invalid_source_never_overwrites_saved_choice(self):
        valid = {**self.track, 'url': self.videos[1]['url']}
        self.assertEqual(self.client.put('/search/source', headers=self.headers, json=valid).status_code, 200)
        for invalid in ('file:///secret', 'http://127.0.0.1/music', 'https://youtube.com.evil.test/watch?v=audio000001',
                        'https://www.youtube.com/playlist?list=abc'):
            response = self.client.put('/search/source', headers=self.headers, json={**self.track, 'url': invalid})
            self.assertEqual(response.status_code, 400)
        result = self.client.post('/search/resolve', headers=self.headers, json=self.track).json()
        self.assertEqual(result['url'], valid['url'])

    def test_provided_source_remains_visible_without_inventing_recording_details(self):
        with patch.object(self.api.download_service, 'search_youtube', return_value=[]):
            response = self.client.post('/search/candidates', headers=self.headers,
                                        json={**self.track, 'url': self.videos[1]['url']})
        item = response.json()['candidates'][0]
        self.assertEqual(item['url'], self.videos[1]['url'])
        self.assertEqual(item['duration'], 0)
        self.assertEqual(item['uploader'], '')
        self.assertEqual(item['recording_type'], 'unspecified')
        self.assertIn('details unavailable', item['title'])
        self.assertTrue(item['is_selected'])
        self.assertFalse(item['details_available'])

    def test_reset_from_metadata_alias_removes_catalog_preference(self):
        self.client.put('/search/source', headers=self.headers, json={**self.track, 'url': self.videos[2]['url']})
        response = self.client.request('DELETE', '/search/source', headers=self.headers, json={**self.track, 'spotify_id': ''})
        self.assertEqual(response.status_code, 200)
        with patch.object(self.api.download_service, 'search_youtube', return_value=self.videos):
            response = self.client.post('/search/resolve', headers=self.headers, json=self.track)
        self.assertEqual(response.json()['id'], 'audio000001')
        self.assertFalse(response.json()['remembered'])

    def test_editing_through_metadata_alias_updates_the_catalog_choice(self):
        self.client.put('/search/source', headers=self.headers, json={**self.track, 'url': self.videos[2]['url']})
        self.client.put('/search/source', headers=self.headers,
                        json={**self.track, 'spotify_id': '', 'url': self.videos[0]['url']})
        result = self.client.post('/search/resolve', headers=self.headers, json=self.track).json()
        self.assertEqual(result['url'], self.videos[0]['url'])
        self.assertTrue(result['remembered'])

    def test_recording_metadata_fallback_keeps_live_and_album_editions_separate(self):
        metadata = {**self.track, 'spotify_id': ''}
        self.client.put('/search/source', headers=self.headers, json={**metadata, 'url': self.videos[1]['url']})
        from unified_search import recording_key
        self.assertNotEqual(recording_key(metadata), recording_key({**metadata, 'title': 'Night Drive (Live)'}))
        self.assertNotEqual(recording_key(metadata), recording_key({**metadata, 'album': 'Re-recorded'}))
        self.assertEqual(recording_key(metadata), recording_key({**metadata, 'title': '  NIGHT  DRIVE ', 'artist': 'demo artist'}))

    def test_source_provider_outage_and_low_confidence_are_explicit(self):
        with patch.object(self.api.download_service, 'search_youtube', side_effect=RuntimeError('private diagnostic')):
            result = self.client.post('/search/resolve', headers=self.headers, json=self.track)
            candidates = self.client.post('/search/candidates', headers=self.headers, json=self.track)
        self.assertEqual(result.status_code, 503)
        self.assertNotIn('private diagnostic', result.text)
        self.assertTrue(candidates.json()['warnings'])
        unrelated = [{**self.videos[0], 'title': 'Unrelated song', 'uploader': 'Another band'}]
        with patch.object(self.api.download_service, 'search_youtube', return_value=unrelated):
            result = self.client.post('/search/resolve', headers=self.headers, json=self.track)
        self.assertEqual(result.status_code, 409)

    def test_download_uses_saved_catalog_choice_for_legacy_metadata_caller(self):
        self.client.put('/search/source', headers=self.headers, json={**self.track, 'url': self.videos[2]['url']})
        result = {'filename': 'chosen.m4a', 'file_path': str(self.root / 'downloads' / 'chosen.m4a'),
                  'title': self.track['title'], 'artist': self.track['artist'], 'album': self.track['album']}
        with patch.object(self.api.download_service, 'download_audio', return_value=result) as download:
            response = self.client.post('/download', headers=self.headers,
                                        json={key: value for key, value in {**self.track, 'url': self.videos[1]['url']}.items()
                                              if key not in ('spotify_id', 'duration')})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(download.call_args.kwargs['url'], self.videos[2]['url'])

    def test_provider_timeout_is_bounded_without_unlimited_background_queue(self):
        from unified_search import ProviderBusy, SearchProviders
        providers = SearchProviders(lambda: self.api.db, lambda: None, lambda: None, timeout=.02)
        release = threading.Event()
        async def run():
            first = await asyncio.gather(*(providers.call(lambda: release.wait(.5)) for _ in range(4)), return_exceptions=True)
            self.assertTrue(all(isinstance(item, TimeoutError) for item in first))
            with self.assertRaises(ProviderBusy):
                await providers.call(lambda: None)
        started = time.monotonic()
        try:
            asyncio.run(run())
            self.assertLess(time.monotonic() - started, .3)
        finally:
            release.set()
            providers._pool.shutdown(wait=True)

    def test_autocomplete_cache_is_bounded_and_preserves_other_catalog_cache(self):
        self.api.db.set_cache('artist-profile:existing', {'name': 'Preserved'}, ttl_seconds=600)
        for index in range(6):
            self.api.db.set_search_cache('unified-search:v1:' + str(index), {'songs': []}, ttl_seconds=600, max_entries=3)
        with closing(self.api.db.get_connection()) as connection:
            count = connection.execute("SELECT COUNT(*) FROM spotify_cache WHERE key LIKE 'unified-search:v1:%'").fetchone()[0]
        self.assertEqual(count, 3)
        self.assertEqual(self.api.db.get_cache('artist-profile:existing'), {'name': 'Preserved'})


if __name__ == '__main__':
    unittest.main()
