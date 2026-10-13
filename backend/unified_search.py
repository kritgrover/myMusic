"""Catalog search and recording-aware source ranking, without account state."""

import asyncio
import hashlib
import json
import math
import re
import threading
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from difflib import SequenceMatcher
from urllib.parse import urlsplit

from spotipy.exceptions import SpotifyException

from source_security import youtube_url


LABELS = {
    'live': 'Live', 'remix': 'Remix', 'acoustic': 'Acoustic',
    'instrumental': 'Instrumental', 'cover': 'Cover', 'karaoke': 'Karaoke',
    'studio': 'Studio', 'original': 'Original', 'unspecified': 'Unspecified',
}
VERSION_PATTERNS = (
    ('live', r'(?:\blive\s+(?:at|from|in|on|version|performance|session|recording)\b|[\[(\-–—]\s*live\b|\blive\s*[\])]|\bin concert\b)'),
    ('remix', r'\b(?:remix(?:ed)?|rework|sped up|slowed(?: down)?|nightcore)\b'),
    ('acoustic', r'\b(?:acoustic|unplugged)\b'),
    ('instrumental', r'\binstrumental\b'),
    ('karaoke', r'\bkaraoke\b'),
    ('cover', r'\bcover(?:ed by| version)?\b'),
    ('studio', r'\bstudio (?:version|recording)\b'),
)


def normalized(value):
    value = unicodedata.normalize('NFKD', str(value or '')).casefold()
    return ' '.join(re.sub(r'[^\w\s]', ' ', ''.join(c for c in value if not unicodedata.combining(c))).split())


def recording_type(title, album='', catalog=False):
    label = f'{title or ""} {album or ""}'
    for kind, pattern in VERSION_PATTERNS:
        if re.search(pattern, label, re.I):
            return kind
    return 'original' if catalog else 'unspecified'


def recording_fields(title, album='', catalog=False):
    kind = recording_type(title, album, catalog)
    return {'recording_type': kind, 'recording_label': LABELS[kind]}


def recording_key(track):
    spotify_id = track.get('spotify_id', '')
    if spotify_id:
        return 'spotify:' + spotify_id
    kind = track.get('recording_type') or recording_type(track.get('title'), track.get('album'))
    # Original/unspecified are the same identity when no version is marked.
    kind = 'original' if kind in ('original', 'unspecified', 'studio') else kind
    identity = [normalized(track.get(field)) for field in ('title', 'artist', 'album')] + [kind]
    return 'metadata:' + hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()


def _duration(value):
    try:
        number = float(value or 0)
        return number if math.isfinite(number) and 0 <= number <= 86400 else 0
    except (ValueError, TypeError):
        return 0


def _image(item):
    images = item.get('images') or []
    return (images[0] or {}).get('url', '') if images else ''


def format_catalog(data):
    result = {'songs': [], 'artists': [], 'albums': [], 'playlists': []}
    for track in (data.get('tracks') or {}).get('items', []):
        if not track or not track.get('id') or not track.get('name') or track.get('is_playable') is False:
            continue
        album = track.get('album') or {}
        artists = track.get('artists') or []
        result['songs'].append({
            'id': track['id'], 'spotify_id': track['id'], 'title': track['name'],
            'artist': ', '.join(a.get('name', '') for a in artists),
            'artist_id': artists[0].get('id', '') if artists else '',
            'album': album.get('name', ''), 'album_id': album.get('id', ''),
            'duration': _duration((track.get('duration_ms') or 0) / 1000),
            'thumbnail': _image(album), 'url': (track.get('external_urls') or {}).get('spotify', ''),
            'provider': 'spotify', 'kind': 'track',
            **recording_fields(track['name'], album.get('name'), catalog=True),
        })
    for artist in (data.get('artists') or {}).get('items', []):
        if not artist or not artist.get('id') or not artist.get('name'):
            continue
        result['artists'].append({'id': artist['id'], 'name': artist['name'],
                                  'thumbnail': _image(artist), 'genres': artist.get('genres') or [],
                                  'provider': 'spotify', 'kind': 'artist'})
    for album in (data.get('albums') or {}).get('items', []):
        if not album or not album.get('id') or not album.get('name'):
            continue
        artists = album.get('artists') or []
        result['albums'].append({
            'id': album['id'], 'name': album['name'], 'title': album['name'],
            'artist': ', '.join(a.get('name', '') for a in artists),
            'artist_id': artists[0].get('id', '') if artists else '',
            'thumbnail': _image(album), 'type': album.get('album_type', 'album'),
            'release_date': album.get('release_date', ''), 'total_tracks': album.get('total_tracks', 0),
            'provider': 'spotify', 'kind': 'album',
        })
    for playlist in (data.get('playlists') or {}).get('items', []):
        if not playlist or not playlist.get('id') or not playlist.get('name'):
            continue
        result['playlists'].append({
            'id': playlist['id'], 'name': playlist['name'],
            'description': playlist.get('description', ''), 'thumbnail': _image(playlist),
            'owner': (playlist.get('owner') or {}).get('display_name', ''),
            'url': (playlist.get('external_urls') or {}).get('spotify', ''),
            'provider': 'spotify', 'kind': 'playlist', 'is_local': False,
        })
    return result


def safe_candidate(video):
    if not isinstance(video, dict) or not video.get('title'):
        return None
    try:
        url = youtube_url(video.get('url', ''))
    except ValueError:
        return None
    video_id = url.rsplit('=', 1)[-1]
    return {'id': video_id, 'title': str(video['title'])[:500],
            'uploader': str(video.get('uploader') or '')[:300],
            'duration': _duration(video.get('duration')), 'url': url,
            'thumbnail': f'https://img.youtube.com/vi/{video_id}/hqdefault.jpg',
            **recording_fields(video['title'])}


