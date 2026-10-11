"""Deterministic listening preferences and resilient private-library shelves."""
import unittest
from contextlib import closing, ExitStack
from datetime import datetime, timezone, timedelta
from unittest.mock import patch
from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class RecommendationRankingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user('rank-listener', 'unused')
        cls.other = cls.api.db.create_user('rank-private', 'unused')
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
            for table in ('history', 'saved_library', 'playlist_songs', 'playlists', 'spotify_cache', 'download_owners'):
                conn.execute('DELETE FROM ' + table)

    def row(self, title, artist='Artist', listened=120, reason='completed', duration=120, **changes):
        value = dict(song_title=title, artist=artist, duration_played=listened, duration_seconds=duration,
                     end_reason=reason, event_id='event', qualified=listened >= min(30, duration * .5) if duration else listened >= 30,
                     timestamp=datetime.now(timezone.utc).isoformat())
        value.update(changes)
        return value

    def test_full_listens_and_repeat_occurrences_outrank_clicks_and_early_skips(self):
        rows = [self.row('Repeated'), self.row('Repeated'), self.row('Completed'),
                self.row('Skipped', listened=1, reason='skipped'),
                self.row('Legacy click', listened=0, event_id=None), self.row('Seek end', listened=1)]
        preferences = self.preferences_class(rows, {})
        ranked = preferences.rank([{'title': name, 'artist': 'Artist'} for name in ('Skipped', 'Completed', 'Repeated', 'Legacy click', 'Seek end')])
        self.assertEqual([track['title'] for track in ranked][:2], ['Repeated', 'Completed'])
        self.assertEqual(ranked[-1]['title'], 'Skipped')
        self.assertNotIn('Legacy click', [track['title'] for track in preferences.top_tracks()])
        self.assertNotIn('Seek end', [track['title'] for track in preferences.top_tracks()])

    def test_errors_and_stops_are_not_negative_but_intentional_short_skip_is(self):
        preferences = self.preferences_class([self.row('Error', listened=1, reason='error'),
            self.row('Stopped', listened=1, reason='stopped'), self.row('Skip', listened=1, reason='skipped')], {})
        self.assertEqual(preferences.tracks[('error', 'artist')], 0)
        self.assertEqual(preferences.tracks[('stopped', 'artist')], 0)
        self.assertLess(preferences.tracks[('skip', 'artist')], 0)
        late_skip = self.preferences_class([self.row('Long listen', listened=90, reason='skipped')], {})
        self.assertGreater(late_skip.tracks[('long listen', 'artist')], 0)

    def test_likes_follows_and_albums_influence_normalized_artist_and_track_preferences(self):
        library = {'tracks': [{'title': '  LIKED  SONG ', 'artist': 'Liked artist'}],
                   'artists': [{'id': 'followed', 'name': 'Followed Artist'}],
                   'albums': [{'title': 'Album', 'artist': 'Album Artist'}]}
        preferences = self.preferences_class([], library)
        candidates = [{'title': 'liked song', 'artist': 'liked artist'}, {'title': 'Other', 'artist': 'Followed Artist'},
                      {'title': 'Album Song', 'artist': 'Album Artist'}, {'title': 'Neutral', 'artist': 'Unknown'}]
        self.assertEqual([row['title'] for row in preferences.rank(candidates)], ['liked song', 'Other', 'Album Song', 'Neutral'])
        self.assertEqual(preferences.top_artists()[0]['id'], 'followed')

    def test_recency_decays_and_duplicate_provider_tracks_keep_owned_playable_metadata(self):
        now = datetime.now(timezone.utc)
        preferences = self.preferences_class([self.row('Old', timestamp=(now - timedelta(days=60)).isoformat()), self.row('Fresh')], {}, now=now)
        self.assertGreater(preferences.score({'title': 'Fresh', 'artist': 'Artist'}), preferences.score({'title': 'Old', 'artist': 'Artist'}))
        rows = preferences.rank([{'id': 'provider', 'title': 'One', 'artist': 'Artist', 'filename': ''},
                                 {'id': 'local', 'title': ' ONE ', 'artist': 'ARTIST', 'filename': 'own.mp3'}])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['filename'], 'own.mp3')

    def provider_down(self):
        stack = ExitStack()
        for name in ('search_track', 'get_recommendations', 'get_genre_recommendations', 'get_artist_genres',
                     'get_recommended_artists', 'get_artist_new_releases', 'get_new_releases'):
            stack.enter_context(patch.object(self.api.spotify_service, name, side_effect=RuntimeError('provider unavailable')))
        return stack

    def save_track(self, name='My local song', filename='own.mp3', headers=None):
        return self.client.put('/library/tracks/local-song', headers=headers or self.headers,
            json={'title': name, 'artist': 'Local Artist', 'filename': filename, 'duration': 60})

    def test_provider_failure_returns_owned_download_fallback_and_never_other_users_library(self):
        (self.root / 'downloads' / 'own.mp3').write_bytes(b'audio')
        self.api.db.claim_download(self.user['id'], 'own.mp3')
        self.assertEqual(self.save_track().status_code, 200)
        self.client.put('/library/artists/followed', headers=self.headers, json={'name': 'Local Artist'})
        self.client.put('/library/albums/album', headers=self.headers, json={'title': 'Local Album', 'artist': 'Local Artist'})
        self.client.put('/library/tracks/secret', headers=self.other_headers, json={'title': 'Private other song', 'artist': 'Private Artist'})
        with self.provider_down():
            for endpoint in ('daily', 'for-you'):
                response = self.client.get('/recommendations/' + endpoint, headers=self.headers)
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual([track['title'] for track in response.json()], ['My local song'])
                self.assertEqual(response.json()[0]['filename'], 'own.mp3')
                self.assertEqual(response.json()[0]['duration'], 60)
            self.assertEqual(self.client.get('/recommendations/mixes', headers=self.headers).json()[0]['tracks'][0]['filename'], 'own.mp3')
            self.assertEqual(self.client.get('/recommendations/because-you-listened', headers=self.headers).json()[0]['tracks'][0]['filename'], 'own.mp3')
            self.assertEqual(self.client.get('/recommendations/artists', headers=self.headers).json()[0]['name'], 'Local Artist')
            self.assertEqual(self.client.get('/recommendations/new-releases', headers=self.headers).json()[0]['name'], 'Local Album')
            other = self.client.get('/recommendations/for-you', headers=self.other_headers).json()
            self.assertEqual([track['title'] for track in other], ['Private other song'])

    def test_playlist_fallback_clears_forged_or_missing_downloads_and_signed_artwork(self):
        playlist = self.api.db.create_playlist(self.user['id'], 'Private playlist')
        self.api.db.add_song_to_playlist(self.user['id'], playlist['id'], {'id': 'forged', 'title': 'Preserved title',
            'artist': 'Artist', 'filename': 'other-private.mp3', 'thumbnail': '/downloads/other-private.mp3/artwork',
            'url': 'https://www.youtube.com/watch?v=testFixture&media_token=secret'})
        with self.provider_down():
            result = self.client.get('/recommendations/daily', headers=self.headers)
        self.assertEqual(result.status_code, 200)
        track = result.json()[0]
        self.assertEqual(track['filename'], '')
        self.assertEqual(track['thumbnail'], '')
        self.assertEqual(track['url'], '')
        self.assertNotIn('secret', result.text)

    def test_provider_failure_includes_only_owned_plain_downloads_with_safe_metadata(self):
        from mutagen.id3 import ID3, TIT2, TPE1
        from urllib.parse import quote
        filename = 'download only % song.mp3'
        path = self.root / 'downloads' / filename
        tags = ID3()
        tags.add(TIT2(encoding=3, text='Owned download title'))
        tags.add(TPE1(encoding=3, text='Owned download artist'))
        tags.save(path)
        self.api.db.claim_download(self.user['id'], filename)
        other_path = self.root / 'downloads' / 'other-download.mp3'
        other_path.write_bytes(b'private')
        self.api.db.claim_download(self.other['id'], other_path.name)
        with self.provider_down():
            for endpoint in ('daily', 'for-you'):
                response = self.client.get('/recommendations/' + endpoint, headers=self.headers)
                self.assertEqual(response.status_code, 200, response.text)
                self.assertEqual(len(response.json()), 1)
                track = response.json()[0]
                self.assertEqual(track['filename'], filename)
                self.assertEqual(track['title'], 'Owned download title')
                self.assertEqual(track['artist'], 'Owned download artist')
                self.assertNotIn('file_path', track)
                self.assertEqual(track['thumbnail'], '/downloads/' + quote(filename, safe='/') + '/artwork')
            self.assertEqual(self.client.get('/recommendations/mixes', headers=self.headers).json()[0]['tracks'][0]['filename'], filename)
        signed = self.client.post('/media/authorize', headers=self.headers,
                                  json={'path': '/downloads/' + quote(filename, safe='')})
        self.assertEqual(signed.status_code, 200, signed.text)
        self.assertEqual(self.client.get(signed.json()['url'], headers={'Range': 'bytes=0-9'}).status_code, 206)
        self.assertEqual(self.client.post('/media/authorize', headers=self.other_headers,
                                        json={'path': '/downloads/' + quote(filename, safe='')}).status_code, 404)

    def test_empty_provider_behaves_like_failure_and_cold_start_returns_tracks_not_albums(self):
        track = {'id': 'cold-track', 'title': 'Cold Track', 'artist': 'Artist', 'url': 'https://youtu.be/testFixture'}
        with patch.object(self.api.spotify_service, 'get_recommendations', return_value=[]), \
             patch.object(self.api.spotify_service, 'get_genre_recommendations', return_value=[track]), \
             patch.object(self.api.spotify_service, 'get_new_releases', side_effect=AssertionError('album-shaped cold start')):
            result = self.client.get('/recommendations/for-you', headers=self.headers)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()[0]['title'], 'Cold Track')
        self.assertEqual(result.json()[0]['url'], 'https://www.youtube.com/watch?v=testFixture')

    def test_qualified_history_and_follows_seed_provider_early_skips_do_not(self):
        report = dict(event_id='qualified-listen', sequence=1, song_title='Qualified', artist='Artist',
                      duration_seconds=120, listened_seconds=120, end_reason='completed', spotify_id='qualified-id')
        self.client.post('/history/listening', headers=self.headers, json=report)
        self.client.post('/history/listening', headers=self.headers, json={**report, 'event_id': 'early-skip-event', 'song_title': 'Skip', 'spotify_id': 'skip-id', 'listened_seconds': 1, 'end_reason': 'skipped'})
        self.client.put('/library/artists/followed-id', headers=self.headers, json={'name': 'Followed Artist'})
        with patch.object(self.api.spotify_service, 'get_recommendations', return_value=[]) as provider, \
             patch.object(self.api.spotify_service, 'get_artist_genres', return_value=['electronic']):
            self.assertEqual(self.client.get('/recommendations/daily', headers=self.headers).status_code, 200)
        seeds = provider.call_args.kwargs
        self.assertEqual(seeds['seed_tracks'], ['qualified-id'])
        self.assertEqual(seeds['seed_artists'], ['followed-id'])
        self.assertNotIn('skip-id', str(seeds))
        recap = self.client.get('/analytics/recap', headers=self.headers).json()
        self.assertEqual(recap['top_genres'], ['electronic'])
