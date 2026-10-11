"""Adversarial media authorization and cache regressions using only temporary data."""

import hashlib
import os
import sqlite3
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from urllib.parse import quote, urlsplit, parse_qs
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient
from isolated_backend import isolated_backend


class PrivateMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        cls.client = TestClient(cls.api.app)
        cls.one = cls.api.db.create_user("media-one", "unused")
        cls.two = cls.api.db.create_user("media-two", "unused")
        cls.h1 = {"Authorization": "Bearer " + cls.api.create_access_token(cls.one["id"], "media-one")}
        cls.h2 = {"Authorization": "Bearer " + cls.api.create_access_token(cls.two["id"], "media-two")}
        cls.file = cls.root / "downloads" / "only-one.mp3"
        cls.file.write_bytes(b"0123456789")
        cls.api.db.claim_download(cls.one["id"], cls.file.name)
        cls.source = "https://www.youtube.com/watch?v=testFixture"

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.environment.__exit__(None, None, None)

    def signed(self, path="/downloads/only-one.mp3"):
        response = self.client.post("/media/authorize", json={"path": path}, headers=self.h1)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()["url"]

    def test_audio_and_artwork_are_private_without_auth(self):
        for path in ("/downloads/only-one.mp3", "/downloads/only-one.mp3/artwork", "/stream/" + quote(self.source, safe="")):
            self.assertEqual(self.client.get(path).status_code, 401)
            self.assertEqual(self.client.head(path).status_code, 401)

    def test_valid_signed_get_head_and_seek(self):
        signed = self.signed()
        response = self.client.get(signed, headers={"Range": "bytes=2-5"})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(response.content, b"2345")
        self.assertEqual(response.headers["cache-control"], "private, no-store")
        head = self.client.head(signed)
        self.assertEqual(head.status_code, 200)
        self.assertEqual(head.content, b"")

    def test_encoded_unicode_and_literal_percent_filenames_round_trip(self):
        filename = "unicode café %20 # song.mp3"
        (self.root / "downloads" / filename).write_bytes(b"unicode")
        self.api.db.claim_download(self.one["id"], filename)
        signed = self.signed("/downloads/" + quote(filename, safe=""))
        self.assertEqual(self.client.get(signed).content, b"unicode")

    def test_other_user_cannot_list_read_sign_or_delete_file(self):
        self.assertNotIn(self.file.name, [file["filename"] for file in self.client.get("/downloads", headers=self.h2).json()["files"]])
        self.assertEqual(self.client.get("/downloads/only-one.mp3", headers=self.h2).status_code, 404)
        self.assertEqual(self.client.get("/downloads/only-one.mp3/artwork", headers=self.h2).status_code, 404)
        self.assertEqual(self.client.post("/media/authorize", json={"path": "/downloads/only-one.mp3"}, headers=self.h2).status_code, 404)
        self.assertEqual(self.client.delete("/downloads/only-one.mp3", headers=self.h2).status_code, 404)
        self.assertTrue(self.file.exists())

    def test_media_token_cannot_authenticate_api_or_change_path_method(self):
        signed = self.signed()
        token = parse_qs(urlsplit(signed).query)["media_token"][0]
        self.assertEqual(self.client.get("/auth/me", headers={"Authorization": "Bearer " + token}).status_code, 401)
        self.assertEqual(self.client.get("/downloads?media_token=" + token).status_code, 401)
        self.assertEqual(self.client.delete(signed).status_code, 401)
        self.assertEqual(self.client.get(signed.replace("only-one.mp3", "other.mp3")).status_code, 401)
        self.assertEqual(self.client.get(signed.replace("only-one.mp3", "only-one.mp3/artwork")).status_code, 401)
        access = self.h1["Authorization"].split()[1]
        self.assertEqual(self.client.get("/downloads/only-one.mp3?media_token=" + access).status_code, 401)

    def test_expired_inactive_and_revoked_claim_tokens_fail(self):
        from auth_utils import create_media_token
        from config import settings
        with patch.object(settings, "MEDIA_TOKEN_SECONDS", -10, create=True):
            expired, _ = create_media_token(self.one["id"], "/downloads/only-one.mp3")
        self.assertEqual(self.client.get("/downloads/only-one.mp3?media_token=" + expired).status_code, 401)
        signed = self.signed()
        with closing(sqlite3.connect(self.api.db.db_url)) as conn, conn:
            conn.execute("UPDATE users SET is_active=0 WHERE id=?", (self.one["id"],))
        try:
            self.assertEqual(self.client.get(signed).status_code, 401)
        finally:
            with closing(sqlite3.connect(self.api.db.db_url)) as conn, conn:
                conn.execute("UPDATE users SET is_active=1 WHERE id=?", (self.one["id"],))
        self.api.db.unclaim_download(self.one["id"], self.file.name)
        try:
            self.assertEqual(self.client.get(signed).status_code, 404)
        finally:
            self.api.db.claim_download(self.one["id"], self.file.name)

    def test_media_signing_rejects_non_audio_traversal_and_external_paths(self):
        for path in ("https://evil.test/downloads/a.mp3", "/auth/me", "/downloads/a.mp3/artwork", "/downloads/../secret.mp3", "/downloads/_stream_cache/x.m4a", "/downloads/a.mp3?x=y"):
            with self.subTest(path=path):
                self.assertIn(self.client.post("/media/authorize", json={"path": path}, headers=self.h1).status_code, (400, 404))

    def test_download_claims_owner_and_batch_rejects_before_launch(self):
        result = {"filename": "new.mp3", "file_path": "", "title": "New", "artist": "", "album": ""}
        with patch.object(self.api.download_service, "download_audio", return_value=result) as downloader:
            response = self.client.post("/download", headers=self.h1, json={"url": "https://youtu.be/testFixture", "title": "New"})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(self.api.db.owns_download(self.one["id"], "new.mp3"))
        self.assertFalse(self.api.db.owns_download(self.two["id"], "new.mp3"))
        self.assertEqual(downloader.call_args.kwargs["owner_id"], self.one["id"])
        with patch.object(self.api.download_service, "download_audio") as downloader:
            response = self.client.post("/downloads/batch", headers=self.h1, json={"downloads": [{"url": self.source, "title": "valid"}, {"url": "file:///secret", "title": "invalid"}]})
        self.assertEqual(response.status_code, 400)
        downloader.assert_not_called()

    def test_delete_shared_file_only_removes_callers_claim_and_references(self):
        filename = "shared.mp3"
        path = self.root / "downloads" / filename
        path.write_bytes(b"shared")
        playlists = []
        for user in (self.one, self.two):
            self.api.db.claim_download(user["id"], filename)
            playlist = self.api.db.create_playlist(user["id"], "shared")
            self.api.db.add_song_to_playlist(user["id"], playlist["id"], {"id": filename, "title": "shared", "filename": filename})
            playlists.append(playlist)
        self.assertEqual(self.client.delete("/downloads/" + filename, headers=self.h1).status_code, 200)
        self.assertTrue(path.exists())
        self.assertEqual(self.api.db.get_playlist(self.one["id"], playlists[0]["id"])["songs"][0]["filename"], "")
        self.assertEqual(self.api.db.get_playlist(self.two["id"], playlists[1]["id"])["songs"][0]["filename"], filename)
        self.assertEqual(self.client.get("/downloads/" + filename, headers=self.h2).status_code, 200)

    def test_playlist_cannot_forge_download_ownership(self):
        playlist = self.api.db.create_playlist(self.two["id"], "forged")
        response = self.client.post("/playlists/" + playlist["id"] + "/songs", headers=self.h2,
                                    json={"id": "forged", "title": "forged", "filename": self.file.name})
        self.assertEqual(response.status_code, 404)
        self.assertFalse(self.api.db.owns_download(self.two["id"], self.file.name))

    def test_delete_only_clears_exact_file_including_legacy_backslash_reference(self):
        filenames = ('collision.mp3', 'nested/collision.mp3', 'other/nested/collision.mp3')
        playlist = self.api.db.create_playlist(self.one['id'], 'Filename collisions')
        for index, filename in enumerate(filenames):
            path = self.root / 'downloads' / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'collision fixture')
            self.api.db.claim_download(self.one['id'], filename)
            self.api.db.add_song_to_playlist(self.one['id'], playlist['id'],
                {'id': str(index), 'title': str(index), 'filename': filename.replace('/', '\\'),
                 'file_path': str(path), 'url': self.source})
        response = self.client.delete('/downloads/' + quote(filenames[1], safe=''), headers=self.h1)
        self.assertEqual(response.status_code, 200, response.text)
        tracks = self.api.db.get_playlist(self.one['id'], playlist['id'])['songs']
        by_title = {track['title']: track for track in tracks}
        self.assertEqual(by_title['1']['filename'], '')
        self.assertEqual(by_title['1']['file_path'], '')
        self.assertEqual(by_title['1']['url'], self.source)
        for index in (0, 2):
            self.assertEqual(by_title[str(index)]['filename'], filenames[index].replace('/', '\\'))
            self.assertTrue((self.root / 'downloads' / filenames[index]).is_file())
            self.assertEqual(self.client.get('/downloads/' + quote(filenames[index], safe=''), headers=self.h1).status_code, 200)

    def test_public_playlists_share_source_without_private_file_references(self):
        playlist = self.api.db.create_playlist(self.one["id"], "public fixture")
        self.api.db.add_song_to_playlist(self.one["id"], playlist["id"], {"id": "public", "title": "Public", "filename": self.file.name, "file_path": str(self.file), "url": self.source})
        self.api.db.set_playlist_public(self.one["id"], playlist["id"], True)
        url = f'/users/{self.one["id"]}/playlists/{playlist["id"]}'
        response = self.client.get(url, headers=self.h2)
        self.assertEqual(response.json()["songs"][0]["filename"], "")
        self.assertEqual(response.json()["songs"][0]["file_path"], "")
        self.assertEqual(response.json()["songs"][0]["url"], self.source)
        saved = self.client.post(url + "/save", headers=self.h2).json()
        self.assertEqual(saved["songs"][0]["filename"], "")
        self.assertFalse(self.api.db.owns_download(self.two["id"], self.file.name))

    def test_upstream_proxy_only_accepts_google_cdn_and_rejects_redirects(self):
        from source_security import streaming_target
        for value in ("http://127.0.0.1/audio", "https://googlevideo.com.evil.test/audio", "https://evil.test/audio", "https://user@r1.googlevideo.com/audio"):
            with self.assertRaises(ValueError):
                streaming_target(value)
        self.assertEqual(streaming_target("https://r1.googlevideo.com/audio"), "https://r1.googlevideo.com/audio")

    def test_playlist_artwork_rejects_capabilities_and_public_views_hide_private_refs(self):
        playlist = self.api.db.create_playlist(self.one['id'], 'Private artwork')
        add_path = '/playlists/' + playlist['id'] + '/songs'
        song = {'id': 'artwork-track', 'title': 'Shared title', 'filename': self.file.name,
                'url': self.source, 'thumbnail': '/downloads/' + self.file.name + '/artwork'}
        signed = self.signed()
        rejected = self.client.post(add_path, headers=self.h1, json={**song, 'thumbnail': signed})
        self.assertEqual(rejected.status_code, 400, rejected.text)
        self.assertEqual(self.api.db.get_playlist(self.one['id'], playlist['id'])['songs'], [])
        self.assertEqual(self.client.post(add_path, headers=self.h1, json=song).status_code, 200)
        self.api.db.set_playlist_public(self.one['id'], playlist['id'], True)
        public_path = f'/users/{self.one["id"]}/playlists/{playlist["id"]}'
        self.assertEqual(self.client.get(public_path, headers=self.h1).json()['songs'][0]['thumbnail'], song['thumbnail'])
        for data in (self.client.get(public_path, headers=self.h2).json(),
                     self.client.get(f'/users/{self.one["id"]}/playlists', headers=self.h2).json()[playlist['id']],
                     self.client.post(public_path + '/save', headers=self.h2).json()):
            self.assertEqual(data['songs'][0]['thumbnail'], '')
            self.assertEqual(data['songs'][0]['filename'], '')
            self.assertEqual(data['songs'][0]['file_path'], '')
            self.assertEqual(data['songs'][0]['url'], self.source)
        # Old stored capability URLs must also disappear from public reads/copies.
        self.api.db.add_song_to_playlist(self.one['id'], playlist['id'],
            {'id': 'legacy-token', 'title': 'Legacy artwork', 'filename': '', 'thumbnail': signed})
        for response in (self.client.get(public_path, headers=self.h2),
                         self.client.post(public_path + '/save', headers=self.h2)):
            self.assertEqual(response.status_code, 200, response.text)
            self.assertNotIn('media_token', response.text)

    def test_csv_uploads_conversion_and_progress_are_scoped(self):
        response = self.client.post("/csv/upload", headers=self.h1, files={"file": ("private.csv", b"Track Name,Artist Name(s)\nOne,Artist", "text/csv")})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.post("/csv/convert/private.csv", headers=self.h2, json={}).status_code, 404)
        self.api.csv_progress[(self.one["id"], "private.csv")] = {"status": "completed"}
        self.assertEqual(self.client.get("/csv/progress/private.csv", headers=self.h1).status_code, 200)
        self.assertEqual(self.client.get("/csv/progress/private.csv", headers=self.h2).status_code, 404)
        self.api.download_progress["private-job"] = {"user_id": self.one["id"], "status": "completed"}
        self.assertEqual(self.client.get("/downloads/progress/private-job", headers=self.h2).status_code, 404)
        result = {"tracks": [{"title": "bad", "url": "http://127.0.0.1/private"}], "success_count": 1, "not_found": [], "total": 1}
        with patch.object(self.api.download_service, "convert_csv_to_playlist", return_value=result):
            self.assertEqual(self.client.post("/csv/convert/private.csv", headers=self.h1, json={}).status_code, 400)

    def test_invalid_sources_rejected_at_all_network_entrypoints(self):
        values = ("file:///secret", "http://127.0.0.1/a", "https://youtube.com.evil.test/watch?v=testFixture", "https://youtube.com@127.0.0.1/watch?v=testFixture", "https://www.youtube.com:9999/watch?v=testFixture", "https://www.youtube.com/playlist?list=123", "--exec=calc", "https://youtu.be/short")
        with patch.object(self.api.download_service, "download_audio") as download, patch.object(self.api.download_service, "get_streaming_url") as stream, patch.object(self.api.metadata_service, "resolve") as metadata:
            for value in values:
                self.assertEqual(self.client.post("/download", headers=self.h1, json={"url": value, "title": "bad"}).status_code, 400)
                self.assertEqual(self.client.get("/stream/" + quote(value, safe=""), headers=self.h1).status_code, 400)
                self.assertEqual(self.client.get("/clean-metadata", headers=self.h1, params={"title": "bad", "video_url": value}).status_code, 400)
            download.assert_not_called()
            stream.assert_not_called()
            metadata.assert_not_called()

    def test_valid_youtube_variants_share_canonical_identity(self):
        from source_security import youtube_url, search_query
        for source in ("https://youtu.be/testFixture?t=5", "https://music.youtube.com/watch?v=testFixture&list=abc", "http://m.youtube.com/shorts/testFixture", "https://www.youtube.com/embed/testFixture"):
            self.assertEqual(youtube_url(source), self.source)
        self.assertEqual(search_query("Song title: a remix"), "Song title: a remix")
        with patch.object(self.api.download_service, "search_youtube") as search:
            response = self.client.post("/search", headers=self.h1, json={"query": "http://127.0.0.1/secrets"})
        self.assertEqual(response.status_code, 400)
        search.assert_not_called()

    def test_stream_signed_scope_and_head(self):
        signed = self.signed("/stream/" + quote(self.source, safe=""))
        def fill(source, output, max_bytes):
            Path(output).write_bytes(b"streamed")
        with patch.object(self.api.download_service, "get_streaming_url", side_effect=RuntimeError("fixture")), patch.object(self.api.download_service, "download_for_streaming", side_effect=fill):
            self.assertEqual(self.client.get(signed).content, b"streamed")
            response = self.client.head(signed)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b"")

    def test_legacy_migration_is_once_and_grants_only_known_playlist_files(self):
        from database import Database
        legacy = Database.__new__(Database)
        legacy.db_url = str(self.root / "migration.db")
        legacy.init_db()
        first = legacy.create_user("a", "unused")
        second = legacy.create_user("b", "unused")
        playlist = legacy.create_playlist(first["id"], "old")
        legacy.add_song_to_playlist(first["id"], playlist["id"], {"id": "old", "title": "Old", "filename": "old.mp3"})
        legacy.migrate_download_ownership(["old.mp3", "unreferenced.mp3"])
        self.assertTrue(legacy.owns_download(first["id"], "old.mp3"))
        self.assertFalse(legacy.owns_download(second["id"], "old.mp3"))
        self.assertFalse(legacy.owns_download(first["id"], "unreferenced.mp3"))
        forged = legacy.create_playlist(second["id"], "later")
        legacy.add_song_to_playlist(second["id"], forged["id"], {"id": "later", "title": "Later", "filename": "old.mp3"})
        legacy.migrate_download_ownership(["old.mp3"])
        self.assertFalse(legacy.owns_download(second["id"], "old.mp3"))

    def test_cache_ttl_byte_limit_oversize_and_same_source_coordination(self):
        from stream_cache import StreamCache
        cache = StreamCache(self.root / "cache-test", ttl_seconds=5, max_bytes=12, max_file_bytes=6)
        calls = []
        def fill(source, output, max_bytes):
            calls.append(source)
            time.sleep(0.02)
            Path(output).write_bytes(b"123456")
        with ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda _: cache.acquire("same", fill), range(4)))
        self.assertEqual(calls, ["same"])
        for path in paths:
            cache.release(path)
        p2 = cache.acquire("second", fill)
        cache.release(p2)
        p3 = cache.acquire("third", fill)
        self.assertFalse(paths[0].exists())
        self.assertLessEqual(sum(p.stat().st_size for p in cache.directory.glob("*.m4a")), 12)
        cache.release(p3)
        os.utime(p2, (time.time() - 20, time.time() - 20))
        p4 = cache.acquire("fourth", fill)
        self.assertFalse(p2.exists())
        cache.release(p4)
        def oversize(source, output, max_bytes):
            Path(output).write_bytes(b"too-many-bytes")
        with self.assertRaises(RuntimeError):
            cache.acquire("huge", oversize)
        self.assertFalse((cache.directory / (hashlib.sha256(b"huge").hexdigest() + ".m4a")).exists())

    def test_single_user_legacy_import_does_not_grant_later_files_or_accounts(self):
        from database import Database
        legacy = Database.__new__(Database)
        legacy.db_url = str(self.root / 'single-user-migration.db')
        legacy.init_db()
        original = legacy.create_user('original', 'unused')
        legacy.migrate_download_ownership(['unreferenced.mp3', 'folder/old.m4a'])
        self.assertEqual(legacy.owned_downloads(original['id']), {'unreferenced.mp3', 'folder/old.m4a'})
        later = legacy.create_user('later', 'unused')
        legacy.init_db()
        legacy.migrate_download_ownership(['unreferenced.mp3', 'folder/old.m4a', 'new.mp3'])
        self.assertEqual(legacy.owned_downloads(later['id']), set())
        self.assertFalse(legacy.owns_download(original['id'], 'new.mp3'))

    def test_additive_schema_upgrade_preserves_old_history_and_playlist_ids(self):
        from database import Database
        legacy = Database.__new__(Database)
        legacy.db_url = str(self.root / 'pre-feature-schema.db')
        with closing(sqlite3.connect(legacy.db_url)) as conn, conn:
            conn.executescript('''
                CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL,
                    password_hash TEXT NOT NULL, is_active INTEGER DEFAULT 1, created_at DATETIME);
                INSERT INTO users VALUES (7, 'old-user', 'unused', 1, '2026-10-01 00:00:00');
                CREATE TABLE history (id INTEGER PRIMARY KEY, user_id INTEGER, song_title TEXT NOT NULL,
                    artist TEXT NOT NULL, timestamp DATETIME, duration_played REAL, spotify_id TEXT);
                INSERT INTO history VALUES (12, 7, 'Legacy full listen', 'Legacy Artist', '2026-10-01 12:00:00', 60, 'original-id');
                INSERT INTO history VALUES (13, 7, 'Legacy click', 'Click Artist', '2026-10-01 13:00:00', 0, NULL);
                CREATE TABLE playlists (id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, name TEXT NOT NULL,
                    cover_image TEXT, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);
                INSERT INTO playlists VALUES ('old-playlist', 7, 'Preserved playlist', NULL, '2026-10-01', '2026-10-01');
                CREATE TABLE playlist_songs (id TEXT PRIMARY KEY, playlist_id TEXT NOT NULL, title TEXT NOT NULL,
                    artist TEXT, album TEXT, filename TEXT, file_path TEXT, url TEXT, thumbnail TEXT,
                    duration REAL, created_at DATETIME NOT NULL);
                INSERT INTO playlist_songs VALUES ('folder/old%20.mp3', 'old-playlist', 'Legacy song', 'Legacy Artist',
                    '', 'folder/old%20.mp3', '', 'https://youtu.be/testFixture', '', 60, '2026-10-01');
            ''')
        legacy.init_db()
        legacy.migrate_download_ownership(['folder/old%20.mp3'])
        legacy.save_library_item(7, 'tracks', 'saved', {'id': 'saved', 'title': 'Retained like', 'filename': 'folder/old%20.mp3'})
        legacy.init_db()
        self.assertEqual(legacy.get_playlist(7, 'old-playlist')['songs'][0]['id'], 'folder/old%20.mp3')
        self.assertEqual(len(legacy.get_recent_history(7)), 2)
        self.assertEqual(legacy.get_saved_library(7)['tracks'][0]['title'], 'Retained like')
        self.assertTrue(legacy.owns_download(7, 'folder/old%20.mp3'))
        summary = legacy.get_history_summary(7, '2026-10-01T00:00:00+00:00', '2026-10-02T00:00:00+00:00')
        self.assertEqual(summary, {'plays': 1, 'total_duration_played': 60, 'unique_artists': 1})
        report = self.api.validate_report({'event_id': 'migrated-listen', 'sequence': 1,
            'song_title': 'New listen', 'artist': 'New Artist', 'duration_seconds': 60,
            'listened_seconds': 60, 'end_reason': 'completed'})
        legacy.upsert_listening(7, report)
        legacy.upsert_listening(7, report)
        self.assertEqual(len(legacy.get_recent_history(7)), 3)
        legacy.remove_song_from_playlist(7, 'old-playlist', 'folder/old%20.mp3')
        self.assertEqual(legacy.get_playlist(7, 'old-playlist')['songs'], [])

    def test_cache_never_evicts_active_responses_and_recovers_failed_fills(self):
        from stream_cache import StreamCache
        cache = StreamCache(self.root / "cache-active", max_bytes=5, max_file_bytes=5)
        def fill(source, output, max_bytes):
            Path(output).write_bytes(b"12345")
        active = cache.acquire("active", fill)
        with self.assertRaises(RuntimeError):
            cache.acquire("other", fill)
        self.assertTrue(active.exists())
        cache.release(active)
        def broken(source, output, max_bytes):
            Path(output + ".tmp").write_bytes(b"partial")
            raise RuntimeError("interrupted")
        with self.assertRaises(RuntimeError):
            cache.acquire("broken", broken)
        self.assertFalse(list(cache.directory.glob("*.tmp")))
        fixed = cache.acquire("broken", fill)
        self.assertEqual(fixed.read_bytes(), b"12345")
        cache.release(fixed)

    def test_stream_remux_uses_actual_final_container_path(self):
        output = str(self.root / "remuxed.m4a")
        def remux(args, source, prefix, max_bytes):
            self.assertEqual(args[args.index('--output') + 1], output + '.work.%(ext)s')
            Path(prefix + '.m4a').write_bytes(b'converted-aac')
        service = self.api.download_service
        with patch.object(service, 'yt_dlp_exe', 'fixture-yt-dlp'), patch.object(service, '_bounded_stream_process', side_effect=remux):
            self.assertEqual(service.download_for_streaming(self.source, output, 100), output)
        self.assertEqual(Path(output).read_bytes(), b'converted-aac')
        self.assertFalse(Path(output + '.work.m4a').exists())

    def test_stream_process_kills_only_own_tree_on_temp_byte_limit_or_timeout(self):
        import download_service
        service = self.api.download_service
        prefix = str(self.root / 'bounded.work')
        Path(prefix + '.m4a').write_bytes(b'123456')
        process = Mock(pid=12345)
        process.poll.return_value = None
        process.wait.return_value = 1
        with patch.object(service, '_yt_cmd', return_value=['fixture']), patch.object(download_service.subprocess, 'Popen', return_value=process), patch.object(download_service.subprocess, 'run') as kill:
            with self.assertRaisesRegex(RuntimeError, 'cache file limit'):
                service._bounded_stream_process([], self.source, prefix, 5)
            if download_service.platform.system() == 'Windows':
                self.assertEqual(kill.call_args.args[0], ['taskkill', '/PID', '12345', '/T', '/F'])
        with patch.object(service, '_yt_cmd', return_value=['fixture']), patch.object(download_service.subprocess, 'Popen', return_value=process), patch.object(download_service.subprocess, 'run'), patch.object(download_service.time, 'monotonic', side_effect=[0, 181]):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                service._bounded_stream_process([], self.source, prefix, 100)

    def test_ytdlp_command_delimits_inputs_and_restricts_extractors(self):
        service = self.api.download_service
        with patch.object(service, 'yt_dlp_exe', 'fixture-yt-dlp'):
            command = service._yt_cmd(['--dump-single-json'], self.source)
            self.assertEqual(command[-2:], ['--', self.source])
            self.assertIn('--use-extractors', command)
            with self.assertRaises(ValueError):
                service._yt_cmd([], 'http://127.0.0.1/secret')


if __name__ == "__main__":
    unittest.main()
