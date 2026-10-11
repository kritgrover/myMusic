"""Authenticated unified search, with account-scoped source corrections."""

import asyncio
import re
from pathlib import PurePosixPath
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, Field

from saved_library import clean_thumbnail
from source_security import search_query, youtube_url
from unified_search import (
    LABELS, SearchProviders, candidate_from_url, is_catalog_url, normalized,
    rank_candidates, recording_fields, recording_key,
)


class RecordingRequest(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    artist: str = Field(default='', max_length=300)
    album: str = Field(default='', max_length=300)
    duration: float = Field(default=0, ge=0, le=86400, allow_inf_nan=False)
    spotify_id: str = Field(default='', max_length=128)
    url: str = Field(default='', max_length=2048)
    recording_type: str = Field(default='', max_length=30)


def _identity(payload):
    track = payload.model_dump() if hasattr(payload, 'model_dump') else payload.dict()
    for field in ('title', 'artist', 'album', 'spotify_id', 'url', 'recording_type'):
        value = track[field]
        if any(ord(char) < 32 for char in value):
            raise HTTPException(status_code=400, detail='Recording metadata must contain printable text')
        track[field] = value.strip()
    if not track['title']:
        raise HTTPException(status_code=400, detail='A recording title is required')
    if track['spotify_id'] and not re.fullmatch(r'[A-Za-z0-9_-]+', track['spotify_id']):
        raise HTTPException(status_code=400, detail='Invalid catalog recording ID')
    if track['recording_type'] and track['recording_type'] not in LABELS:
        raise HTTPException(status_code=400, detail='Invalid recording type')
    if track['url']:
        if is_catalog_url(track['url']):
            track['url'] = ''  # Catalog links identify music but cannot be streamed by this backend.
        else:
            try:
                track['url'] = youtube_url(track['url'])
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from None
    return track


def _matches(query, item):
    text = normalized(' '.join(str(item.get(field) or '') for field in ('title', 'name', 'artist', 'album', 'filename')))
    return all(token in text for token in normalized(query).split())


def _sort_local(query, rows):
    needle = normalized(query)
    return sorted(rows, key=lambda item: (
        normalized(item.get('title') or item.get('name')) != needle,
        not normalized(item.get('title') or item.get('name')).startswith(needle),
        normalized(item.get('title') or item.get('name')),
    ))


def build_search_router(database, spotify, downloads, current_user, saved_library, list_downloads):
    """Accept accessors so app/test dependency replacement stays effective."""
    router = APIRouter(prefix='/search', tags=['search'])
    providers = SearchProviders(database, spotify, downloads)
    router.search_providers = providers

    def local_results(request, query, limit):
        user_id = current_user(request)['id']
        library = saved_library(request)
        owned_files = {row['filename']: row for row in list_downloads(request).get('files', [])}
        owned_playlists = database().get_all_playlists(user_id)
        library_rows = []
        seen = set()

        def add(item, kind, origin, **extra):
            item = {**item, 'kind': kind, 'provider': 'local', 'library_origin': origin, **extra}
            item.pop('file_path', None)
            try:
                item['thumbnail'] = clean_thumbnail(item.get('thumbnail') or '',
                                                    lambda filename: filename in owned_files,
                                                    lambda playlist_id: playlist_id in owned_playlists)
            except HTTPException:
                item['thumbnail'] = ''
            if kind == 'track':
                item.update(recording_fields(item.get('title'), item.get('album'), bool(item.get('spotify_id'))))
                filename = item.get('filename', '').replace('\\', '/')
                item['filename'] = filename if filename in owned_files else ''
                if item.get('url'):
                    try:
                        item['url'] = youtube_url(item['url'])
                    except ValueError:
                        item['url'] = ''
            key = (kind, item.get('id'))
            if key not in seen and _matches(query, item):
                seen.add(key)
                library_rows.append(item)

        for kind, items in library.items():
            for item in items:
                add(item, {'tracks': 'track', 'albums': 'album', 'artists': 'artist'}[kind], 'saved')
        playlists = []
        for playlist in owned_playlists.values():
            item = {key: value for key, value in playlist.items() if key not in ('songs', 'coverImage')}
            item.update({'thumbnail': f'/playlists/{quote(playlist["id"], safe="")}/cover' if playlist.get('coverImage') else '',
                         'provider': 'local', 'kind': 'playlist', 'is_local': True,
                         'owner': 'You', 'track_count': len(playlist['songs'])})
            if _matches(query, item):
                playlists.append(item)
                add(item, 'playlist', 'playlist')
            for song in playlist['songs']:
                add(song, 'track', 'playlist', playlist_id=playlist['id'], playlist_name=playlist['name'])
        saved_files = {row.get('filename') for row in library_rows}
        for filename, download in owned_files.items():
            if filename in saved_files:
                continue
            add({'id': 'download:' + filename, 'title': download.get('title') or PurePosixPath(filename).stem,
                 'artist': download.get('artist') or '', 'filename': filename,
                 'thumbnail': '/downloads/' + quote(filename, safe='/') + '/artwork',
                 'duration': 0, 'url': ''}, 'track', 'download')
        return _sort_local(query, library_rows)[:limit * 2], _sort_local(query, playlists)[:limit]

    @router.get('/library')
    async def search_library(request: Request, q: str = Query(min_length=1, max_length=500),
                             limit: int = Query(default=20, ge=1, le=20)):
        """Return owned music immediately, independently of catalog/video availability."""
        current_user(request)
        try:
            query = search_query(q)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None
        try:
            library, playlists = await asyncio.to_thread(local_results, request, query, limit)
        except Exception:
            raise HTTPException(status_code=503, detail='Your library could not be searched. Please try again.') from None
        return {'library': library, 'playlists': playlists}

    @router.get('/unified')
    async def unified(request: Request, q: str = Query(min_length=1, max_length=500), limit: int = Query(default=12, ge=1, le=20)):
        current_user(request)
        try:
            query = search_query(q)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from None
        result = {'query': query, 'songs': [], 'artists': [], 'albums': [], 'playlists': [],
                  'library': [], 'suggestions': [], 'warnings': []}
        # Only public provider results are cached. Local results are freshly scoped on each request.
        local_task = asyncio.to_thread(local_results, request, query, limit)
        if query.startswith('https://'):
            local = (await asyncio.gather(local_task, return_exceptions=True))[0]
        else:
            local, catalog = await asyncio.gather(local_task, providers.catalog(query, limit), return_exceptions=True)
            if isinstance(catalog, Exception):
                result['warnings'].append('Music catalog is temporarily unavailable. Showing available sources and your library.')
            else:
                result.update(catalog)
        if isinstance(local, Exception):
            result['warnings'].append('Your library could not be searched. Please try again.')
        else:
            result['library'], local_playlists = local
            result['playlists'] = local_playlists + result['playlists']
        if not result['songs']:
            try:
                videos = await providers.videos(query, limit)
                result['songs'] = [{**video, 'artist': video['uploader'], 'album': '', 'provider': 'youtube',
                                    'kind': 'track', 'spotify_id': ''} for video in videos]
            except Exception:
                result['warnings'].append('Video search is temporarily unavailable. Please try again.')
        suggestions = []
        for category in ('artists', 'songs', 'albums', 'library'):
            for item in result[category]:
                suggestion = item.get('title') or item.get('name')
                if suggestion and normalized(suggestion) not in {normalized(value) for value in suggestions}:
                    suggestions.append(suggestion)
        result['suggestions'] = suggestions[:8]
        return result

    def remembered_source(user_id, track):
        stored = database().get_source_preference(user_id, recording_key(track))
        if stored:
            try:
                return youtube_url(stored)
            except ValueError:
                return None
        return None

    async def candidates_for(track):
        query = search_query(' '.join(filter(None, (track['artist'], track['title'])))[:500])
        return rank_candidates(track, await providers.videos(query, 12))

    @router.post('/candidates')
    async def candidates(payload: RecordingRequest, request: Request):
        user_id = current_user(request)['id']
        track = _identity(payload)
        selected = remembered_source(user_id, track)
        result = {'candidates': [], 'selected_url': selected or track['url'] or None,
                  'remembered': bool(selected), 'warnings': []}
        try:
            result['candidates'] = await candidates_for(track)
        except Exception:
            result['warnings'].append('Source search is temporarily unavailable. You can retry or paste a YouTube video URL.')
        chosen = selected or track['url']
        if chosen and chosen not in {item['url'] for item in result['candidates']}:
            result['candidates'].insert(0, {**candidate_from_url(chosen, remembered=bool(selected)), 'is_selected': True})
        for item in result['candidates']:
            item['is_selected'] = item['url'] == chosen
        return result

    @router.post('/resolve')
    async def resolve(payload: RecordingRequest, request: Request):
        user_id = current_user(request)['id']
        track = _identity(payload)
        selected = remembered_source(user_id, track)
        if selected or track['url']:
            return {**candidate_from_url(selected or track['url'], remembered=bool(selected)), 'remembered': bool(selected),
                    'selection_reason': 'remembered' if selected else 'provided'}
        try:
            rows = await candidates_for(track)
        except Exception:
            raise HTTPException(status_code=503, detail='Source search is temporarily unavailable. Please try again.') from None
        if not rows:
            raise HTTPException(status_code=404, detail='No playable source found. Choose another recording or set a source.')
        eligible = [row for row in rows if row['auto_selectable'] and row['match_score'] >= 45]
        if not eligible:
            raise HTTPException(status_code=409, detail='No confident recording match. Review available sources to choose one.')
        return {**eligible[0], 'remembered': False, 'selection_reason': 'ranked'}

    @router.put('/source')
    def remember(payload: RecordingRequest, request: Request):
        user_id = current_user(request)['id']
        track = _identity(payload)
        if not track['url']:
            raise HTTPException(status_code=400, detail='An individual YouTube video URL is required')
        aliases = [recording_key({**track, 'spotify_id': ''})] if track['spotify_id'] else []
        database().save_source_preference(user_id, recording_key(track), track['url'], aliases=aliases)
        return {'url': track['url'], 'remembered': True}

    @router.delete('/source')
    def forget(payload: RecordingRequest, request: Request):
        user_id = current_user(request)['id']
        track = _identity(payload)
        database().remove_source_preference(user_id, recording_key(track))
        return {'remembered': False}

    return router
