"""Synthetic catalogue and external-service substitutes for browser QA.

Authentication, authorization, database operations, and media delivery remain
genuine. Every fixture MP3 and M4A is generated locally using ffmpeg.
"""

import copy
import shutil
import sqlite3
import struct
import subprocess
import types
import zlib
from contextlib import ExitStack, closing, contextmanager
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from unittest.mock import patch

from fastapi import HTTPException, Request
from mutagen.id3 import APIC, ID3
from mutagen.mp4 import MP4, MP4Cover

from isolated_backend import isolated_backend


TRACKS = [
    {"id": "demo0000001", "title": "Night Drive", "artist": "Demo Artist", "album": "Evening Signals", "artist_id": "demo-artist", "album_id": "evening-signals", "duration": 12.0, "frequency": 220},
    {"id": "demo0000002", "title": "City Lights", "artist": "Demo Artist", "album": "Evening Signals", "artist_id": "demo-artist", "album_id": "evening-signals", "duration": 14.0, "frequency": 277},
    {"id": "demo0000003", "title": "First Light", "artist": "Studio Fixture", "album": "Focus Studies", "artist_id": "studio-fixture", "album_id": "focus-studies", "duration": 16.0, "frequency": 330},
    {"id": "demo0000004", "title": "Quiet Hours", "artist": "Studio Fixture", "album": "Focus Studies", "artist_id": "studio-fixture", "album_id": "focus-studies", "duration": 18.0, "frequency": 392},
    {"id": "demo0000005", "title": "Open Road", "artist": "Sample Band", "album": "Weekend Motion", "artist_id": "sample-band", "album_id": "weekend-motion", "duration": 20.0, "frequency": 440},
]
PRIVATE_TRACK = {"id": "other000001", "title": "Other Private Tone", "artist": "Private Fixture", "album": "Private Collection", "artist_id": "private-fixture", "album_id": "private-collection", "duration": 10.0, "frequency": 523}


def catalogue_track(track):
    return {**{key: value for key, value in track.items() if key != "frequency"},
            "name": track["title"], "filename": f"fixture/{track['id']}.mp3",
            "url": f"https://www.youtube.com/watch?v={track['id']}",
            "uploader": track["artist"], "thumbnail": "", "preview_url": None}


def catalogue_albums():
    albums = {}
    for track in TRACKS:
        entry = albums.setdefault(track["album_id"], {
            "id": track["album_id"], "name": track["album"], "artist": track["artist"],
            "artist_id": track["artist_id"], "thumbnail": "", "release_date": "2026-01-01",
            "type": "album", "total_tracks": 0})
        entry["total_tracks"] += 1
    return list(albums.values())


def catalogue_artists():
    return [{"id": album["artist_id"], "name": album["artist"], "thumbnail": "",
             "genres": ["electronic"], "followers": 1234} for album in catalogue_albums()]


def find_track(url):
    video_id = parse_qs(urlparse(url).query).get("v", [""])[0]
    if urlparse(url).hostname == "youtu.be":
        video_id = urlparse(url).path.strip("/")
    return next((track for track in TRACKS if track["id"] == video_id), None)


def generate_audio(ffmpeg, track, mp3_path, m4a_path):
    """Generate audio without acquiring or converting any user's media."""
    mp3_path.parent.mkdir(parents=True, exist_ok=True)
    common = [str(ffmpeg), "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
              "-i", f"sine=frequency={track['frequency']}:duration={track['duration']}:sample_rate=44100",
              "-af", "volume=0.08", "-metadata", f"title={track['title']}",
              "-metadata", f"artist={track['artist']}", "-metadata", f"album={track['album']}"]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    for codec, output in ((["-c:a", "libmp3lame", "-b:a", "96k"], mp3_path),
                          (["-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart"], m4a_path)):
        subprocess.run(common + codec + [str(output)], check=True, timeout=30,
                       capture_output=True, creationflags=flags)
    # Tiny procedural artwork exercises genuine private image routes too.
    # It uses no remote images or user content and has no extra dependencies.
    def png_chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    color = (track["frequency"] % 200 + 40, 80, 190)
    pixels = b"".join(b"\x00" + bytes(color) * 32 for _ in range(32))
    artwork = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack("!2I5B", 32, 32, 8, 2, 0, 0, 0))
               + png_chunk(b"IDAT", zlib.compress(pixels)) + png_chunk(b"IEND", b""))
    mp3 = ID3(mp3_path)
    mp3.add(APIC(encoding=3, mime="image/png", type=3, desc="Synthetic fixture", data=artwork))
    mp3.save(mp3_path)
    m4a = MP4(m4a_path)
    m4a["covr"] = [MP4Cover(artwork, imageformat=MP4Cover.FORMAT_PNG)]
    m4a.save(m4a_path)


