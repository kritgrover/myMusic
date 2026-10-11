"""Cumulative, user-scoped listening and recap regressions using disposable data."""
import json
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timezone, timedelta
from unittest.mock import patch
from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class ListeningHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user('listening-user', 'unused')
        cls.other = cls.api.db.create_user('listening-other', 'unused')
        cls.headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.user['id'], cls.user['username'])}
        cls.other_headers = {'Authorization': 'Bearer ' + cls.api.create_access_token(cls.other['id'], cls.other['username'])}

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        with closing(self.api.db.get_connection()) as conn, conn:
            conn.execute('DELETE FROM history')

    def report(self, **changes):
        value = dict(event_id='event-fixture-0001', sequence=1, song_title='Evening', artist='Fixture Artist',
                     duration_seconds=120, listened_seconds=5, end_reason='ongoing')
        value.update(changes)
        return value

    def post(self, value=None, headers=None, **changes):
        return self.client.post('/history/listening', json=value or self.report(**changes), headers=headers or self.headers)

    def history(self, headers=None):
        return self.client.get('/history/recent', headers=headers or self.headers).json()

    def test_authentication_required_and_no_provider_calls_during_ingestion(self):
        self.assertEqual(self.client.post('/history/listening', json=self.report()).status_code, 401)
        with patch.object(self.api.spotify_service, 'search_track', side_effect=AssertionError('network in ingestion')) as search:
            self.assertEqual(self.post().status_code, 200)
            search.assert_not_called()

    def test_legacy_ingestion_stays_compatible_without_provider_calls_or_invalid_totals(self):
        with patch.object(self.api.spotify_service, 'search_track', side_effect=AssertionError('network in ingestion')):
            response = self.client.post('/history', headers=self.headers,
                json={'song_title': 'Legacy Song', 'artist': 'Artist', 'duration_played': 12})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'success': True, 'spotify_id': None})
        self.assertEqual(self.history()[0]['duration_played'], 12)
        for seconds in (-1, float('nan')):
            response = self.client.post('/history', content=json.dumps({'song_title': 'Invalid', 'artist': 'Artist', 'duration_played': seconds}),
                headers={**self.headers, 'Content-Type': 'application/json'})
            self.assertEqual(response.status_code, 400)

    def test_retry_and_out_of_order_reports_count_once_and_never_reduce_time(self):
        self.assertTrue(self.post().json()['accepted'])
        self.assertFalse(self.post().json()['accepted'])
        self.assertTrue(self.post(sequence=3, listened_seconds=45).json()['qualified'])
        self.assertFalse(self.post(sequence=2, listened_seconds=80).json()['accepted'])
        self.assertEqual(self.post(sequence=4, listened_seconds=20).json()['listened_seconds'], 45)
        rows = self.history()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['duration_played'], 45)
        recap = self.client.get('/analytics/recap', headers=self.headers).json()
        self.assertEqual(recap['totals']['plays'], 1)
        self.assertEqual(recap['totals']['minutes'], 0.8)

    def test_paused_event_resumes_but_terminal_event_never_reopens(self):
        self.post(end_reason='paused', listened_seconds=15)
        resumed = self.post(sequence=2, listened_seconds=35).json()
        self.assertTrue(resumed['accepted'])
        self.assertFalse(resumed['closed'])
        ended = self.post(sequence=3, listened_seconds=70, end_reason='completed').json()
        self.assertTrue(ended['closed'])
        self.assertFalse(self.post(sequence=4, listened_seconds=100).json()['accepted'])
        self.assertEqual(self.history()[0]['duration_played'], 70)

    def test_same_event_id_is_private_per_account_and_identity_is_immutable(self):
        self.post()
        other = self.post(headers=self.other_headers, song_title='Other private song')
        self.assertEqual(other.status_code, 200)
        self.assertEqual(self.history(self.other_headers)[0]['song_title'], 'Other private song')
        self.assertEqual(self.post(sequence=2, song_title='Forged replacement').status_code, 409)
        self.assertEqual(self.history()[0]['song_title'], 'Evening')

    def test_canonical_source_may_fill_unknown_then_cannot_be_replaced(self):
        self.post()
        self.assertEqual(self.post(sequence=2, source_url='https://youtu.be/testFixture?t=25').status_code, 200)
        self.assertEqual(self.history()[0]['source_url'], 'https://www.youtube.com/watch?v=testFixture')
        self.assertEqual(self.post(sequence=3, source_url='https://youtu.be/otherVideo1').status_code, 409)

    def test_short_track_threshold_and_unknown_duration_threshold(self):
        self.assertFalse(self.post(duration_seconds=12, listened_seconds=5).json()['qualified'])
        self.assertTrue(self.post(sequence=2, duration_seconds=12, listened_seconds=6).json()['qualified'])
        self.assertFalse(self.post(event_id='unknown-duration', duration_seconds=0, listened_seconds=29).json()['qualified'])
        self.assertTrue(self.post(event_id='unknown-duration', sequence=2, duration_seconds=0, listened_seconds=30).json()['qualified'])

    def test_seeking_to_end_does_not_create_qualified_play_but_relisten_time_is_retained(self):
        self.assertFalse(self.post(listened_seconds=2, end_reason='completed').json()['qualified'])
        result = self.post(event_id='seek-back-listen', duration_seconds=12, listened_seconds=24, end_reason='stopped')
        self.assertEqual(result.json()['listened_seconds'], 24)
        self.assertTrue(result.json()['qualified'])

    def test_invalid_numbers_fields_and_secrets_never_write(self):
        invalid = [{'sequence': 0}, {'sequence': True}, {'sequence': 1.5}, {'event_id': '../short'},
                   {'song_title': ''}, {'song_title': 'x' * 301}, {'artist': {'nested': 'value'}},
                   {'artist': 'x\x00y'}, {'duration_seconds': -1}, {'listened_seconds': True},
                   {'listened_seconds': 86401}, {'duration_seconds': float('nan')},
                   {'listened_seconds': float('inf')}, {'end_reason': 'buffering'},
                   {'source_url': 'https://evil.test/audio'},
                   {'source_url': 'https://youtu.be/testFixture?media_token=secret'},
                   {'spotify_id': 'bearer secret'}, {'unexpected_field': 'private'}]
        for changes in invalid:
            with self.subTest(changes=changes):
                response = self.client.post('/history/listening', content=json.dumps(self.report(**changes)),
                    headers={**self.headers, 'Content-Type': 'application/json'})
                self.assertEqual(response.status_code, 400, response.text)
        self.assertEqual(self.history(), [])

    def test_concurrent_reports_merge_atomically_and_survive_database_reopen(self):
        reports = [self.api.validate_report(self.report(sequence=index, listened_seconds=index * 2)) for index in range(1, 21)]
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda report: self.api.db.upsert_listening(self.user['id'], report), reports))
        from database import Database
        reopened = Database()
        rows = reopened.get_recent_history(self.user['id'])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['sequence'], 20)
        self.assertEqual(rows[0]['duration_played'], 40)

    def test_recap_handles_space_iso_utc_and_offsets_at_precise_boundaries(self):
        timestamps = [('2026-10-10 10:59:59.999', 20), ('2026-10-10 11:00:00', 30),
                      ('2026-10-10T11:30:00+00:00', 40), ('2026-10-10T07:45:00-04:00', 50),
                      ('2026-10-10T12:00:00+00:00', 60), ('2026-10-10 11:15:00', 0)]
        with closing(self.api.db.get_connection()) as conn, conn:
            conn.executemany('INSERT INTO history(user_id,song_title,artist,duration_played,timestamp) VALUES (?,?,?,?,?)',
                [(self.user['id'], 'Track', 'Artist', seconds, timestamp) for timestamp, seconds in timestamps])
        start, end = '2026-10-10T11:00:00+00:00', '2026-10-10T12:00:00+00:00'
        summary = self.api.db.get_history_summary(self.user['id'], start, end)
        self.assertEqual(summary, {'plays': 3, 'total_duration_played': 120, 'unique_artists': 1})
        self.assertEqual(self.api.db.get_top_tracks_in_range(self.user['id'], start, end)[0]['count'], 3)
        self.assertEqual(self.api.db.get_top_artists_in_range(self.user['id'], start, end)[0]['count'], 3)

    def test_new_timestamps_are_utc_and_legacy_zero_rows_do_not_inflate_recap(self):
        self.api.db.add_history(self.user['id'], 'Legacy click', 'Artist', 0)
        self.post(listened_seconds=5)
        recap = self.client.get('/analytics/recap', headers=self.headers).json()
        self.assertEqual(recap['totals']['plays'], 0)
        self.assertEqual(recap['totals']['unique_artists'], 0)
        self.assertEqual(recap['top_tracks'], [])
        self.assertTrue(self.history()[0]['timestamp'].endswith('+00:00'))
        self.assertTrue(recap['end_date'].endswith('+00:00'))
