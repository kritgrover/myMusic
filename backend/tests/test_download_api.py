"""Durable API and playlist integration without providers or real user data."""
import time
import unittest
from contextlib import closing
from unittest.mock import patch

from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class DownloadApiTests(unittest.TestCase):
    def setUp(self):
        self.environment = isolated_backend()
        self.api, self.root = self.environment.__enter__()
        self.client = TestClient(self.api.app)
        self.user = self.api.db.create_user('download-owner', 'unused')
        self.other = self.api.db.create_user('download-other', 'unused')
        self.headers = {'Authorization': 'Bearer ' + self.api.create_access_token(self.user['id'], 'download-owner')}
        self.other_headers = {'Authorization': 'Bearer ' + self.api.create_access_token(self.other['id'], 'download-other')}
        self.source = 'https://www.youtube.com/watch?v=testFixture'
        self.start = patch.object(self.api.download_jobs, 'start')
        self.start_mock = self.start.start()

    def tearDown(self):
        self.start.stop()
        self.client.close()
        self.environment.__exit__(None, None, None)

    def submit(self, **fields):
        response = self.client.post('/downloads/batch', headers=self.headers,
            json={'downloads': [{'url': self.source, 'title': 'Song', 'artist': 'Artist', **fields}]})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['download_id']

    def playlist(self):
        playlist = self.api.db.create_playlist(self.user['id'], 'Keep this order')
        for song_id in ('first', 'second'):
            playlist = self.api.db.add_song_to_playlist(self.user['id'], playlist['id'], {
                'id': song_id, 'title': 'Canonical ' + song_id, 'artist': 'Canonical Artist',
                'album': 'Album', 'thumbnail': 'https://example.com/cover.jpg',
                'duration': 123, 'url': self.source, 'filename': '', 'file_path': '',
            })
        return playlist

    def finish_next(self, manager=None):
        manager = manager or self.api.download_jobs
        item = manager._claim()
        self.assertIsNotNone(item)
        filename = f"users/{self.user['id']}/{item['payload']['download_key']}.m4a"
        file = self.root / 'downloads' / filename
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b'completed-audio')
        result = {'filename': filename, 'file_path': str(file),
                  'title': item['payload']['title'], 'artist': 'Artist', 'album': ''}
        with patch.object(self.api.download_service, 'download_audio', return_value=result) as download:
            completed = manager.callback(item['payload'], item['user_id'], lambda: False)
        manager._finish(item, completed)
        self.assertEqual(download.call_args.kwargs['download_key'], item['payload']['download_key'])
        return filename

    def test_jobs_and_actions_are_private_and_invalid_batches_never_enqueue(self):
        job_id = self.submit()
        self.assertEqual(self.client.get('/downloads/jobs', headers=self.other_headers).json(), {'jobs': []})
        for route in (f'/downloads/jobs/{job_id}/cancel', f'/downloads/jobs/{job_id}/retry'):
            self.assertEqual(self.client.post(route, headers=self.other_headers).status_code, 404)
        self.assertEqual(self.client.get(f'/downloads/progress/{job_id}', headers=self.other_headers).status_code, 404)
        self.assertEqual(self.client.get('/downloads/jobs').status_code, 401)
        for entries in ([], [{'title': 'Song', 'url': self.source}] * 501,
                        [{'title': 'Bad', 'url': 'http://127.0.0.1/private'}]):
            response = self.client.post('/downloads/batch', headers=self.headers, json={'downloads': entries})
            self.assertGreaterEqual(response.status_code, 400)
        self.assertEqual(len(self.api.download_jobs.list(self.user['id'])), 1)

    def test_cancel_retry_and_reopen_database_keep_same_job(self):
        job_id = self.submit()
        cancelled = self.client.post(f'/downloads/jobs/{job_id}/cancel', headers=self.headers).json()
        self.assertEqual(cancelled['state'], 'cancelled')
        self.assertTrue(cancelled['can_retry'])
        retried = self.client.post(f'/downloads/jobs/{job_id}/retry', headers=self.headers)
        self.assertEqual(retried.status_code, 200, retried.text)
        self.assertEqual(retried.json()['state'], 'queued')
        self.assertEqual(self.client.post(f'/downloads/jobs/{job_id}/retry', headers=self.headers).status_code, 409)
        reopened = self.api.DownloadJobManager(self.api.db, self.api._run_download_item)
        filename = self.finish_next(reopened)
        progress = self.client.get(f'/downloads/progress/{job_id}', headers=self.headers).json()
        self.assertEqual((progress['state'], progress['processed']), ('completed', 1))
        self.assertEqual(progress['downloads'][0]['filename'], filename)
        self.assertTrue(self.api.db.owns_download(self.user['id'], filename))

    def test_playlist_completion_persists_without_changing_metadata_or_order(self):
        before = self.playlist()
        job_id = self.submit(playlist_id=before['id'], playlist_song_id='second')
        filename = self.finish_next()
        after = self.api.db.get_playlist(self.user['id'], before['id'])
        self.assertEqual([row['id'] for row in after['songs']], ['first', 'second'])
        for index, row in enumerate(after['songs']):
            for key in ('title', 'artist', 'album', 'thumbnail', 'url', 'duration'):
                self.assertEqual(row[key], before['songs'][index][key])
        self.assertEqual(after['songs'][0]['filename'], '')
        self.assertEqual(after['songs'][1]['filename'], filename)
        self.assertEqual(self.api.download_jobs.get(self.user['id'], job_id)['processed'], 1)

    def test_playlist_validation_and_removal_during_download(self):
        playlist = self.playlist()
        response = self.client.post('/downloads/batch', headers=self.other_headers, json={'downloads': [{
            'url': self.source, 'title': 'Song', 'playlist_id': playlist['id'], 'playlist_song_id': 'second'}]})
        self.assertEqual(response.status_code, 404)
        self.submit(playlist_id=playlist['id'], playlist_song_id='second')
        self.api.db.remove_song_from_playlist(self.user['id'], playlist['id'], 'second')
        filename = self.finish_next()
        self.assertTrue(self.api.db.owns_download(self.user['id'], filename))
        self.assertEqual([row['id'] for row in self.api.db.get_playlist(self.user['id'], playlist['id'])['songs']], ['first'])

    def test_attachment_does_not_overwrite_a_newer_download_or_source(self):
        playlist = self.playlist()
        for change in ("filename='newer.m4a'", "url='https://www.youtube.com/watch?v=abcdefghijk'"):
            with closing(self.api.db.get_connection()) as conn, conn:
                conn.execute(f"UPDATE playlist_songs SET filename='',url=?,{change} WHERE playlist_id=? AND source_id='second'",
                             (self.source, playlist['id']))
            self.assertFalse(self.api.db.attach_download_to_playlist(self.user['id'], playlist['id'],
                'second', 'old.m4a', '/old.m4a', self.source))

    def test_active_csv_progress_never_expires(self):
        now = time.time()
        self.api.csv_progress.update({
            'active': {'status': 'Searching...', 'created_at': now - 10000},
            'old': {'status': 'completed', 'created_at': now - 10000, 'finished_at': now - 4000},
            'recent': {'status': 'completed', 'created_at': now - 10000, 'finished_at': now},
        })
        self.api.cleanup_old_progress()
        self.assertEqual(set(self.api.csv_progress), {'active', 'recent'})

    def test_lifecycle_resumes_saved_jobs_and_closes_background_services(self):
        job_id = self.submit()
        with patch.object(self.api.metadata_service, 'close') as close, \
             patch.object(self.api.download_jobs, 'shutdown') as shutdown:
            with TestClient(self.api.app) as client:
                self.assertEqual(client.get('/downloads/jobs', headers=self.headers).json()['jobs'][0]['download_id'], job_id)
            close.assert_called_once()
            shutdown.assert_called_once()
        self.assertEqual(self.start_mock.call_count, 2)


if __name__ == '__main__':
    unittest.main()
