"""Deterministic preference ranking independent of catalogue availability."""
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import math
import re
from urllib.parse import urlsplit
from listening_history import normalized, track_key, early_skip
from saved_library import _reject_credentials, clean_thumbnail
from source_security import youtube_url


class ListeningPreferences:
    def __init__(self, history, library, now=None):
        self.tracks = defaultdict(float)
        self.artists = defaultdict(float)
        self.track_metadata = {}
        self.artist_metadata = {}
        self.liked = set()
        now = now or datetime.now(timezone.utc)
        for row in history:
            key = track_key(row['song_title'], row['artist'])
            artist = key[1]
            listened = max(0, float(row.get('duration_played') or 0))
            duration = max(0, float(row.get('duration_seconds') or 0))
            is_qualified = bool(row.get('qualified')) if row.get('event_id') else listened > 0
            try:
                played_at = datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00'))
                if played_at.tzinfo is None:
                    played_at = played_at.replace(tzinfo=timezone.utc)
                age = max(0, (now - played_at).total_seconds() / 86400)
            except (ValueError, TypeError):
                age = 90
            decay = 0.5 ** (age / 30)
            if is_qualified:
                ratio = min(1, listened / duration) if duration else 0
                score = 1 + min(2, listened / 180) + 0.75 * ratio
                if row.get('end_reason') == 'completed' and ratio >= 0.8:
                    score += 0.5
                self.tracks[key] += decay * score
                self.artists[artist] += decay * score * 0.5
                self.track_metadata.setdefault(key, {'id': row.get('spotify_id') or 'history_' + hashlib.sha256(repr(key).encode()).hexdigest()[:24],
                    'spotify_id': row.get('spotify_id') or '', 'title': row['song_title'], 'artist': row['artist'],
                    'url': row.get('source_url') or '', 'duration': duration})
                self.artist_metadata.setdefault(artist, {'name': row['artist']})
            elif early_skip(row):
                self.tracks[key] -= 3 * decay
                self.artists[artist] -= 0.5 * decay
        for track in library.get('tracks', []):
            key = track_key(track.get('title'), track.get('artist'))
            self.liked.add(key)
            self.tracks[key] += 4
            self.artists[key[1]] += 1
            self.track_metadata[key] = track
            self.artist_metadata.setdefault(key[1], {'name': track.get('artist') or 'Unknown'})
        for album in library.get('albums', []):
            artist = normalized(album.get('artist'))
            self.artists[artist] += 1
            self.artist_metadata.setdefault(artist, {'name': album.get('artist') or 'Unknown'})
        for artist in library.get('artists', []):
            key = normalized(artist.get('name'))
            self.artists[key] += 3
            self.artist_metadata[key] = dict(artist)

    def top_tracks(self, limit=3):
        return [self.track_metadata[key] for key in sorted(self.tracks, key=lambda key: (-self.tracks[key], key))
                if self.tracks[key] > 0 and key in self.track_metadata][:limit]

    def top_artists(self, limit=5):
        return [self.artist_metadata[key] for key in sorted(self.artists, key=lambda key: (-self.artists[key], key))
                if self.artists[key] > 0 and key in self.artist_metadata and key not in ('', 'unknown')][:limit]

    def score(self, track):
        key = track_key(track.get('title'), track.get('artist'))
        return self.tracks[key] + self.artists[key[1]]

    def rank(self, candidates, limit=30):
        merged = {}
        for candidate in candidates:
            key = track_key(candidate.get('title'), candidate.get('artist'))
            if not key[0]:
                continue
            if key not in merged:
                merged[key] = dict(candidate)
            else:
                previous = merged[key]
                for field, value in candidate.items():
                    if value and (field == 'filename' or not previous.get(field)):
                        previous[field] = value
        return sorted(merged.values(), key=lambda item: (-self.score(item), normalized(item.get('title')), normalized(item.get('artist'))))[:limit]


def safe_track(candidate, owns_filename, owns_playlist):
    """Return only supported public metadata and explicitly owned local refs."""
    if not isinstance(candidate, dict):
        return None
    item = {}
    for key, limit in (('id', 512), ('title', 300), ('artist', 300), ('album', 300), ('filename', 1024), ('url', 2048), ('thumbnail', 2048)):
        value = candidate.get(key) or ''
        if not isinstance(value, str) or any(ord(c) < 32 for c in value):
            value = ''
        item[key] = value[:limit].strip()
    if not item['title']:
        return None
    try:
        _reject_credentials(item['id'])
    except Exception:
        item['id'] = ''
    if not item['id']:
        item['id'] = 'local_' + hashlib.sha256(repr(track_key(item['title'], item['artist'])).encode()).hexdigest()[:24]
    if not item['filename'] or not owns_filename(item['filename']):
        item['filename'] = ''
    if item['url']:
        try:
            _reject_credentials(item['url'])
            parsed = urlsplit(item['url'])
            if parsed.scheme == 'https' and parsed.netloc == 'open.spotify.com' and re.fullmatch(r'/track/[A-Za-z0-9]+', parsed.path):
                item['url'] = 'https://open.spotify.com' + parsed.path
            else:
                item['url'] = youtube_url(item['url'])
        except Exception:
            item['url'] = ''
    try:
        item['thumbnail'] = clean_thumbnail(item['thumbnail'], owns_filename, owns_playlist)
    except Exception:
        item['thumbnail'] = ''
    duration = candidate.get('duration') or 0
    item['duration'] = float(duration) if not isinstance(duration, bool) and isinstance(duration, (int, float)) and math.isfinite(duration) and 0 <= duration <= 86400 else 0
    return item


def available(call, *args, **kwargs):
    """Provider failure is an empty candidate set, never a broken library."""
    try:
        return call(*args, **kwargs) or []
    except Exception:
        return []
