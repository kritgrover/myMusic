"""Account discovery controls, recording feedback, and seed-centered radio."""
import unittest
from contextlib import closing, ExitStack
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class DiscoveryPersonalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user('discovery-listener', 'unused')
        cls.other = cls.api.db.create_user('discovery-private', 'unused')
        cls.headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.user['id'], cls.user['username'])}
        cls.other_headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.other['id'], cls.other['username'])}
        from recommendation_ranking import ListeningPreferences
        cls.preferences_class = ListeningPreferences

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        with closing(self.api.db.get_connection()) as conn, conn:
            for table in ('discovery_preferences', 'discovery_feedback', 'history', 'saved_library',
                          'playlist_songs', 'playlists', 'spotify_cache', 'download_owners'):
                conn.execute('DELETE FROM ' + table)

    def song(self, title='Seed', artist='Seed Artist', **extra):
        return {'id': title.lower().replace(' ', '-'), 'title': title, 'artist': artist, **extra}

    def save(self, song, headers=None):
        response = self.client.put('/library/tracks/' + song['id'], headers=headers or self.headers,
                                   json={key: value for key, value in song.items()
                                         if key in {'title', 'artist', 'album', 'filename', 'url', 'thumbnail', 'spotify_id', 'duration'}})
        self.assertEqual(response.status_code, 200, response.text)

    def dismiss(self, song, headers=None):
        response = self.client.post('/discovery/feedback', headers=headers or self.headers,
                                    json={'action': 'less_like_this', 'track': song})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['feedback_id']

    def providers_down(self):
        stack = ExitStack()
        for name in ('search_track', 'get_recommendations', 'get_genre_recommendations', 'get_artist_genres'):
            stack.enter_context(patch.object(self.api.spotify_service, name, side_effect=RuntimeError('private provider token')))
        return stack

    def test_preferences_defaults_partial_updates_restart_and_account_isolation(self):
        default = self.client.get('/discovery/preferences', headers=self.headers).json()
        self.assertEqual(default, {'mode': 'balanced', 'autoplay': False, 'onboarding_completed': False, 'seed_artists': []})
        choices = [{'id': 'artist123', 'name': 'Chosen Artist', 'thumbnail': 'https://i.scdn.co/image/art'}]
        response = self.client.patch('/discovery/preferences', headers=self.headers,
                                     json={'mode': 'discover', 'seed_artists': choices, 'onboarding_completed': True})
        self.assertEqual(response.status_code, 200, response.text)
        response = self.client.patch('/discovery/preferences', headers=self.headers, json={'autoplay': True})
        self.assertEqual(response.json(), {**default, 'mode': 'discover', 'autoplay': True,
                                          'onboarding_completed': True, 'seed_artists': choices})
        from database import Database
        self.assertEqual(Database().get_discovery_preferences(self.user['id']), response.json())
        self.assertEqual(self.client.get('/discovery/preferences', headers=self.other_headers).json(), default)
        self.assertEqual(self.client.get('/library', headers=self.headers).json()['artists'], [])

    def test_preferences_reject_unbounded_ambiguous_or_credential_bearing_inputs(self):
        artist = {'id': 'chosen', 'name': 'Chosen'}
        for value in ({'mode': 'random'}, {'autoplay': 1}, {'onboarding_completed': 'true'},
                      {'seed_artists': [artist] * 6}, {'seed_artists': [artist, artist]},
                      {'seed_artists': [{'id': '../private', 'name': 'Chosen'}]},
                      {'seed_artists': [{'id': 'chosen', 'name': 'Chosen', 'thumbnail': 'https://example.com/a?media_token=secret'}]},
                      {'user_id': self.other['id']}):
            with self.subTest(value=value):
                result = self.client.patch('/discovery/preferences', headers=self.headers, json=value)
                self.assertEqual(result.status_code, 400, result.text)
        result = self.client.patch('/discovery/preferences', headers=self.headers,
                                  json={'seed_artists': [{**artist, 'thumbnail': '/downloads/private.mp3/artwork'}]})
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(result.json()['seed_artists'][0]['thumbnail'], '')

    def test_new_discovery_endpoints_require_authentication(self):
        for path in ('/discovery/preferences', '/discovery/feedback', '/discovery/artists?q=artist'):
            self.assertEqual(self.client.get(path).status_code, 401)
        self.assertEqual(self.client.patch('/discovery/preferences', json={'autoplay': True}).status_code, 401)
        self.assertEqual(self.client.post('/discovery/radio', json={'seed': self.song()}).status_code, 401)
        self.assertEqual(self.client.post('/discovery/feedback', json={'track': self.song(), 'action': 'less_like_this'}).status_code, 401)

    def test_feedback_is_durable_idempotent_owned_and_does_not_remove_library_music(self):
        song = self.song(spotify_id='track123', artist_id='artist123')
        self.save(song)
        identity = self.dismiss({**song, 'filename': 'private.mp3', 'url': 'https://open.spotify.com/track/track123'})
        self.assertEqual(self.dismiss(song), identity)
        from database import Database
        feedback = Database().get_discovery_feedback(self.user['id'])
        self.assertEqual(len(feedback), 1)
        self.assertNotIn('filename', feedback[0]['track'])
        self.assertNotIn('url', feedback[0]['track'])
        self.assertEqual(self.client.get('/discovery/feedback', headers=self.other_headers).json(), {'feedback': []})
        self.assertEqual(self.client.delete('/discovery/feedback/' + identity, headers=self.other_headers).status_code, 404)
        self.assertEqual(len(self.client.get('/library', headers=self.headers).json()['tracks']), 1)
        self.assertEqual(self.client.delete('/discovery/feedback/' + identity, headers=self.headers).status_code, 200)
        self.assertEqual(self.api.db.get_discovery_feedback(self.user['id']), [])

    def test_dismissed_recording_never_returns_through_sparse_fallback_and_undo_restores_it(self):
        song = self.song()
        self.save(song)
        identity = self.dismiss(song)
        with self.providers_down():
            for shelf in ('daily', 'for-you', 'mixes', 'because-you-listened'):
                result = self.client.get('/recommendations/' + shelf, headers=self.headers)
                self.assertEqual(result.status_code, 200, result.text)
                self.assertEqual(result.json(), [], shelf)
            self.client.delete('/discovery/feedback/' + identity, headers=self.headers)
            restored = self.client.get('/recommendations/for-you', headers=self.headers).json()
        self.assertEqual([track['title'] for track in restored], ['Seed'])

    def test_modes_change_familiarity_mix_recency_window_and_artist_diversity(self):
        familiar = [self.song('Known ' + str(i), 'Known Artist ' + str(i)) for i in range(8)]
        new = [self.song('New ' + str(i), 'New Artist ' + str(i)) for i in range(8)]
        results = {}
        for mode in ('familiar', 'balanced', 'discover'):
            preferences = self.preferences_class([], {'tracks': familiar}, settings={'mode': mode})
            results[mode] = preferences.discover(familiar + new, limit=6, day_seed='stable')
        self.assertEqual(sum(song['title'].startswith('Known') for song in results['familiar']), 6)
        self.assertEqual(sum(song['title'].startswith('Known') for song in results['balanced']), 2)
        self.assertEqual(sum(song['title'].startswith('Known') for song in results['discover']), 0)
        now = datetime.now(timezone.utc)
        history = [{'song_title': 'Played', 'artist': 'Artist', 'duration_played': 100,
                    'duration_seconds': 100, 'qualified': True, 'event_id': 'played',
                    'timestamp': (now - timedelta(days=4)).isoformat()}]
        self.assertNotIn(('played', 'artist'), self.preferences_class(history, {}, now=now, settings={'mode': 'familiar'}).recent)
        self.assertIn(('played', 'artist'), self.preferences_class(history, {}, now=now, settings={'mode': 'discover'}).recent)
        pool = [self.song('Same ' + str(i), 'Favorite') for i in range(10)] + new
        for mode, cap in (('familiar', 4), ('balanced', 3), ('discover', 2)):
            preferences = self.preferences_class([], {'artists': [{'id': 'favorite', 'name': 'Favorite'}]}, settings={'mode': mode})
            ranked = preferences.discover(pool + pool, limit=8, day_seed='stable')
            self.assertEqual(sum(song['artist'] == 'Favorite' for song in ranked), cap)
            self.assertEqual(len({song['id'] for song in ranked}), 8)

    def test_feedback_targets_recording_and_gently_reduces_artist_affinity(self):
        original = self.song('Song', spotify_id='original', artist_id='artist', recording_type='original')
        live = self.song('Song (Live)', spotify_id='live', artist_id='artist', recording_type='live')
        library = {'artists': [{'id': 'artist', 'name': 'Seed Artist'}]}
        preferences = self.preferences_class([], library, feedback=[{'track': original}])
        self.assertEqual(preferences.artists['seed artist'], 2.25)
        self.assertEqual(preferences.discover([original, live], limit=20), [live])
        self.assertEqual(preferences.discover([original], exclude=[original]), [])
        self.assertFalse(preferences.allows({**original, 'artist': 'Seed Artist, Guest'}))

    def test_onboarding_artist_is_used_as_seed_without_following_artist(self):
        self.client.patch('/discovery/preferences', headers=self.headers,
                          json={'seed_artists': [{'id': 'chosenArtist', 'name': 'Chosen Artist'}]})
        with patch.object(self.api.spotify_service, 'get_artist_genres', return_value=[]), \
                patch.object(self.api.spotify_service, 'get_recommendations', return_value=[]) as recommend:
            response = self.client.get('/recommendations/for-you', headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(recommend.call_args.kwargs['seed_artists'], ['chosenArtist'])
        self.assertEqual(self.client.get('/library', headers=self.headers).json()['artists'], [])

    def test_radio_uses_seed_excludes_queue_feedback_and_collapses_provider_duplicates(self):
        seed = self.song(spotify_id='seed', artist_id='artist')
        queued = self.song('Queued', spotify_id='queued', artist_id='artist')
        dismissed = self.song('Dismissed', spotify_id='dismissed', artist_id='artist')
        allowed = self.song('Related', spotify_id='related', artist_id='artist')
        self.dismiss(dismissed)
        with patch.object(self.api.spotify_service, 'get_recommendations', return_value=[seed, queued, dismissed, allowed, allowed]) as recommend:
            response = self.client.post('/discovery/radio', headers=self.headers,
                                        json={'seed': seed, 'exclude': [queued], 'limit': 20})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual([song['title'] for song in response.json()['tracks']], ['Related'])
        recommend.assert_called_once_with(seed_tracks=['seed'], seed_artists=['artist'], limit=50)

    def test_all_five_chosen_artists_rotate_into_provider_seeds_despite_heavy_history(self):
        choices = [{'id': 'choice' + str(i), 'name': 'Chosen ' + str(i)} for i in range(5)]
        library = {'artists': [{'id': 'old', 'name': 'Old Favorite'}],
                   'tracks': [self.song('Old ' + str(i), 'Old Favorite') for i in range(30)]}
        selected = set()
        with patch.object(self.api.spotify_service, 'search_track', return_value=None), \
                patch.object(self.api.spotify_service, 'get_artist_genres', return_value=[]), \
                patch.object(self.api, 'datetime') as clock:
            for day in range(5):
                clock.now.return_value = datetime(2026, 11, 20, tzinfo=timezone.utc) + timedelta(days=day)
                preferences = self.preferences_class([], library, settings={'seed_artists': choices})
                seeds = self.api._recommendation_seeds(self.user['id'], preferences)
                self.assertEqual(len(seeds['seed_artists']), 2)
                self.assertNotIn('old', seeds['seed_artists'])
                selected.update(seeds['seed_artists'])
                other = self.api._recommendation_seeds(self.user['id'], preferences, shelf='for-you')
                self.assertNotEqual(seeds['seed_artists'], other['seed_artists'])
        self.assertEqual(selected, {artist['id'] for artist in choices})

    def test_radio_resolves_metadata_seed_once_and_removes_seed_despite_display_credit_change(self):
        seed = self.song()
        resolved = self.song(id='catalogSeed', spotify_id='catalogSeed', artist_id='artist')
        catalog_seed = {**resolved, 'artist': 'Seed Artist, Guest'}
        with patch.object(self.api.spotify_service, 'search_track', return_value=resolved) as search, \
                patch.object(self.api.spotify_service, 'get_recommendations', return_value=[catalog_seed]):
            response = self.client.post('/discovery/radio', headers=self.headers, json={'seed': seed})
        search.assert_called_once_with('Seed', 'Seed Artist')
        self.assertEqual(response.json()['tracks'], [])
        self.assertIn('message', response.json())

    def test_radio_provider_failure_uses_only_seed_artist_library_and_never_other_accounts(self):
        self.save(self.song('Related'))
        self.save(self.song('Unrelated', 'Other Artist'))
        self.save(self.song('Other account song'), headers=self.other_headers)
        with self.providers_down():
            response = self.client.post('/discovery/radio', headers=self.headers, json={'seed': self.song(spotify_id='seed')})
            empty = self.client.post('/discovery/radio', headers=self.headers,
                                     json={'seed': self.song(spotify_id='seed'), 'exclude': [self.song('Related')]})
        self.assertEqual([song['title'] for song in response.json()['tracks']], ['Related'])
        self.assertIn('library', response.json()['message'])
        self.assertEqual(empty.json()['tracks'], [])
        self.assertNotIn('private provider token', empty.text)

    def test_radio_cleans_private_files_and_preserves_owned_source_when_merging(self):
        owned = self.root / 'downloads' / 'radio-owned.mp3'
        owned.write_bytes(b'audio')
        self.api.db.claim_download(self.user['id'], owned.name)
        own = self.song('Related', filename=owned.name, spotify_id='related', artist_id='artist')
        self.save(own)
        private = self.root / 'downloads' / 'radio-private.mp3'
        private.write_bytes(b'private')
        self.api.db.claim_download(self.other['id'], private.name)
        forged = self.song('Other related', filename=private.name,
                           thumbnail='/downloads/' + private.name + '/artwork', spotify_id='other', artist_id='artist')
        catalog = self.song('Related', spotify_id='related', artist_id='artist', thumbnail='https://i.scdn.co/image/album')
        with patch.object(self.api.spotify_service, 'get_recommendations', return_value=[catalog, forged]):
            response = self.client.post('/discovery/radio', headers=self.headers,
                                        json={'seed': self.song(spotify_id='seed', artist_id='artist')})
        self.assertEqual(response.status_code, 200, response.text)
        tracks = {track['title']: track for track in response.json()['tracks']}
        self.assertEqual(tracks['Related']['filename'], owned.name)
        self.assertEqual(tracks['Related']['thumbnail'], 'https://i.scdn.co/image/album')
        self.assertEqual(tracks['Other related']['filename'], '')
        self.assertEqual(tracks['Other related']['thumbnail'], '')

    def test_radio_and_feedback_reject_oversized_or_credential_bearing_metadata(self):
        seed = self.song()
        for payload in ({'seed': seed, 'limit': 31}, {'seed': seed, 'limit': True},
                        {'seed': seed, 'exclude': [seed] * 101}, {'seed': {**seed, 'duration': False}},
                        {'seed': {**seed, 'url': 'https://example.com/a?media_token=private'}},
                        {'seed': {**seed, 'file_path': 'C:/private.mp3'}},
                        {'seed': {**seed, 'title': 'x' * 301}}):
            with self.subTest(payload=payload):
                self.assertEqual(self.client.post('/discovery/radio', headers=self.headers, json=payload).status_code, 400)
        self.assertEqual(self.client.post('/discovery/feedback', headers=self.headers,
                                         json={'action': 'delete', 'track': seed}).status_code, 400)

    def test_artist_search_supported_path_and_safe_unavailable_results(self):
        response = self.client.get('/discovery/artists?q=Seed', headers=self.headers)
        self.assertEqual(response.status_code, 503)
        raw = [{'id': 'artist', 'name': 'Seed Artist', 'images': [{'url': 'https://i.scdn.co/image/portrait'}]}]
        with patch.object(self.api.spotify_service, 'sp', object()), \
                patch.object(self.api.spotify_service, '_search_items', return_value=raw) as search:
            response = self.client.get('/discovery/artists?q=Seed', headers=self.headers)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['artists'][0]['id'], 'artist')
        search.assert_called_once_with('Seed', 'artist', 10)
        with patch.object(self.api.spotify_service, 'sp', object()), \
                patch.object(self.api.spotify_service, '_search_items', side_effect=RuntimeError('private token')):
            response = self.client.get('/discovery/artists?q=Seed', headers=self.headers)
        self.assertEqual(response.status_code, 503)
        self.assertNotIn('private token', response.text)
        self.assertEqual(self.client.get('/discovery/artists?q=', headers=self.headers).status_code, 400)


if __name__ == '__main__':
    unittest.main()
