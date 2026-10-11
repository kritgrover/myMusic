"""Saved-library data validation, persistence, and authorization regressions."""

import unittest
from urllib.parse import quote
from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class SavedLibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user("saved-listener", "unused")
        cls.other = cls.api.db.create_user("saved-other", "unused")
        cls.headers = {"Authorization": "Bearer " + cls.api.create_access_token(cls.user['id'], cls.user['username'])}
        cls.other_headers = {"Authorization": "Bearer " + cls.api.create_access_token(cls.other['id'], cls.other['username'])}
        cls.source = "https://www.youtube.com/watch?v=testFixture"
        cls.filename = "private art.mp3"
        (cls.root / "downloads" / cls.filename).write_bytes(b"audio")
        cls.api.db.claim_download(cls.user['id'], cls.filename)

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def put(self, kind, item_id, payload, headers=None):
        return self.client.put('/library/' + kind + '/' + quote(item_id, safe=''), headers=headers or self.headers, json=payload)

    def test_all_library_methods_require_access_token(self):
        self.assertEqual(self.client.get('/library').status_code, 401)
        self.assertEqual(self.client.put('/library/artists/a', json={'name': 'A'}).status_code, 401)
        self.assertEqual(self.client.delete('/library/artists/a').status_code, 401)

    def test_metadata_normalization_preserves_source_and_order(self):
        first = self.put('tracks', 'ordering-one', {'id': 'original-youtube-id', 'title': '  Song one ', 'artist': None, 'url': 'https://youtu.be/testFixture?t=30', 'duration': None})
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(first.json()['source_id'], 'original-youtube-id')
        self.assertEqual(first.json()['artist'], '')
        self.assertEqual(first.json()['url'], self.source)
        self.assertEqual(first.json()['duration'], 0)
        self.put('tracks', 'ordering-two', {'title': 'Song two'})
        library = self.client.get('/library', headers=self.headers).json()
        keys = [item['id'] for item in library['tracks']]
        self.assertLess(keys.index('ordering-two'), keys.index('ordering-one'))
        updated = self.put('tracks', 'ordering-one', {'title': 'Updated song', 'source_id': 'original-youtube-id'})
        self.assertEqual(updated.status_code, 200)
        library = self.client.get('/library', headers=self.headers).json()
        self.assertEqual(library['tracks'][0]['id'], 'ordering-one')
        self.assertEqual(sum(item['id'] == 'ordering-one' for item in library['tracks']), 1)

    def test_unknown_kinds_and_unbounded_metadata_rejected_without_writes(self):
        cases = [
            ('podcasts', 'bad-kind', {'name': 'bad'}),
            ('tracks', 'bad-title', {'title': 'x' * 301}),
            ('tracks', 'missing-title', {'artist': 'a'}),
            ('artists', 'blank-name', {'name': '   '}),
            ('albums', 'unknown-field', {'title': 'a', 'access_token': 'not-saved'}),
            ('tracks', 'bad-type', {'title': {'nested': 'object'}}),
            ('tracks', 'bad-bool', {'title': 'a', 'artist': False}),
            ('tracks', 'negative', {'title': 'a', 'duration': -1}),
            ('tracks', 'too-long', {'title': 'a', 'duration': 86401}),
            ('tracks', 'bool-duration', {'title': 'a', 'duration': True}),
            ('tracks', 'injected', {'title': 'a\x00b'}),
            ('tracks', 'file-path', {'title': 'a', 'file_path': 'C:/secret'}),
        ]
        for kind, item_id, payload in cases:
            with self.subTest(item=item_id):
                self.assertEqual(self.put(kind, item_id, payload).status_code, 400)
        self.assertEqual(self.put('tracks', 'x' * 513, {'title': 'a'}).status_code, 400)
        library = self.client.get('/library', headers=self.headers).json()
        saved_ids = {item['id'] for items in library.values() for item in items}
        self.assertFalse(saved_ids & {item_id for _, item_id, _ in cases})

    def test_signed_urls_credentials_and_non_youtube_sources_never_persist(self):
        urls = [self.source + '&media_token=secret', self.source + '&%6dedia_token=secret',
                '/stream/' + quote(self.source, safe='') + '?media_token=secret',
                'https://youtube.com.evil.test/watch?v=testFixture', 'file:///private.mp3']
        for url in urls:
            with self.subTest(url=url):
                self.assertEqual(self.put('tracks', 'bad-source', {'title': 'A', 'url': url}).status_code, 400)
        thumbnails = ['https://images.example.test/a?access_token=secret',
                      'https://user:secret@images.example.test/a', 'javascript:alert(1)',
                      'data:image/png;base64,AAAA', '/auth/me', 'https://images.example.test/a?token=secret']
        for thumbnail in thumbnails:
            with self.subTest(thumbnail=thumbnail):
                self.assertEqual(self.put('albums', 'bad-thumb', {'title': 'A', 'thumbnail': thumbnail}).status_code, 400)
        library = self.client.get('/library', headers=self.headers).json()
        self.assertNotIn('bad-source', [item['id'] for item in library['tracks']])
        self.assertNotIn('bad-thumb', [item['id'] for item in library['albums']])
        for field in ('id', 'source_id', 'spotify_id'):
            response = self.put('tracks', 'bad-identity', {'title': 'A', field: '/downloads/a.mp3?media_token=secret'})
            self.assertEqual(response.status_code, 400)
        self.assertEqual(self.put('tracks', 'media_token=secret', {'title': 'A'}).status_code, 400)

    def test_missing_download_file_does_not_break_saved_track_playback_choice(self):
        path = self.root / 'downloads' / 'removed-externally.mp3'
        path.write_bytes(b'temporary')
        self.api.db.claim_download(self.user['id'], path.name)
        self.assertEqual(self.put('tracks', 'removed-external', {'title': 'Retained like', 'filename': path.name, 'url': self.source}).status_code, 200)
        path.unlink()
        saved = next(item for item in self.client.get('/library', headers=self.headers).json()['tracks'] if item['id'] == 'removed-external')
        self.assertEqual(saved['filename'], '')
        self.assertEqual(saved['url'], self.source)

    def test_artwork_only_preserves_owned_backend_references(self):
        artwork = '/downloads/' + quote(self.filename, safe='') + '/artwork'
        own = self.put('tracks', 'own-artwork', {'title': 'Own art', 'filename': self.filename, 'thumbnail': artwork})
        self.assertEqual(own.status_code, 200, own.text)
        self.assertEqual(own.json()['thumbnail'], artwork)
        other = self.put('albums', 'other-artwork', {'title': 'No access', 'thumbnail': artwork}, headers=self.other_headers)
        self.assertEqual(other.status_code, 200, other.text)
        self.assertEqual(other.json()['thumbnail'], '')
        playlist = self.api.db.create_playlist(self.user['id'], 'Own cover')
        cover = '/playlists/' + playlist['id'] + '/cover'
        self.assertEqual(self.put('albums', 'own-cover', {'title': 'Own', 'thumbnail': cover}).json()['thumbnail'], cover)
        self.assertEqual(self.put('albums', 'other-cover', {'title': 'Other', 'thumbnail': cover}, headers=self.other_headers).json()['thumbnail'], '')
        self.api.db.delete_playlist(self.user['id'], playlist['id'])
        albums = self.client.get('/library', headers=self.headers).json()['albums']
        self.assertEqual(next(item for item in albums if item['id'] == 'own-cover')['thumbnail'], '')

    def test_failed_edit_does_not_replace_previous_saved_metadata(self):
        self.put('artists', 'safe-existing', {'name': 'Original', 'thumbnail': 'https://images.example.test/cover.jpg'})
        rejected = self.put('artists', 'safe-existing', {'name': 'Changed', 'thumbnail': 'https://user:password@images.example.test/cover.jpg'})
        self.assertEqual(rejected.status_code, 400)
        artists = self.client.get('/library', headers=self.headers).json()['artists']
        self.assertEqual(next(item for item in artists if item['id'] == 'safe-existing')['name'], 'Original')


if __name__ == '__main__':
    unittest.main()
