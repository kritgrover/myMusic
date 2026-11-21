"""Bounded, credential-free inputs for account discovery controls."""
import math
import re
from fastapi import HTTPException
from saved_library import _reject_credentials, clean_thumbnail


MODES = {'familiar', 'balanced', 'discover'}
RECORDINGS = {'live', 'remix', 'acoustic', 'instrumental', 'cover', 'karaoke',
              'studio', 'original', 'unspecified'}


def default_preferences():
    return {'mode': 'balanced', 'autoplay': False, 'onboarding_completed': False, 'seed_artists': []}


def text(value, field, limit, *, required=False):
    value = '' if value is None else value
    if not isinstance(value, str) or len(value) > limit or any(ord(char) < 32 for char in value):
        raise HTTPException(400, f'Invalid discovery {field}')
    value = value.strip()
    if required and not value:
        raise HTTPException(400, f'Discovery {field} is required')
    _reject_credentials(value)
    return value


def artist(value):
    if not isinstance(value, dict) or set(value) - {'id', 'name', 'thumbnail'}:
        raise HTTPException(400, 'Invalid discovery artist')
    identity = text(value.get('id'), 'artist ID', 128, required=True)
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', identity):
        raise HTTPException(400, 'Invalid discovery artist ID')
    return {'id': identity, 'name': text(value.get('name'), 'artist name', 300, required=True),
            'thumbnail': clean_thumbnail(text(value.get('thumbnail'), 'artwork', 2048), lambda _: False, lambda _: False)}


def preference_patch(value):
    if not isinstance(value, dict) or set(value) - set(default_preferences()):
        raise HTTPException(400, 'Unsupported discovery preference fields')
    result = {}
    if 'mode' in value:
        if not isinstance(value['mode'], str) or value['mode'] not in MODES:
            raise HTTPException(400, 'Choose familiar, balanced, or discover')
        result['mode'] = value['mode']
    for field in ('autoplay', 'onboarding_completed'):
        if field in value:
            if not isinstance(value[field], bool):
                raise HTTPException(400, f'Discovery {field} must be true or false')
            result[field] = value[field]
    if 'seed_artists' in value:
        choices = value['seed_artists']
        if not isinstance(choices, list) or len(choices) > 5:
            raise HTTPException(400, 'Choose up to five artists')
        artists = [artist(choice) for choice in choices]
        if len({choice['id'] for choice in artists}) != len(artists):
            raise HTTPException(400, 'Choose each artist once')
        result['seed_artists'] = artists
    return result


def track(value):
    fields = {'id': 512, 'title': 300, 'artist': 300, 'album': 300, 'spotify_id': 128,
              'artist_id': 128, 'album_id': 128, 'filename': 1024, 'url': 2048,
              'thumbnail': 2048, 'recording_type': 30}
    if not isinstance(value, dict) or set(value) - (set(fields) | {'duration'}):
        raise HTTPException(400, 'Unsupported discovery track fields')
    result = {field: text(value.get(field), field, limit, required=field in ('title', 'artist'))
              for field, limit in fields.items()}
    for field in ('spotify_id', 'artist_id', 'album_id'):
        if result[field] and not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', result[field]):
            raise HTTPException(400, f'Invalid discovery {field}')
    if result['recording_type'] and result['recording_type'] not in RECORDINGS:
        raise HTTPException(400, 'Invalid discovery recording type')
    duration = value.get('duration')
    if duration is None:
        duration = 0
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 0 <= duration <= 86400:
        raise HTTPException(400, 'Invalid discovery duration')
    result['duration'] = duration
    return result


def feedback_track(value):
    valid = track(value)
    # Feedback is a musical identity, never an audio capability or disk path.
    return {field: valid[field] for field in ('title', 'artist', 'album', 'spotify_id', 'artist_id', 'recording_type')
            if valid[field]}
