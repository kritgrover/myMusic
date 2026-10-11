"""Small, bounded, token-free metadata records for the persistent user library."""

import math
import re
from urllib.parse import parse_qsl, quote, unquote, urlsplit

from fastapi import HTTPException
from source_security import youtube_url


KINDS = ("tracks", "albums", "artists")
TEXT_FIELDS = {
    "tracks": {"title": 300, "artist": 300, "album": 300, "filename": 1024,
               "url": 2048, "thumbnail": 2048, "source_id": 512, "spotify_id": 512},
    "albums": {"title": 300, "artist": 300, "thumbnail": 2048},
    "artists": {"name": 300, "thumbnail": 2048},
}


def validate_identity(kind, item_id):
    if kind not in KINDS:
        raise HTTPException(status_code=400, detail="Library kind must be tracks, albums, or artists")
    if not isinstance(item_id, str) or not item_id.strip() or len(item_id) > 512 or any(ord(c) < 32 for c in item_id):
        raise HTTPException(status_code=400, detail="Invalid library item ID")
    _reject_credentials(item_id)
    return item_id


def _reject_credentials(value):
    decoded = unquote(value)
    if re.search(r"(?:media_token|access_token|authorization|bearer)\s*[=: ]", decoded, re.I):
        raise HTTPException(status_code=400, detail="Save canonical URLs without credentials or media tokens")


def clean_thumbnail(value, owns_filename, owns_playlist):
    if not value:
        return ""
    _reject_credentials(value)
    try:
        parsed = urlsplit(value)
        if parsed.username or parsed.password:
            raise ValueError()
        path = parsed.path
        if path.startswith('/downloads/'):
            if not path.endswith('/artwork') or parsed.query or parsed.fragment:
                raise ValueError()
            filename = unquote(path[len('/downloads/'):-len('/artwork')])
            if not owns_filename(filename):
                return ""
            return '/downloads/' + quote(filename.replace('\\', '/'), safe='/') + '/artwork'
        if path.startswith('/playlists/'):
            match = re.fullmatch(r'/playlists/([^/]+)/cover', path)
            if not match or parsed.query or parsed.fragment:
                raise ValueError()
            playlist_id = unquote(match.group(1))
            return '/playlists/' + quote(playlist_id, safe='') + '/cover' if owns_playlist(playlist_id) else ""
        if parsed.scheme != 'https' or not parsed.hostname or parsed.fragment or parsed.port not in (None, 443):
            raise ValueError()
        if any(key.lower() in ('token', 'jwt', 'secret', 'api_key', 'apikey') for key, _ in parse_qsl(parsed.query)):
            raise ValueError()
        return value
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="Invalid saved artwork URL") from None


def normalize_item(kind, item_id, metadata, normalize_filename, owns_filename, owns_playlist):
    validate_identity(kind, item_id)
    if not isinstance(metadata, dict):
        raise HTTPException(status_code=400, detail="Library metadata must be an object")
    fields = TEXT_FIELDS[kind]
    allowed = set(fields) | {'id'} | ({'duration'} if kind == 'tracks' else set())
    if set(metadata) - allowed:
        raise HTTPException(status_code=400, detail="Unsupported library metadata fields")
    item = {'id': item_id}
    for field, limit in fields.items():
        value = metadata.get(field)
        value = '' if value is None else value
        if not isinstance(value, str) or len(value) > limit or any(ord(c) < 32 for c in value):
            raise HTTPException(status_code=400, detail=f"Invalid library {field}")
        item[field] = value.strip()
    label = 'name' if kind == 'artists' else 'title'
    if not item[label]:
        raise HTTPException(status_code=400, detail=f"Library {label} cannot be empty")
    original_id = metadata.get('id')
    if original_id is not None:
        validate_identity(kind, original_id)
    if kind == 'tracks':
        if original_id and original_id != item_id and not item['source_id']:
            item['source_id'] = original_id
        _reject_credentials(item['source_id'])
        _reject_credentials(item['spotify_id'])
        duration = metadata.get('duration')
        duration = 0 if duration is None else duration
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 0 <= duration <= 86400:
            raise HTTPException(status_code=400, detail="Track duration must be between 0 and 86400 seconds")
        item['duration'] = float(duration)
        if item['filename']:
            item['filename'] = normalize_filename(item['filename'])
            if not owns_filename(item['filename']):
                raise HTTPException(status_code=404, detail="File not found")
        if item['url']:
            _reject_credentials(item['url'])
            try:
                item['url'] = youtube_url(item['url'])
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from None
    item['thumbnail'] = clean_thumbnail(item['thumbnail'], owns_filename, owns_playlist)
    return item