class DemoFixture:
    def __init__(self, api, root, ffmpeg):
        self.api = api
        self.root = Path(root)
        self.downloads = self.root / "downloads"
        self.sources = self.root / "synthetic-sources"
        self.sources.mkdir()
        self.shutdown = lambda: None
        self.users = {}
        self.playlists = {}
        self.calls = []
        self.provider_available = True
        for track in TRACKS + [PRIVATE_TRACK]:
            generate_audio(ffmpeg, track, self.sources / f"{track['id']}.mp3",
                           self.sources / f"{track['id']}.m4a")
        self.seed()
        self.snapshot = self.root / "seed.db"
        with closing(sqlite3.connect(self.api.db.db_url)) as source, closing(sqlite3.connect(self.snapshot)) as destination:
            source.backup(destination)

    def seed(self):
        from auth_utils import hash_password

        for username, password in (("demo", "demo-only"), ("other", "other-only")):
            user = self.api.db.create_user(username, hash_password(password))
            self.users[username] = user
            self.api.db.update_user_profile(user["id"], username, "Isolated browser regression account")
        self.restore_audio()
        for username, playlist_name, tracks in (
                ("demo", "Evening rotation", TRACKS[:2]),
                ("demo", "Deep focus", TRACKS[2:4]),
                ("demo", "Weekend favourites", TRACKS[4:]),
                ("other", "Private collection", [PRIVATE_TRACK])):
            user_id = self.users[username]["id"]
            playlist = self.api.db.create_playlist(user_id, playlist_name)
            self.playlists[playlist_name] = playlist["id"]
            for track in tracks:
                data = catalogue_track(track)
                self.api.db.add_song_to_playlist(user_id, playlist["id"], data)
                self.api.db.claim_download(user_id, data["filename"])
                for album in ("", track["album"]):
                    key = self.api._album_cover_cache_key(track["title"], track["artist"], album)
                    self.api.db.set_album_cover_cache(key, None, 0)

    def restore_audio(self):
        destination = self.downloads / "fixture"
        destination.mkdir(parents=True, exist_ok=True)
        for track in TRACKS + [PRIVATE_TRACK]:
            shutil.copyfile(self.sources / f"{track['id']}.mp3", destination / f"{track['id']}.mp3")

    def reset(self):
        with closing(sqlite3.connect(self.snapshot)) as source, closing(sqlite3.connect(self.api.db.db_url)) as destination:
            source.backup(destination)
        self.restore_audio()
        self.calls.clear()
        self.provider_available = True

    def search(self, query, duration_min=0, duration_max=600, **kwargs):
        words = query.casefold().split()
        return [catalogue_track(track) for track in TRACKS
                if all(word in f"{track['title']} {track['artist']} {track['album']}".casefold() for word in words)
                and duration_min <= track["duration"] <= duration_max]

    def catalog_search(self, q, **kwargs):
        """Spotify-shaped search payload; contains only the synthetic public catalogue."""
        words = q.casefold().split()
        def matches(*values):
            text = ' '.join(str(value) for value in values).casefold()
            return all(word in text for word in words)
        tracks = []
        for track in TRACKS:
            if matches(track['title'], track['artist'], track['album']):
                tracks.append({'id': 'catalog' + track['id'], 'name': track['title'],
                               'artists': [{'id': track['artist_id'], 'name': track['artist']}],
                               'album': {'id': track['album_id'], 'name': track['album'], 'images': []},
                               'duration_ms': track['duration'] * 1000,
                               'external_urls': {'spotify': 'https://open.spotify.com/track/catalog' + track['id']}})
        artists = [{'id': artist['id'], 'name': artist['name'], 'images': [], 'genres': artist['genres']}
                   for artist in catalogue_artists() if matches(artist['name'])]
        albums = [{**album, 'artists': [{'id': album['artist_id'], 'name': album['artist']}],
                   'images': [], 'album_type': album['type']} for album in catalogue_albums()
                  if matches(album['name'], album['artist'])]
        playlists = [{'id': 'demo-catalog-playlist', 'name': 'Evening discovery', 'images': [],
                      'description': 'Synthetic public playlist', 'owner': {'display_name': 'Demo curator'}}]
        return {'tracks': {'items': tracks}, 'artists': {'items': artists}, 'albums': {'items': albums},
                'playlists': {'items': [p for p in playlists if matches(p['name'])]}}

    def download(self, url, title="", artist="", album="", output_format="m4a", **kwargs):
        track = find_track(url)
        if not track:
            raise ValueError("This isolated fixture only contains synthetic catalogue tracks")
        filename = f"fixture/{track['id']}.{output_format}"
        path = self.downloads / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.sources / f"{track['id']}.{output_format}", path)
        return {"success": True, "filename": filename, "file_path": str(path),
                "title": track["title"], "artist": track["artist"], "album": track["album"]}

    def stream(self, url, output_path, **kwargs):
        track = find_track(url)
        if not track:
            raise ValueError("This isolated fixture only streams synthetic catalogue tracks")
        shutil.copyfile(self.sources / f"{track['id']}.m4a", output_path)
        return str(output_path)

    def recommendations(self, **kwargs):
        self.calls.append(copy.deepcopy(kwargs))
        return [catalogue_track(track) for track in TRACKS][:kwargs.get("limit", 20)]

    def provider(self, replacement):
        def guarded(*args, **kwargs):
            if not self.provider_available:
                raise RuntimeError('Synthetic catalogue provider is unavailable')
            return replacement(*args, **kwargs)
        return guarded

    def metadata(self, title, uploader="", **kwargs):
        track = next((item for item in TRACKS if item["title"].casefold() == title.casefold()), None)
        return {"title": track["title"] if track else title, "artist": track["artist"] if track else uploader,
                "album": track["album"] if track else "", "source": "synthetic-fixture", "thumbnail": ""}

    def install_controls(self):
        def require_demo(request):
            user = self.api._require_current_user(request)
            if user["id"] != self.users["demo"]["id"]:
                raise HTTPException(status_code=403, detail="Fixture controls require the demo account")

        @self.api.app.get("/__test/state", include_in_schema=False)
        def state(request: Request):
            require_demo(request)
            return {"fixture": True, "playlists": self.playlists, "tracks": [catalogue_track(t) for t in TRACKS],
                    "users": {name: user["id"] for name, user in self.users.items()},
                    "recommendation_calls": self.calls,
                    "provider_available": self.provider_available,
                    "history": self.api.db.get_recent_history(self.users["demo"]["id"], limit=100)}

        @self.api.app.post("/__test/reset", include_in_schema=False)
        def reset(request: Request):
            require_demo(request)
            self.reset()
            return {"reset": True}

        @self.api.app.post("/__test/provider-state", include_in_schema=False)
        def provider_state(payload: dict, request: Request):
            require_demo(request)
            if set(payload) != {'available'} or not isinstance(payload.get('available'), bool):
                raise HTTPException(status_code=400, detail='available must be a boolean')
            self.provider_available = payload['available']
            return {'available': self.provider_available}

        @self.api.app.post("/__test/shutdown", include_in_schema=False)
        def shutdown(request: Request):
            require_demo(request)
            self.shutdown()
            return {"shutdown": True}