def candidate_from_url(url, remembered=False):
    """A remembered URL proves a preference, not that video's title or duration."""
    label = 'Saved source' if remembered else 'Provided source'
    item = safe_candidate({'url': url, 'title': label + ' (details unavailable)', 'uploader': '', 'duration': 0})
    return {**item, 'details_available': False}


def rank_candidates(track, videos):
    title = normalized(track['title'])
    artist = normalized(track.get('artist'))
    wanted = track.get('recording_type') or recording_type(track['title'], track.get('album'))
    requested_duration = _duration(track.get('duration'))
    rows = []
    seen = set()
    for video in videos:
        item = safe_candidate(video)
        if not item or item['url'] in seen:
            continue
        seen.add(item['url'])
        candidate_title = normalized(item['title'])
        artist_text = normalized(item['title'] + ' ' + item['uploader'])
        title_words = set(title.split())
        overlap = len(title_words & set(candidate_title.split())) / max(len(title_words), 1)
        title_score = max(SequenceMatcher(None, title, candidate_title).ratio(), overlap)
        score = 55 * title_score
        eligible = title_score >= .65
        if artist:
            artist_words = set(artist.split())
            artist_match = len(artist_words & set(artist_text.split())) / max(len(artist_words), 1)
            score += 30 * artist_match if artist_match >= .5 else -30
            eligible = eligible and artist_match >= .5
        else:
            score += 10
        if requested_duration and item['duration']:
            difference = abs(requested_duration - item['duration'])
            score += max(-35, 15 - difference / max(2, requested_duration * .015))
            eligible = eligible and difference <= max(30, requested_duration * .15)
        actual = item['recording_type']
        special = set(LABELS) - {'original', 'unspecified', 'studio'}
        if actual in special and actual != wanted:
            score -= 45
            eligible = False
        elif wanted in special:
            score += 15 if actual == wanted else -25
            eligible = eligible and actual == wanted
        if re.search(r'\b(?:official audio|provided to youtube)\b', item['title'] + ' ' + item['uploader'], re.I):
            score += 5
        item['match_score'] = round(max(0, min(100, score)), 1)
        # A high title/duration score cannot cancel a known artist/version mismatch.
        # Keep incompatible options available for a deliberate user correction.
        item['auto_selectable'] = eligible
        rows.append(item)
    return sorted(rows, key=lambda row: (not row['auto_selectable'], -row['match_score']))


class ProviderBusy(Exception):
    pass


class CatalogPremiumRequired(Exception):
    """A known catalog access restriction, with a safe message for the client."""

    def __init__(self):
        super().__init__(
            "Spotify catalog access requires an active Premium subscription for the app owner's Spotify account. "
            'Showing available sources and your library.'
        )


class SearchProviders:
    """Bound concurrent blocking clients; timed-out work cannot accumulate in a queue."""

    def __init__(self, database, spotify, downloads, timeout=8):
        self.database = database
        self.spotify = spotify
        self.downloads = downloads
        self.timeout = timeout
        self._pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix='music-search')
        self._slots = threading.BoundedSemaphore(4)

    async def call(self, function):
        if not self._slots.acquire(blocking=False):
            raise ProviderBusy('Search providers are busy')
        try:
            future = self._pool.submit(function)
        except Exception:
            self._slots.release()
            raise
        future.add_done_callback(lambda _: self._slots.release())
        return await asyncio.wait_for(asyncio.wrap_future(future), timeout=self.timeout)

    def _catalog(self, query, limit):
        database = self.database()
        key = 'unified-search:v1:' + hashlib.sha256(f'{query}:{limit}'.encode()).hexdigest()
        cached = database.get_cache(key)
        if cached is not None:
            return cached
        client = self.spotify().sp
        if client is None:
            raise ProviderBusy('Catalog is unavailable')
        try:
            catalog = client.search(q=query, type='track,artist,album,playlist', limit=min(10, limit), market='US')
        except SpotifyException as exc:
            if (exc.http_status == 403
                    and 'active premium subscription required for the owner of the app' in str(exc.msg).casefold()):
                raise CatalogPremiumRequired() from None
            raise
        result = format_catalog(catalog)
        database.set_search_cache(key, result, ttl_seconds=600)
        return result

    async def catalog(self, query, limit):
        return await self.call(lambda: self._catalog(query, limit))

    def _videos(self, query, limit):
        database = self.database()
        key = 'source-search:v1:' + hashlib.sha256(f'{query}:{limit}'.encode()).hexdigest()
        cached = database.get_cache(key)
        if cached is not None:
            return cached
        videos = self.downloads().search_youtube(query=query, duration_min=0, duration_max=86400, max_results=limit)
        result = [item for item in (safe_candidate(video) for video in videos) if item]
        if result:
            database.set_search_cache(key, result, ttl_seconds=300)
        return result

    async def videos(self, query, limit=10):
        return await self.call(lambda: self._videos(query, limit))


def is_catalog_url(value):
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == 'https' and parsed.hostname == 'open.spotify.com'
                and not parsed.username and not parsed.password and parsed.port in (None, 443)
                and re.fullmatch(r'/(?:intl-[a-z]{2}/)?track/[A-Za-z0-9]+', parsed.path) is not None)
    except (TypeError, ValueError):
        return False
