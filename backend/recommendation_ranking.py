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
from unified_search import recording_type


def recommendation_identity(track):
    """Collapse the same song across sources without mixing marked recordings."""
    kind = track.get('recording_type') or recording_type(track.get('title'), track.get('album'))
    if kind in ('studio', 'original', 'unspecified'):
        kind = 'original'
    return (*track_key(track.get('title'), track.get('artist')), kind)


def _catalog_id(track):
    value = track.get('spotify_id')
    if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        return value
    return ''


def same_recommendation_recording(left, right):
    """Catalog IDs survive display-credit changes; known artist conflicts do not."""
    if left.get('artist_id') and right.get('artist_id') and left['artist_id'] != right['artist_id']:
        return False
    left_id, right_id = _catalog_id(left), _catalog_id(right)
    if left_id and right_id:
        return left_id == right_id
    return recommendation_identity(left) == recommendation_identity(right)


def _artwork_quality(track):
    thumbnail = track.get('thumbnail') or ''
    host = (urlsplit(thumbnail).hostname or '').lower()
    if host in ('img.youtube.com', 'i.ytimg.com', 'i1.ytimg.com', 'i2.ytimg.com', 'i3.ytimg.com', 'i4.ytimg.com'):
        return 0
    if not thumbnail:
        return -1
    if track.get('spotify_id') or host == 'i.scdn.co' or host.endswith('.mzstatic.com'):
        return 3
    return 2


def merge_tracks(candidates):
    """Prefer album artwork while retaining the listener's playable source/file."""
    candidates = [candidate for candidate in candidates if isinstance(candidate, dict) and
                  recommendation_identity(candidate)[0]]
    artists_by_metadata, artists_by_catalog = defaultdict(set), defaultdict(set)
    for candidate in candidates:
        if candidate.get('artist_id'):
            artists_by_metadata[recommendation_identity(candidate)].add(candidate['artist_id'])
            if _catalog_id(candidate):
                artists_by_catalog[_catalog_id(candidate)].add(candidate['artist_id'])

    def artist_scope(candidate):
        if candidate.get('artist_id'):
            return candidate['artist_id']
        known = artists_by_catalog[_catalog_id(candidate)] if _catalog_id(candidate) else set()
        if len(known) != 1:
            known = artists_by_metadata[recommendation_identity(candidate)]
        return next(iter(known)) if len(known) == 1 else ''

    catalogs_by_metadata = defaultdict(set)
    for candidate in candidates:
        if _catalog_id(candidate):
            catalogs_by_metadata[(recommendation_identity(candidate), artist_scope(candidate))].add(_catalog_id(candidate))
    merged = {}
    for candidate in candidates:
        metadata = recommendation_identity(candidate)
        artist = artist_scope(candidate)
        catalog_id = _catalog_id(candidate)
        aliases = catalogs_by_metadata[(metadata, artist)]
        if not catalog_id and len(aliases) == 1:
            catalog_id = next(iter(aliases))
        # Unknown-source metadata joins a catalog identity only when that
        # metadata has one unambiguous artist and recording. Same-name artists
        # and conflicting known recordings retain separate buckets.
        key = ('spotify', catalog_id, artist) if catalog_id else ('metadata', metadata, artist)
        if key not in merged:
            merged[key] = dict(candidate)
            continue
        previous = merged[key]
        # Do not replace one edition's artwork with a different album's cover.
        same_album = (not previous.get('album') or not candidate.get('album') or
                      normalized(previous['album']) == normalized(candidate['album']))
        same_catalog_id = bool(previous.get('spotify_id') and
                               previous.get('spotify_id') == candidate.get('spotify_id'))
        catalog_conflict = bool(previous.get('spotify_id') and candidate.get('spotify_id') and
                                previous['spotify_id'] != candidate['spotify_id'])
        artist_conflict = bool(previous.get('artist_id') and candidate.get('artist_id') and
                               previous['artist_id'] != candidate['artist_id'])
        compatible = not artist_conflict and (same_catalog_id or same_album and not catalog_conflict)
        if compatible and _artwork_quality(candidate) > _artwork_quality(previous):
            previous['thumbnail'] = candidate['thumbnail']
            for field in ('album', 'album_id'):
                if candidate.get(field):
                    previous[field] = candidate[field]
        for field, value in candidate.items():
            if not compatible and field in ('filename', 'url', 'spotify_id', 'artist_id', 'album', 'album_id', 'thumbnail'):
                continue
            if value and (field == 'filename' or not previous.get(field)):
                previous[field] = value
    return list(merged.values())


class ListeningPreferences:
    def __init__(self, history, library, now=None):
        self.tracks = defaultdict(float)
        self.artists = defaultdict(float)
        self.track_metadata = {}
        self.artist_metadata = {}
        self.liked = set()
        self.heard = set()
        self.recent = set()
        self.catalog_tracks = []
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
                self.heard.add(key)
                if age <= 7:
                    self.recent.add(key)
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
        return sorted(merge_tracks(candidates), key=lambda item: (-self.score(item), recommendation_identity(item)))[:limit]

    def rotation(self, candidates, limit=15):
        """A familiar collection, leaving some local music for discovery fallback."""
        ranked = self.rank(candidates, limit=5000)
        if not ranked:
            return []
        # A small collection should not fill every Home shelf with the same list.
        size = min(limit, max(1, len(ranked) // 2))
        return ranked[:size]

    def discover(self, candidates, *, limit=20, exclude=(), day_seed=''):
        """Unheard music first, stable for a day, with a soft per-artist limit."""
        candidates = merge_tracks(candidates)
        excluded = list(exclude)
        fresh = [track for track in candidates if not any(same_recommendation_recording(track, previous)
                                                        for previous in excluded)]
        # Keep a one-song/offline library useful; otherwise never pad with Rotation.
        pool = fresh or candidates

        def rank_key(track):
            key = track_key(track.get('title'), track.get('artist'))
            familiarity = (3 if self.tracks[key] < 0 else 2 if key in self.recent else
                           1 if key in self.heard or key in self.liked else 0)
            affinity = min(6, max(-3, self.artists[key[1]]))
            jitter = hashlib.sha256((str(day_seed) + repr(recommendation_identity(track))).encode()).hexdigest()
            return familiarity, -affinity, jitter

        ordered = sorted(pool, key=rank_key)
        selected, deferred, counts = [], [], defaultdict(int)
        for track in ordered:
            artist = normalized(track.get('artist'))
            if counts[artist] >= 3:
                deferred.append(track)
            else:
                selected.append(track)
                counts[artist] += 1
        # Sparse/single-artist collections remain playable without pretending
        # unavailable artists exist. Diversity affects order, not completeness.
        return (selected + deferred)[:limit]


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
    for field in ('spotify_id', 'artist_id', 'album_id'):
        value = candidate.get(field)
        if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
            item[field] = value
    kind = candidate.get('recording_type')
    if kind in ('live', 'remix', 'acoustic', 'instrumental', 'cover', 'karaoke', 'studio', 'original', 'unspecified'):
        item['recording_type'] = kind
    return item


def available(call, *args, **kwargs):
    """Provider failure is an empty candidate set, never a broken library."""
    try:
        return call(*args, **kwargs) or []
    except Exception:
        return []
