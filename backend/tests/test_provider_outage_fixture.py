"""Browser outage control leaves genuine local fallback playback available."""
import shutil
import unittest
from fastapi.testclient import TestClient
from demo_fixture import browser_fixture


@unittest.skipUnless(shutil.which('ffmpeg'), 'Synthetic media requires ffmpeg')
class ProviderOutageFixtureTests(unittest.TestCase):
    def test_control_is_authenticated_and_resettable_with_playable_private_fallback(self):
        with browser_fixture() as (api, fixture), TestClient(api.app) as client:
            def login(username, password):
                token = client.post('/auth/login', json={'username': username, 'password': password}).json()['access_token']
                return {'Authorization': 'Bearer ' + token}
            demo, other = login('demo', 'demo-only'), login('other', 'other-only')
            self.assertEqual(client.post('/__test/provider-state', json={'available': False}).status_code, 401)
            self.assertEqual(client.post('/__test/provider-state', json={'available': False}, headers=other).status_code, 403)
            self.assertEqual(client.post('/__test/provider-state', json={'available': 'false'}, headers=demo).status_code, 400)
            self.assertEqual(client.post('/__test/provider-state', json={'available': False}, headers=demo).json(), {'available': False})
            self.assertFalse(client.get('/__test/state', headers=demo).json()['provider_available'])
            response = client.get('/recommendations/for-you', headers=demo)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(len(response.json()), 5)
            self.assertNotIn('Other Private Tone', response.text)
            track = response.json()[0]
            signed = client.post('/media/authorize', json={'path': '/downloads/' + track['filename']}, headers=demo).json()['url']
            self.assertEqual(client.get(signed, headers={'Range': 'bytes=0-127'}).status_code, 206)
            search = client.post('/search', json={'query': 'night drive'}, headers=demo)
            self.assertEqual(search.status_code, 200)
            self.assertEqual(search.json()[0]['title'], 'Night Drive')
            client.post('/__test/reset', headers=demo)
            self.assertTrue(client.get('/__test/state', headers=demo).json()['provider_available'])
