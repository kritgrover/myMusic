"""Artwork must identify the requested artist, recording, and known album."""
import asyncio
import unittest
from unittest.mock import AsyncMock, Mock, patch

from isolated_backend import isolated_backend


class AlbumArtworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, _ = cls.environment.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.environment.__exit__(None, None, None)

    def result(self, **overrides):
        return dict(artistName='Bad Omens', trackName='Just Pretend',
                    collectionName='THE DEATH OF PEACE OF MIND',
                    artworkUrl100='https://artwork.example/100x100.jpg', **overrides)

    def test_match_requires_artist_and_exact_recording_not_shared_title(self):
        result = self.result()
        self.assertEqual(self.api._score_itunes_result(result, 'Just Pretend', 'Bad Omens', ''), 70)
        for changes in [dict(artistName='Another Artist'),
                        dict(artistName='Bad Omens Tribute Band'),
                        dict(trackName='Just Pretend (Live)'),
                        dict(trackName='Just Pretend Again')]:
            with self.subTest(changes=changes):
                self.assertEqual(self.api._score_itunes_result(
                    {**result, **changes}, 'Just Pretend', 'Bad Omens', ''), 0)
        self.assertEqual(self.api._score_itunes_result(result, 'Just Pretend', '', ''), 0)

    def test_known_album_and_explicit_collaboration_are_respected(self):
        result = self.result()
        self.assertEqual(self.api._score_itunes_result(
            result, 'Just Pretend', 'Bad Omens', 'THE DEATH OF PEACE OF MIND'), 100)
        self.assertEqual(self.api._score_itunes_result(
            result, 'Just Pretend', 'Bad Omens', 'Different album'), 0)
        collaboration = {**result, 'artistName': 'Bad Omens & Poppy',
                         'trackName': 'V.A.N.'}
        self.assertEqual(self.api._score_itunes_result(
            collaboration, 'V.A.N.', 'Bad Omens', ''), 70)

    def lookup(self, results):
        response = Mock(status_code=200)
        response.json.return_value = {'results': results}
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.get.return_value = response
        with patch.object(self.api.httpx, 'AsyncClient', return_value=client), \
             patch.object(self.api.db, 'get_album_cover_cache', return_value=None), \
             patch.object(self.api.db, 'set_album_cover_cache') as cache:
            value = asyncio.run(self.api.get_album_cover('Just Pretend', 'Bad Omens'))
            return value, cache.call_args_list

    def test_wrong_match_never_returns_speculative_artwork(self):
        value, calls = self.lookup([{**self.result(), 'artistName': 'Another Artist'}])
        self.assertIsNone(value['artwork_url'])
        self.assertFalse(any(call.args[1] for call in calls))

    def test_verified_cover_wins_and_uses_new_cache_namespace(self):
        value, calls = self.lookup([
            {**self.result(), 'artistName': 'Another Artist'}, self.result()])
        self.assertEqual(value['artwork_url'], 'https://artwork.example/600x600.jpg')
        self.assertEqual(value['matched_artist'], 'Bad Omens')
        self.assertTrue(calls[0].args[0].startswith('artwork-v3:'))

    def test_cache_identity_preserves_empty_fields_and_delimiters(self):
        self.assertNotEqual(self.api._album_cover_cache_key('Song', 'Name', ''),
                            self.api._album_cover_cache_key('Song', '', 'Name'))
        self.assertNotEqual(self.api._album_cover_cache_key('Song', 'Name', 'Album'),
                            self.api._album_cover_cache_key('Song', 'Album', 'Name'))

    def test_known_artist_is_not_replaced_by_a_dashed_recording_title(self):
        self.assertEqual(self.api._artwork_metadata('Just Pretend - Live', 'Bad Omens'),
                         {'title': 'Just Pretend - Live', 'artist': 'Bad Omens'})
        self.assertEqual(self.api._artwork_metadata('Bad Omens - Just Pretend (Official Audio)', 'Bad Omens'),
                         {'title': 'Just Pretend', 'artist': 'Bad Omens'})


if __name__ == '__main__':
    unittest.main()