@contextmanager
def browser_fixture(ffmpeg=None):
    executable = ffmpeg or shutil.which("ffmpeg")
    if not executable or not Path(executable).is_file():
        raise RuntimeError("Browser fixtures require local ffmpeg; provide --ffmpeg PATH")
    with isolated_backend() as (api, root), ExitStack() as stack:
        fixture = DemoFixture(api, root, executable)
        provider = api.spotify_service
        stack.enter_context(patch.object(provider, 'sp', types.SimpleNamespace(search=fixture.provider(fixture.catalog_search))))
        substitutions = {
            "get_new_releases": lambda **kwargs: catalogue_albums(),
            "get_album": lambda album_id: next((a for a in catalogue_albums() if a["id"] == album_id), None),
            "get_album_tracks": lambda album_id: [catalogue_track(t) for t in TRACKS if t["album_id"] == album_id],
            "get_artist": lambda artist_id: next((a for a in catalogue_artists() if a["id"] == artist_id), None),
            "get_artist_top_tracks": lambda artist_id, **kwargs: [catalogue_track(t) for t in TRACKS if t["artist_id"] == artist_id],
            "get_artist_albums": lambda artist_id, **kwargs: [a for a in catalogue_albums() if a["artist_id"] == artist_id],
            "get_artist_new_releases": lambda artist_id, **kwargs: [a for a in catalogue_albums() if a["artist_id"] == artist_id],
            "get_related_artists": lambda artist_id, **kwargs: [a for a in catalogue_artists() if a["id"] != artist_id],
            "get_recommended_artists": lambda **kwargs: catalogue_artists(),
            "get_recommendations": fixture.recommendations,
            "get_genre_recommendations": lambda genre, **kwargs: [catalogue_track(t) for t in TRACKS],
            "get_available_genre_seeds": lambda: ["electronic", "pop", "rock"],
            "get_artist_genres": lambda artist_id: ["electronic"],
            "get_curated_playlists": lambda *args, **kwargs: [],
            "get_genre_playlists": lambda *args, **kwargs: [],
            "get_mood_playlists": lambda *args, **kwargs: [],
            "get_playlist_tracks": lambda *args, **kwargs: [catalogue_track(t) for t in TRACKS],
            "get_moods": lambda: ["Focus", "Chill"],
            "search_track": lambda title, artist: next((catalogue_track(t) for t in TRACKS if t["title"].casefold() == title.casefold()), None),
        }
        for name, replacement in substitutions.items():
            stack.enter_context(patch.object(provider, name, fixture.provider(replacement)))
        stack.enter_context(patch.object(api.download_service, "search_youtube", fixture.search))
        stack.enter_context(patch.object(api.download_service, "download_audio", fixture.download))
        stack.enter_context(patch.object(api.download_service, "download_for_streaming", fixture.stream))
        stack.enter_context(patch.object(api.download_service, "get_streaming_url", side_effect=RuntimeError("Fixture uses cached local AAC")))
        stack.enter_context(patch.object(api.metadata_service, "resolve", fixture.metadata))
        stack.enter_context(patch.object(api.lyrics_service, "get_lyrics", return_value={
            "trackName": "Synthetic fixture", "artistName": "Demo Artist", "instrumental": True,
            "plainLyrics": None, "syncedLyrics": None, "duration": 12}))
        fixture.install_controls()
        yield api, fixture
