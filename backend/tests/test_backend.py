"""Regression tests. Run: py -m unittest discover -s backend/tests -v"""

import hashlib
import sqlite3
import unittest
from pathlib import Path
from urllib.parse import quote
from unittest.mock import AsyncMock, Mock, patch

from fastapi.testclient import TestClient

from isolated_backend import isolated_backend


class BackendRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.user = cls.api.db.create_user("test-listener", "unused-test-hash")
        cls.other = cls.api.db.create_user("other-listener", "unused-test-hash")
        cls.headers = {"Authorization": "Bearer " + cls.api.create_access_token(cls.user["id"], cls.user["username"])}
        cls.audio = cls.root / "downloads" / "fixture.MP3"
        cls.audio.write_bytes(b"0123456789")
        cls.api.db.claim_download(cls.user["id"], "fixture.MP3")
        cls.client.headers.update(cls.headers)

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def test_health(self):
        self.assertEqual(self.client.get("/").json()["status"], "running")

    def test_restart_preserves_artwork_and_ignores_expired_entries(self):
        from database import Database

        self.api.db.set_album_cover_cache("fresh-cover", "https://example.test/cover.png", 90)
        self.api.db.set_album_cover_cache("expired-cover", "https://example.test/old.png", 50)
        self.api.db.set_cache("expired-spotify", {"fixture": True}, ttl_seconds=-1)
        with sqlite3.connect(self.api.db.db_url) as connection:
            connection.execute("UPDATE album_cover_cache SET created_at = ? WHERE cache_key = ?",
                               ("2000-01-01T00:00:00", "expired-cover"))
        connection.close()
        restarted = Database()
        self.assertEqual(restarted.get_album_cover_cache("fresh-cover"),
                         {"artwork_url": "https://example.test/cover.png", "match_score": 90})
        self.assertIsNone(restarted.get_album_cover_cache("expired-cover"))
        self.assertIsNone(restarted.get_cache("expired-spotify"))

    def test_full_audio_and_head(self):
        response = self.client.get("/downloads/fixture.MP3")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"0123456789")
        self.assertEqual(response.headers["content-type"], "audio/mpeg")
        head = self.client.head("/downloads/fixture.MP3")
        self.assertEqual(head.status_code, 200)
        self.assertEqual(head.content, b"")
        self.assertEqual(head.headers["content-length"], "10")

    def test_seeking_returns_only_requested_bytes(self):
        cases = [("bytes=2-5", b"2345", "bytes 2-5/10"),
                 ("bytes=7-", b"789", "bytes 7-9/10"),
                 ("bytes=-3", b"789", "bytes 7-9/10"),
                 ("bytes=8-500", b"89", "bytes 8-9/10")]
        for header, content, content_range in cases:
            with self.subTest(header=header):
                response = self.client.get("/downloads/fixture.MP3", headers={"Range": header})
                self.assertEqual(response.status_code, 206)
                self.assertEqual(response.content, content)
                self.assertEqual(response.headers["content-range"], content_range)
                self.assertEqual(response.headers["content-length"], str(len(content)))

    def test_invalid_ranges(self):
        for header in ("bytes=10-", "bytes=8-2", "bytes=-0", "bytes=-", "bytes=nope"):
            with self.subTest(header=header):
                response = self.client.get("/downloads/fixture.MP3", headers={"Range": header})
                self.assertEqual(response.status_code, 416)
                self.assertEqual(response.headers["content-range"], "bytes */10")

    def test_range_on_empty_file(self):
        (self.root / "downloads" / "empty.mp3").write_bytes(b"")
        self.api.db.claim_download(self.user["id"], "empty.mp3")
        response = self.client.get("/downloads/empty.mp3", headers={"Range": "bytes=0-"})
        self.assertEqual(response.status_code, 416)
        self.assertEqual(response.headers["content-range"], "bytes */0")

    def test_stale_if_range_returns_complete_audio(self):
        response = self.client.get("/downloads/fixture.MP3", headers={"Range": "bytes=2-5", "If-Range": '"stale"'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"0123456789")
        current = self.client.get("/downloads/fixture.MP3", headers={"Range": "bytes=2-5", "If-Range": response.headers["etag"]})
        self.assertEqual(current.status_code, 206)

    def test_path_traversal_rejects_sibling_prefix_and_windows_separators(self):
        for filename in ("../downloads-other/secret.mp3", "..\\downloads-other\\secret.mp3"):
            with self.subTest(filename=filename):
                with self.assertRaises(self.api.HTTPException) as failure:
                    self.api.validate_path_safety(str(self.root / "downloads"), filename)
                self.assertEqual(failure.exception.status_code, 400)
        nested = self.api.validate_path_safety(str(self.root / "downloads"), "album\\song.mp3")
        self.assertEqual(nested, self.root / "downloads" / "album" / "song.mp3")

    def test_artwork_route_precedes_catchall(self):
        from mutagen.id3 import ID3, APIC
        path = self.root / "downloads" / "cover.mp3"
        tags = ID3()
        tags.add(APIC(mime="image/png", type=3, data=b"test-cover-image"))
        tags.save(path)
        self.api.db.claim_download(self.user["id"], "cover.mp3")
        response = self.client.get("/downloads/cover.mp3/artwork")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"test-cover-image")

    def test_deleted_missing_file_stays_404(self):
        response = self.client.delete("/downloads/missing.mp3", headers=self.headers)
        self.assertEqual(response.status_code, 404)

    def test_csv_upload_rejects_escape_before_writing(self):
        response = self.client.post("/csv/upload", headers=self.headers,
            files={"file": ("../escaped.csv", b"title,artist\nfixture,test", "text/csv")})
        self.assertEqual(response.status_code, 400)
        self.assertFalse((self.root / "escaped.csv").exists())

    def test_stream_cache_supports_seeking_and_stays_out_of_library(self):
        youtube_url = "https://www.youtube.com/watch?v=testFixture"
        cache = self.root / "downloads" / "_stream_cache"
        cache.mkdir(exist_ok=True)
        (cache / (hashlib.sha256(youtube_url.encode()).hexdigest() + ".m4a")).write_bytes(b"abcdefghij")
        with patch.object(self.api.download_service, "get_streaming_url", side_effect=RuntimeError("test fallback")):
            response = self.client.get("/stream/" + quote(youtube_url, safe=""), headers={"Range": "bytes=3-6"})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(response.content, b"defg")
        library = self.client.get("/downloads", headers=self.headers).json()["files"]
        self.assertFalse(any("_stream_cache" in item["filename"] for item in library))

    def test_upstream_range_is_streamed_without_buffering_and_closed(self):
        import httpx

        class AudioStream(httpx.AsyncByteStream):
            async def __aiter__(self):
                yield b"2345"

        upstream = httpx.Response(206, headers={"Content-Range": "bytes 2-5/10", "Content-Length": "4"}, stream=AudioStream())
        upstream.aread = AsyncMock(side_effect=AssertionError("Audio must not be buffered"))
        upstream_client = Mock()
        upstream_client.send = AsyncMock(return_value=upstream)
        upstream_client.aclose = AsyncMock()
        with patch.object(self.api.download_service, "get_streaming_url", return_value="https://test.googlevideo.com/audio"), \
                patch.object(self.api.httpx, "AsyncClient", return_value=upstream_client):
            response = self.client.get("/stream/" + quote("https://www.youtube.com/watch?v=testFixture", safe=""), headers={"Range": "bytes=2-5"})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(response.content, b"2345")
        self.assertEqual(response.headers["content-range"], "bytes 2-5/10")
        upstream.aread.assert_not_awaited()
        upstream_client.aclose.assert_awaited_once()
        self.assertTrue(upstream.is_closed)

    def test_upstream_connection_failure_closes_client_before_fallback(self):
        upstream_client = Mock()
        upstream_client.send = AsyncMock(side_effect=RuntimeError("connection failed"))
        upstream_client.aclose = AsyncMock()
        youtube_url = "https://www.youtube.com/watch?v=cacheFixtur"
        cache = self.root / "downloads" / "_stream_cache"
        cache.mkdir(exist_ok=True)
        (cache / (hashlib.sha256(youtube_url.encode()).hexdigest() + ".m4a")).write_bytes(b"cached")
        with patch.object(self.api.download_service, "get_streaming_url", return_value="https://test.googlevideo.com/audio"), \
                patch.object(self.api.httpx, "AsyncClient", return_value=upstream_client):
            response = self.client.get("/stream/" + quote(youtube_url, safe=""))
        self.assertEqual(response.content, b"cached")
        upstream_client.aclose.assert_awaited_once()

    def test_upstream_non_audio_success_falls_back_to_cached_audio(self):
        import httpx

        source = "https://www.youtube.com/watch?v=contentType"
        cache = self.root / "downloads" / "_stream_cache"
        cache.mkdir(exist_ok=True)
        (cache / (hashlib.sha256(source.encode()).hexdigest() + ".m4a")).write_bytes(b"cached-audio")
        for content_type in ("text/html; charset=utf-8", "application/json",
                             "application/vnd.apple.mpegurl", "audio/x-mpegurl",
                             "application/dash+xml"):
            with self.subTest(content_type=content_type):
                upstream = httpx.Response(200, headers={"Content-Type": content_type}, content=b"not audio")
                upstream_client = Mock()
                upstream_client.send = AsyncMock(return_value=upstream)
                upstream_client.aclose = AsyncMock()
                with patch.object(self.api.download_service, "get_streaming_url", return_value="https://test.googlevideo.com/audio"), \
                        patch.object(self.api.httpx, "AsyncClient", return_value=upstream_client):
                    response = self.client.get("/stream/" + quote(source, safe=""),
                                               headers={"User-Agent": "libmpv"})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.content, b"cached-audio")
                self.assertEqual(response.headers["content-type"], "audio/mp4")
                headers = upstream_client.build_request.call_args.kwargs["headers"]
                self.assertIn("Mozilla/5.0", headers["User-Agent"])
                self.assertNotIn("libmpv", headers["User-Agent"])
                upstream_client.aclose.assert_awaited_once()
                self.assertTrue(upstream.is_closed)

    def test_stream_provider_failure_reports_safe_gateway_error(self):
        with patch.object(self.api.download_service, "get_streaming_url", side_effect=RuntimeError("private extractor detail")), \
                patch.object(self.api.stream_cache, "acquire", side_effect=RuntimeError("private cookie path")):
            response = self.client.get("/stream/" + quote("https://www.youtube.com/watch?v=failedAudio", safe=""))
        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.json()["detail"], "YouTube audio is unavailable. Please try again later.")
        self.assertNotIn("private", response.text)

    def test_cover_requires_auth_and_accepts_owner(self):
        playlist = self.api.db.create_playlist(self.user["id"], "Cover fixture")
        covers = self.root / "covers"
        covers.mkdir(exist_ok=True)
        (covers / (playlist["id"] + ".png")).write_bytes(b"cover-fixture")
        url = "/playlists/" + playlist["id"] + "/cover"
        self.api.db.update_playlist_cover(self.user["id"], playlist["id"], url)
        self.assertEqual(self.client.get(url, headers={"Authorization": ""}).status_code, 401)
        self.assertEqual(self.client.get(url, headers=self.headers).content, b"cover-fixture")
        other_headers = {"Authorization": "Bearer " + self.api.create_access_token(self.other["id"], self.other["username"])}
        self.assertEqual(self.client.get(url, headers=other_headers).status_code, 404)

    def test_same_track_can_belong_to_multiple_playlists_and_users(self):
        song = {"id": "shared-track", "title": "A fixture", "filename": "", "url": "https://example.test/fixture"}
        first = self.api.db.create_playlist(self.user["id"], "One")
        second = self.api.db.create_playlist(self.user["id"], "Two")
        other = self.api.db.create_playlist(self.other["id"], "Other")
        for user, playlist in ((self.user, first), (self.user, second), (self.other, other)):
            result = self.api.db.add_song_to_playlist(user["id"], playlist["id"], song)
            self.assertEqual(result["songs"][0]["id"], song["id"])
            duplicate = self.api.db.add_song_to_playlist(user["id"], playlist["id"], song)
            self.assertEqual(len(duplicate["songs"]), 1)
        removed = self.api.db.remove_song_from_playlist(self.user["id"], first["id"], song["id"])
        self.assertEqual(removed["songs"], [])
        self.assertEqual(len(self.api.db.get_playlist(self.user["id"], second["id"])["songs"]), 1)
        self.assertEqual(len(self.api.db.get_playlist(self.other["id"], other["id"])["songs"]), 1)

    def test_legacy_song_ids_remain_readable_and_removable(self):
        playlist = self.api.db.create_playlist(self.user["id"], "Legacy")
        with sqlite3.connect(self.api.db.db_url) as connection:
            connection.execute("INSERT INTO playlist_songs (id, playlist_id, title, created_at) VALUES (?, ?, ?, ?)",
                               ("legacy-track", playlist["id"], "Legacy fixture", "2025-01-01"))
        legacy = self.api.db.get_playlist(self.user["id"], playlist["id"])
        self.assertEqual(legacy["songs"][0]["id"], "legacy-track")
        duplicate = self.api.db.add_song_to_playlist(self.user["id"], playlist["id"], {"id": "legacy-track", "title": "Same"})
        self.assertEqual(len(duplicate["songs"]), 1)
        removed = self.api.db.remove_song_from_playlist(self.user["id"], playlist["id"], "legacy-track")
        self.assertEqual(removed["songs"], [])

    def test_encoded_source_and_filename_track_ids_can_be_removed(self):
        playlist = self.api.db.create_playlist(self.user["id"], "Encoded IDs")
        route = "/playlists/" + playlist["id"] + "/songs"
        ids = ("fixture/source-track.mp3", "https://www.youtube.com/watch?v=testFixture#chapter",
               "percent%2F song?one#two.mp3", "café/曲.mp3")
        for song_id in ids:
            added = self.client.post(route, json={"id": song_id, "title": song_id, "filename": ""})
            self.assertEqual(added.status_code, 200, added.text)
        for song_id in ids:
            with self.subTest(song_id=song_id):
                response = self.client.delete(route + "/" + quote(song_id, safe=""))
                self.assertEqual(response.status_code, 200, response.text)
                self.assertNotIn(song_id, [song["id"] for song in response.json()["songs"]])
        self.assertEqual(self.api.db.get_playlist(self.user["id"], playlist["id"])["songs"], [])

    def test_encoded_track_id_removal_remains_owner_scoped(self):
        playlist = self.api.db.create_playlist(self.other["id"], "Other encoded ID")
        song_id = "private/folder/song.mp3?version=1#part"
        self.api.db.add_song_to_playlist(self.other["id"], playlist["id"],
                                         {"id": song_id, "title": "Other", "filename": ""})
        response = self.client.delete("/playlists/" + playlist["id"] + "/songs/" + quote(song_id, safe=""))
        self.assertEqual(response.status_code, 404)
        self.assertEqual(len(self.api.db.get_playlist(self.other["id"], playlist["id"])["songs"]), 1)

    def test_existing_playlist_table_upgrades_without_rewriting_rows(self):
        from database import Database

        path = self.root / "legacy-upgrade.db"
        with sqlite3.connect(path) as connection:
            connection.execute("""CREATE TABLE playlist_songs (
                id TEXT PRIMARY KEY, playlist_id TEXT NOT NULL, title TEXT NOT NULL,
                artist TEXT, album TEXT, filename TEXT, file_path TEXT, url TEXT,
                thumbnail TEXT, duration REAL, created_at DATETIME NOT NULL)""")
            connection.execute("INSERT INTO playlist_songs (id, playlist_id, title, created_at) VALUES (?, ?, ?, ?)",
                               ("existing-id", "existing-playlist", "Existing title", "2025-01-01"))
        connection.close()
        legacy_db = Database.__new__(Database)
        legacy_db.db_url = str(path)
        legacy_db.init_db()
        legacy_db.init_db()  # Startup remains idempotent.
        with sqlite3.connect(path) as connection:
            row = connection.execute("SELECT id, title, source_id FROM playlist_songs").fetchone()
        connection.close()
        self.assertEqual(row, ("existing-id", "Existing title", None))


if __name__ == "__main__":
    unittest.main()
