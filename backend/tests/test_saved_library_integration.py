"""Saved-library journeys using the same real API/data fixture as browser QA."""

import shutil
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from demo_fixture import TRACKS, PRIVATE_TRACK, browser_fixture, catalogue_track


@unittest.skipUnless(shutil.which("ffmpeg"), "Synthetic browser fixtures require local ffmpeg")
class SavedLibraryIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = browser_fixture()
        cls.api, cls.fixture = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.demo = cls.login(cls.client, "demo", "demo-only")
        cls.other = cls.login(cls.client, "other", "other-only")

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        self.fixture.reset()

    @staticmethod
    def login(client, username, password):
        response = client.post("/auth/login", json={"username": username, "password": password})
        if response.status_code != 200:
            raise AssertionError(response.text)
        return {"Authorization": "Bearer " + response.json()["access_token"]}

    @staticmethod
    def track_payload(track):
        data = catalogue_track(track)
        return {key: data[key] for key in ("id", "title", "artist", "album", "filename", "url", "duration", "thumbnail")}

    def save(self, kind, item_id, payload, headers=None):
        response = self.client.put(f"/library/{kind}/{item_id}", json=payload, headers=headers or self.demo)
        self.assertEqual(response.status_code, 200, response.text)
        return response

    def library(self, headers=None, client=None):
        response = (client or self.client).get("/library", headers=headers or self.demo)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_catalogue_save_reload_and_unsave_journey(self):
        playlists = self.client.get("/playlists", headers=self.demo).json()
        evening = next(item for item in playlists.values() if item["name"] == "Evening rotation")
        track = evening["songs"][0]
        album = self.client.get("/album/evening-signals", headers=self.demo).json()
        artist = self.client.get("/artist/demo-artist", headers=self.demo).json()
        track_id = "youtube:" + track["id"]
        payloads = (
            ("tracks", track_id, self.track_payload(TRACKS[0])),
            ("albums", album["id"], {"title": album["name"], "artist": album["artist"], "thumbnail": album["thumbnail"]}),
            ("artists", artist["id"], {"name": artist["name"], "thumbnail": artist["thumbnail"]}),
        )
        for kind, item_id, payload in payloads:
            self.save(kind, item_id, payload)
            self.save(kind, item_id, payload)
        self.assertEqual({kind: len(rows) for kind, rows in self.library().items()}, {"tracks": 1, "albums": 1, "artists": 1})

        # New browser/API client and new DB object prove storage is persistent,
        # rather than an in-process or front-end optimistic collection.
        from database import Database
        with patch.object(self.api, "db", Database()), TestClient(self.api.app) as reloaded:
            headers = self.login(reloaded, "demo", "demo-only")
            saved = self.library(headers=headers, client=reloaded)
            self.assertEqual(saved["tracks"][0]["id"], track_id)
            self.assertEqual(saved["tracks"][0]["title"], "Night Drive")
            self.assertEqual(saved["albums"][0]["title"], "Evening Signals")
            self.assertEqual(saved["artists"][0]["name"], "Demo Artist")
            other = self.login(reloaded, "other", "other-only")
            self.assertEqual(self.library(headers=other, client=reloaded), {"tracks": [], "albums": [], "artists": []})

        for kind, item_id, _ in payloads:
            for _ in range(2):
                response = self.client.delete(f"/library/{kind}/{item_id}", headers=self.demo)
                self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.library(), {"tracks": [], "albums": [], "artists": []})

    def test_same_catalogue_item_belongs_independently_to_each_account(self):
        item_id = "evening-signals"
        payload = {"title": "Evening Signals", "artist": "Demo Artist"}
        self.save("albums", item_id, payload, self.demo)
        self.save("albums", item_id, payload, self.other)
        response = self.client.delete(f"/library/albums/{item_id}", headers=self.demo)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.library()["albums"], [])
        self.assertEqual([row["id"] for row in self.library(self.other)["albums"]], [item_id])

    def test_forged_filename_cannot_turn_a_like_into_private_media_access(self):
        own_track = self.track_payload(TRACKS[0])
        self.save("tracks", own_track["id"], own_track)
        foreign_track = self.track_payload(PRIVATE_TRACK)
        response = self.client.put("/library/tracks/stolen", json=foreign_track, headers=self.demo)
        self.assertEqual(response.status_code, 404, response.text)
        self.assertEqual([row["id"] for row in self.library()["tracks"]], [own_track["id"]])
        foreign_path = "/downloads/" + foreign_track["filename"]
        authorization = self.client.post("/media/authorize", json={"path": foreign_path}, headers=self.demo)
        self.assertEqual(authorization.status_code, 404)

        saved = self.library()["tracks"][0]
        authorization = self.client.post("/media/authorize", json={"path": "/downloads/" + saved["filename"]}, headers=self.demo)
        self.assertEqual(authorization.status_code, 200, authorization.text)
        media = self.client.get(authorization.json()["url"], headers={"Range": "bytes=0-127"})
        self.assertEqual(media.status_code, 206)
        self.assertEqual(media.headers["content-type"], "audio/mpeg")

    def test_forged_update_preserves_previously_saved_item(self):
        original = self.track_payload(TRACKS[0])
        self.save("tracks", original["id"], original)
        forged = {**original, "filename": catalogue_track(PRIVATE_TRACK)["filename"]}
        response = self.client.put(f"/library/tracks/{original['id']}", json=forged, headers=self.demo)
        self.assertEqual(response.status_code, 404, response.text)
        stored = self.library()["tracks"][0]
        self.assertEqual(stored["filename"], original["filename"])
        self.assertEqual(stored["title"], original["title"])

    def test_download_deletion_keeps_like_and_streamable_source(self):
        original = self.track_payload(TRACKS[0])
        self.save("tracks", original["id"], original)
        deleted = self.client.delete("/downloads/" + original["filename"], headers=self.demo)
        self.assertEqual(deleted.status_code, 200, deleted.text)
        stored = self.library()["tracks"][0]
        self.assertEqual(stored["title"], original["title"])
        self.assertFalse(stored.get("filename"))
        self.assertEqual(stored["url"], original["url"])

    def test_private_saved_artwork_is_canonical_and_remains_authenticated(self):
        original = self.track_payload(TRACKS[0])
        artwork_path = "/downloads/" + original["filename"] + "/artwork"
        original["thumbnail"] = "http://testserver" + artwork_path
        self.save("tracks", original["id"], original)
        stored = self.library()["tracks"][0]
        self.assertEqual(stored["thumbnail"], artwork_path)
        self.assertEqual(self.client.get(artwork_path).status_code, 401)
        self.assertEqual(self.client.get(artwork_path, headers=self.other).status_code, 404)
        owned = self.client.get(artwork_path, headers=self.demo)
        self.assertEqual(owned.status_code, 200, owned.text)
        self.assertEqual(owned.headers["content-type"], "image/png")
        self.assertTrue(owned.content.startswith(b"\x89PNG"))


if __name__ == "__main__":
    unittest.main()
