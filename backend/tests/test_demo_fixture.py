"""Browser fixture smoke tests against genuine auth, data, and media routes."""

import shutil
import unittest
from urllib.parse import quote

from fastapi.testclient import TestClient
from mutagen.mp3 import MP3

from demo_fixture import TRACKS, PRIVATE_TRACK, browser_fixture, catalogue_track


@unittest.skipUnless(shutil.which("ffmpeg"), "Synthetic browser fixtures require local ffmpeg")
class BrowserFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = browser_fixture()
        cls.api, cls.fixture = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.demo = cls.login("demo", "demo-only")
        cls.other = cls.login("other", "other-only")

    @classmethod
    def login(cls, username, password):
        response = cls.client.post("/auth/login", json={"username": username, "password": password})
        if response.status_code != 200:
            raise AssertionError(response.text)
        return {"Authorization": "Bearer " + response.json()["access_token"]}

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        self.fixture.reset()

    def test_authentication_and_fixture_controls_are_real(self):
        self.assertEqual(self.client.get("/playlists").status_code, 401)
        self.assertEqual(self.client.get("/__test/state").status_code, 401)
        self.assertEqual(self.client.post("/__test/reset", headers=self.other).status_code, 403)
        bad = self.client.post("/auth/login", json={"username": "demo", "password": "incorrect"})
        self.assertEqual(bad.status_code, 401)
        self.assertTrue(self.client.get("/__test/state", headers=self.demo).json()["fixture"])

    def test_accounts_see_disjoint_downloads(self):
        demo = self.client.get("/downloads", headers=self.demo).json()["files"]
        other = self.client.get("/downloads", headers=self.other).json()["files"]
        self.assertEqual({item["filename"] for item in demo}, {catalogue_track(t)["filename"] for t in TRACKS})
        self.assertEqual([item["filename"] for item in other], [catalogue_track(PRIVATE_TRACK)["filename"]])
        private_path = "/downloads/" + catalogue_track(PRIVATE_TRACK)["filename"]
        self.assertEqual(self.client.get(private_path, headers=self.demo).status_code, 404)
        self.assertEqual(self.client.post("/media/authorize", json={"path": private_path}, headers=self.demo).status_code, 404)

    def test_real_playable_audio_uses_scoped_media_tokens_and_ranges(self):
        track = catalogue_track(TRACKS[0])
        path = "/downloads/" + track["filename"]
        self.assertEqual(self.client.get(path).status_code, 401)
        signed = self.client.post("/media/authorize", json={"path": path}, headers=self.demo)
        self.assertEqual(signed.status_code, 200, signed.text)
        url = signed.json()["url"]
        partial = self.client.get(url, headers={"Range": "bytes=0-127"})
        self.assertEqual(partial.status_code, 206)
        self.assertEqual(len(partial.content), 128)
        self.assertEqual(partial.headers["content-type"], "audio/mpeg")
        self.assertAlmostEqual(MP3(self.fixture.downloads / track["filename"]).info.length, track["duration"], delta=0.1)
        wrong_path = url.replace(TRACKS[0]["id"], TRACKS[1]["id"])
        self.assertEqual(self.client.get(wrong_path).status_code, 401)

    def test_search_album_and_artist_catalogue_are_deterministic(self):
        search = self.client.post("/search", json={"query": "night drive"}, headers=self.demo)
        self.assertEqual(search.status_code, 200, search.text)
        self.assertEqual([row["title"] for row in search.json()], ["Night Drive"])
        album = self.client.get("/album/evening-signals", headers=self.demo).json()
        self.assertEqual(album["total_tracks"], 2)
        tracks = self.client.get("/recommendations/album/evening-signals/tracks", headers=self.demo).json()
        self.assertEqual([t["title"] for t in tracks], ["Night Drive", "City Lights"])
        artist = self.client.get("/artist/demo-artist", headers=self.demo).json()
        self.assertEqual(artist["name"], "Demo Artist")

    def test_streaming_uses_synthetic_aac_through_genuine_cache_and_route(self):
        source = catalogue_track(TRACKS[0])["url"]
        path = "/stream/" + quote(source, safe="")
        signed = self.client.post("/media/authorize", json={"path": path}, headers=self.demo)
        self.assertEqual(signed.status_code, 200, signed.text)
        response = self.client.get(signed.json()["url"], headers={"Range": "bytes=0-127"})
        self.assertEqual(response.status_code, 206, response.text)
        self.assertEqual(response.headers["content-type"], "audio/mp4")
        self.assertIn(b"ftyp", response.content)

    def test_reset_restores_removed_tracks_and_ownership(self):
        filename = catalogue_track(TRACKS[0])["filename"]
        deleted = self.client.delete("/downloads/" + filename, headers=self.demo)
        self.assertEqual(deleted.status_code, 200, deleted.text)
        self.assertFalse((self.fixture.downloads / filename).exists())
        self.assertEqual(self.client.post("/__test/reset", headers=self.demo).status_code, 200)
        self.assertTrue((self.fixture.downloads / filename).exists())
        self.assertEqual(self.client.get("/downloads/" + filename, headers=self.demo).status_code, 200)


if __name__ == "__main__":
    unittest.main()
