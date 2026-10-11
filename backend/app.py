from fastapi import FastAPI, HTTPException, Request, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse, Response
from starlette.background import BackgroundTask
from pydantic import BaseModel
from typing import List, Optional, Dict
import os
import uuid
import hashlib
import shutil
import asyncio
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, unquote
from config import settings
import httpx
from download_service import DownloadService
from database import db
from spotify_service import spotify_service, SpotifyCatalogError
from search_routes import build_search_router
from unified_search import recording_key
from lyrics_service import lyrics_service
from metadata_service import MetadataService, _regex_parse as _enhanced_regex_parse
from auth_utils import create_access_token, decode_access_token, create_media_token, decode_media_token
from media_files import audio_file_response, validate_path_safety
from source_security import youtube_url, search_query, streaming_target, VIDEO_ID
from stream_cache import StreamCache
from saved_library import normalize_item, validate_identity, clean_thumbnail
from listening_history import validate_report
from recommendation_ranking import ListeningPreferences, safe_track, available, normalized
from mutagen.mp4 import MP4
from mutagen.easyid3 import EasyID3
from mutagen.id3 import ID3, APIC
from mutagen.mp4 import MP4Cover


app = FastAPI(title="Music Download API")

# CORS middleware to allow Flutter app to connect
# Configure allowed origins - more specific than wildcard for better security
ALLOWED_ORIGINS = [
    "http://localhost:*",
    "http://127.0.0.1:*",
    "http://localhost:3000",  # Web development
    "http://localhost:8080",  # Flutter web
    "http://127.0.0.1:8080",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allow all origins for Flutter desktop/mobile apps
    allow_credentials=True,
    allow_methods=["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"],  # Explicitly list allowed methods
    allow_headers=["Content-Type", "Authorization", "Range", "If-Range", "Accept"],  # Only needed headers
    expose_headers=["Content-Length", "Content-Range", "Accept-Ranges"],  # For streaming support
)

# Initialize download service
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOADS_DIR = os.path.join(BASE_DIR, "downloads")
os.makedirs(DOWNLOADS_DIR, exist_ok=True)

download_service = DownloadService(output_dir=DOWNLOADS_DIR)
metadata_service = MetadataService(download_service=download_service, spotify_service=spotify_service)
stream_cache = StreamCache(
    os.path.join(download_service.output_dir, "_stream_cache"),
    ttl_seconds=getattr(settings, "STREAM_CACHE_TTL_SECONDS", 86400),
    max_bytes=getattr(settings, "STREAM_CACHE_MAX_BYTES", 536870912),
    max_file_bytes=getattr(settings, "STREAM_CACHE_MAX_FILE_BYTES", 67108864),
)
db.migrate_download_ownership(
    str(path.relative_to(download_service.output_dir)).replace("\\", "/")
    for path in Path(download_service.output_dir).rglob("*")
    if path.is_file() and path.suffix.lower() in (".mp3", ".m4a") and "_stream_cache" not in path.parts
)

# Global progress tracking for CSV conversions
csv_progress: Dict[str, Dict] = {}

# Global progress tracking for downloads
download_progress: Dict[str, Dict] = {}

# Maximum age for progress entries (1 hour in seconds)
PROGRESS_MAX_AGE = 3600

def cleanup_old_progress():
    """Remove progress entries older than PROGRESS_MAX_AGE seconds"""
    import time
    current_time = time.time()
    
    # Cleanup csv_progress
    keys_to_remove = []
    for key, value in csv_progress.items():
        created_at = value.get('created_at', 0)
        if current_time - created_at > PROGRESS_MAX_AGE:
            keys_to_remove.append(key)
    for key in keys_to_remove:
        del csv_progress[key]
    
    # Cleanup download_progress
    keys_to_remove = []
    for key, value in download_progress.items():
        created_at = value.get('created_at', 0)
        if current_time - created_at > PROGRESS_MAX_AGE:
            keys_to_remove.append(key)
    for key in keys_to_remove:
        del download_progress[key]


class SearchRequest(BaseModel):
    query: str
    duration_min: int = 0
    duration_max: float = 600


class DownloadRequest(BaseModel):
    url: str
    title: str
    artist: str = ""
    album: str = ""
    output_format: str = "m4a"  # "m4a" or "mp3"
    embed_thumbnail: bool = False
    spotify_id: str = ""
    recording_type: str = ""


class VideoInfo(BaseModel):
    id: str
    title: str
    uploader: str
    duration: float
    url: str
    thumbnail: str

class Song(BaseModel):
    id: str
    title: str
    artist: Optional[str] = ""
    album: Optional[str] = ""
    filename: str
    file_path: Optional[str] = ""
    url: Optional[str] = ""
    thumbnail: Optional[str] = ""
    duration: Optional[float] = 0.0

class Playlist(BaseModel):
    id: str
    name: str
    songs: List[Song] = []
    createdAt: str
    updatedAt: str
    coverImage: Optional[str] = None
    isPublic: bool = False

class CreatePlaylistRequest(BaseModel):
    name: str

class AddSongRequest(BaseModel):
    id: str
    title: str
    artist: Optional[str] = ""
    album: Optional[str] = ""
    filename: str
    file_path: Optional[str] = ""
    url: Optional[str] = ""
    thumbnail: Optional[str] = ""
    duration: Optional[float] = 0.0


class LoginRequest(BaseModel):
    username: str
    password: str

class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: Dict[str, object]


class ProfileUpdateRequest(BaseModel):
    username: str
    tagline: Optional[str] = ""


def _require_current_user(request: Request) -> Dict:
    current_user = getattr(request.state, "current_user", None)
    if not current_user:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return current_user


def _source_url(value):
    try:
        return youtube_url(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None


def _download_filename(filename):
    path = validate_path_safety(download_service.output_dir, filename)
    relative = path.relative_to(Path(download_service.output_dir).resolve()).as_posix()
    if relative.startswith("_stream_cache/") or path.suffix.lower() not in (".mp3", ".m4a"):
        raise HTTPException(status_code=400, detail="Invalid audio file")
    return relative


def _owned_file(user_id, filename):
    filename = _download_filename(filename)
    if not db.owns_download(user_id, filename):
        raise HTTPException(status_code=404, detail="File not found")
    path = validate_path_safety(download_service.output_dir, filename)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return path


def _raw_download_filename(request, fallback, artwork=False):
    """Decode the server's raw path once, preserving literal percent filenames."""
    raw = request.scope.get("raw_path")
    if raw is None:
        return fallback
    path = raw.decode("ascii").removeprefix("/downloads/")
    if artwork:
        path = path.removesuffix("/artwork")
    return unquote(path)


def _media_path(path):
    """Return exact canonical token scope; reject queries except inside encoded video URLs."""
    if path.startswith("/downloads/") and "?" not in path and "#" not in path:
        filename = _download_filename(unquote(path[len("/downloads/"):]))
        return "/downloads/" + quote(filename, safe="/")
    if path.startswith("/stream/"):
        source = _source_url(unquote(path[len("/stream/"):]))
        return "/stream/" + quote(source, safe="")
    raise HTTPException(status_code=400, detail="Only audio media paths can be authorized")


class MediaAuthorizationRequest(BaseModel):
    path: str


@app.post("/media/authorize")
def authorize_media(payload: MediaAuthorizationRequest, request: Request):
    user = _require_current_user(request)
    path = _media_path(payload.path)
    if path.startswith("/downloads/"):
        _owned_file(user["id"], unquote(path[len("/downloads/"):]))
    token, expires = create_media_token(user["id"], path)
    return {"url": path + "?media_token=" + token, "expires_at": expires}


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    public_paths = {
        "/",
        "/auth/login",
        "/openapi.json",
        "/docs",
        "/docs/oauth2-redirect",
        "/redoc",
    }
    path = request.url.path

    if request.method == "OPTIONS":
        return await call_next(request)

    if path in public_paths:
        return await call_next(request)

    auth_header = request.headers.get("Authorization", "")
    payload = decode_access_token(auth_header.split(" ", 1)[1]) if auth_header.startswith("Bearer ") else None
    if not payload and request.method in ("GET", "HEAD") and request.query_params.get("media_token"):
        try:
            encoded_path = request.scope.get("raw_path", path.encode()).decode("ascii")
            payload = decode_media_token(request.query_params["media_token"], _media_path(encoded_path))
        except HTTPException:
            pass
    if not payload or "sub" not in payload:
        return Response(status_code=401, content="Unauthorized")

    try:
        user_id = int(payload["sub"])
    except (TypeError, ValueError):
        return Response(status_code=401, content="Unauthorized")

    user = db.get_user_by_id(user_id)
    if not user or not user.get("is_active"):
        return Response(status_code=401, content="Unauthorized")

    request.state.current_user = user
    result = await call_next(request)
    # Private responses must never leak through a shared browser/proxy cache.
    result.headers["Cache-Control"] = "private, no-store"
    result.headers["Referrer-Policy"] = "no-referrer"
    return result


@app.get("/")
def read_root():
    return {"message": "Music Download API", "status": "running"}


@app.post("/auth/login", response_model=LoginResponse)
def login(request: LoginRequest):
    user = db.verify_user_credentials(request.username, request.password)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid username or password")

    token = create_access_token(user_id=user["id"], username=user["username"])
    return {
        "access_token": token,
        "token_type": "bearer",
        "user": {
            "id": user["id"],
            "username": user["username"],
            "tagline": user.get("tagline") or "",
        },
    }


@app.get("/auth/me")
def get_me(request: Request):
    current_user = _require_current_user(request)
    return {
        "id": current_user["id"],
        "username": current_user["username"],
        "tagline": current_user.get("tagline") or "",
    }


@app.get("/library")
def get_saved_library(request: Request):
    user_id = _require_current_user(request)["id"]
    owned = set()
    for filename in db.owned_downloads(user_id):
        try:
            _owned_file(user_id, filename)
            owned.add(filename)
        except HTTPException:
            pass
    library = db.get_saved_library(user_id)
    for kind, items in library.items():
        for item in items:
            if kind == "tracks" and item.get("filename") not in owned:
                item["filename"] = ""
            item["thumbnail"] = clean_thumbnail(
                item.get("thumbnail", ""), lambda filename: filename in owned,
                lambda playlist_id: db.get_playlist(user_id, playlist_id) is not None)
    return library


@app.put("/library/{kind}/{item_id:path}")
def save_library_item(kind: str, item_id: str, metadata: Dict, request: Request):
    user_id = _require_current_user(request)["id"]
    def owns_filename(filename):
        try:
            _owned_file(user_id, filename)
            return True
        except HTTPException:
            return False
    item = normalize_item(kind, item_id, metadata, _download_filename, owns_filename,
                          lambda playlist_id: db.get_playlist(user_id, playlist_id) is not None)
    return db.save_library_item(user_id, kind, item_id, item)


@app.delete("/library/{kind}/{item_id:path}")
def remove_library_item(kind: str, item_id: str, request: Request):
    validate_identity(kind, item_id)
    db.remove_library_item(_require_current_user(request)["id"], kind, item_id)
    return {"success": True}


@app.get("/profile/me")
def get_profile(request: Request):
    current_user = _require_current_user(request)
    profile = db.get_user_profile(current_user["id"])
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")
    return {
        "id": profile["id"],
        "username": profile["username"],
        "tagline": profile.get("tagline") or "",
        "created_at": profile.get("created_at"),
        "follower_count": db.count_followers(profile["id"]),
        "following_count": db.count_following(profile["id"]),
        "public_playlist_count": db.count_public_playlists(profile["id"]),
    }


@app.put("/profile/me")
def update_profile(payload: ProfileUpdateRequest, request: Request):
    current_user = _require_current_user(request)
    username = payload.username.strip()
    if not username:
        raise HTTPException(status_code=400, detail="Username cannot be empty")
    tagline = (payload.tagline or "").strip()
    if len(tagline) > 120:
        raise HTTPException(status_code=400, detail="Tagline must be 120 characters or less")
    try:
        profile = db.update_user_profile(
            user_id=current_user["id"],
            username=username,
            tagline=tagline,
        )
    except ValueError as exc:
        if str(exc) == "username_taken":
            raise HTTPException(status_code=409, detail="Username is already taken")
        raise

    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")

    return {
        "id": profile["id"],
        "username": profile["username"],
        "tagline": profile.get("tagline") or "",
        "created_at": profile.get("created_at"),
    }


@app.post("/search", response_model=List[VideoInfo])
def search_youtube(request: SearchRequest):
    """Search YouTube for videos"""
    try:
        query = search_query(request.query)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    try:
        results = download_service.search_youtube(
            query=query,
            duration_min=request.duration_min,
            duration_max=request.duration_max
        )
        return results
    except Exception as e:
        import traceback
        error_detail = f"{str(e)}\n\nTraceback:\n{traceback.format_exc()}"
        print(f"Search error: {error_detail}")  # Log to console
        raise HTTPException(status_code=500, detail=str(e))


@app.options("/stream/{encoded_url:path}")
async def stream_audio_options(encoded_url: str):
    """Handle CORS preflight requests"""
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Range, Content-Type",
        "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
    }

@app.api_route("/stream/{encoded_url:path}", methods=["GET", "HEAD"])
async def stream_audio(encoded_url: str, request: Request):
    """Stream audio directly from YouTube with range request support"""
    youtube_url = _source_url(unquote(encoded_url))
    client = None
    response = None

    async def close_resources():
        try:
            if response is not None:
                await response.aclose()
        finally:
            if client is not None:
                await client.aclose()

    def stream_from_cached_download(youtube_url: str):
        """Fallback: download browser-compatible audio file and serve it locally."""
        path = stream_cache.acquire(youtube_url, download_service.download_for_streaming)
        try:
            result = audio_file_response(path, request)
            result.background = BackgroundTask(stream_cache.release, path)
            return result
        except Exception:
            stream_cache.release(path)
            raise

    try:
        # Get direct streaming URL from YouTube
        loop = asyncio.get_event_loop()
        stream_url = await loop.run_in_executor(
            None,
            download_service.get_streaming_url,
            youtube_url
        )
        stream_url = streaming_target(stream_url)
        
        # Get range header from request if present
        range_header = request.headers.get("range")
        
        # Build upstream request headers. YouTube is sensitive to missing browser-like headers.
        upstream_headers = {
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://www.youtube.com/",
            "Origin": "https://www.youtube.com",
            # Native players send libmpv/Lavf identifiers, which are not the
            # browser identity used to resolve the YouTube media URL.
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                          "(KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
        }
        if range_header:
            upstream_headers["Range"] = range_header

        client = httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=10.0))
        request_obj = client.build_request(request.method, stream_url, headers=upstream_headers)
        response = await client.send(request_obj, stream=True, follow_redirects=False)

        # Determine content type
        content_type = response.headers.get("Content-Type", "audio/mp4")

        # Build response headers
        response_headers = {
            "Content-Type": content_type,
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "Range, Content-Type",
            "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
        }

        # HTML errors and manifests can arrive with HTTP 200. Passing those
        # bytes to a decoder produces a misleading "wrong format" failure.
        mime_type = content_type.split(";", 1)[0].strip().lower()
        is_audio_payload = mime_type.startswith("audio/") or mime_type in {
            "video/mp4", "video/webm", "application/octet-stream",
        }
        is_manifest = mime_type in {
            "audio/mpegurl", "audio/x-mpegurl", "application/vnd.apple.mpegurl",
            "application/x-mpegurl", "application/dash+xml",
        }
        # Preserve range errors so the client can correct its byte request.
        if response.status_code != 416 and (
            response.status_code >= 300 or not is_audio_payload or is_manifest
        ):
            await close_resources()
            loop = asyncio.get_event_loop()
            return await loop.run_in_executor(None, stream_from_cached_download, youtube_url)

        # Forward byte metadata while streaming the original bytes. Buffering an
        # open-ended range delays playback and can load the entire song into RAM.
        for header in ("Content-Length", "Content-Range", "Content-Encoding"):
            if header in response.headers:
                response_headers[header] = response.headers[header]

        if request.method == "HEAD":
            await close_resources()
            return Response(status_code=response.status_code, headers=response_headers)
        return StreamingResponse(
            response.aiter_raw(),
            status_code=response.status_code,
            headers=response_headers,
            background=BackgroundTask(close_resources),
        )
    except HTTPException:
        await close_resources()
        raise
    except Exception as e:
        await close_resources()
        try:
            # Last-resort fallback for any transient upstream/proxy failures.
            loop = asyncio.get_event_loop()
            return await loop.run_in_executor(None, stream_from_cached_download, youtube_url)
        except Exception:
            import traceback
            print(f"Stream error: {traceback.format_exc()}")
            raise HTTPException(status_code=502, detail="YouTube audio is unavailable. Please try again later.")


@app.post("/download")
def download_audio(request: DownloadRequest, http_request: Request):
    """Download audio from YouTube URL"""
    user = _require_current_user(http_request)
    source = _source_url(request.url)
    chosen = db.get_source_preference(user['id'], recording_key({
        'title': request.title, 'artist': request.artist, 'album': request.album,
        'spotify_id': request.spotify_id, 'recording_type': request.recording_type,
    }))
    if chosen:
        source = _source_url(chosen)
    if request.output_format not in ("m4a", "mp3"):
        raise HTTPException(status_code=400, detail="Unsupported audio format")
    try:
        result = download_service.download_audio(
            url=source,
            title=request.title,
            artist=request.artist,
            album=request.album,
            output_format=request.output_format,
            embed_thumbnail=request.embed_thumbnail,
            owner_id=user["id"],
        )
        db.claim_download(user["id"], _download_filename(result['filename']))
        return {
            "success": True,
            "file_path": result['file_path'],
            "filename": result['filename'],
            "title": result['title'],
            "artist": result['artist'],
            "album": result['album']
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class BatchDownloadRequest(BaseModel):
    downloads: List[DownloadRequest]


@app.post("/downloads/batch")
def start_batch_download(request: BatchDownloadRequest, http_request: Request):
    """Start a batch download with progress tracking"""
    import uuid
    import time
    user = _require_current_user(http_request)
    for entry in request.downloads:
        entry.url = _source_url(entry.url)
        chosen = db.get_source_preference(user['id'], recording_key({
            'title': entry.title, 'artist': entry.artist, 'album': entry.album,
            'spotify_id': entry.spotify_id, 'recording_type': entry.recording_type,
        }))
        if chosen:
            entry.url = _source_url(chosen)
        if entry.output_format not in ("m4a", "mp3"):
            raise HTTPException(status_code=400, detail="Unsupported audio format")
    download_id = str(uuid.uuid4())
    
    # Clean up old progress entries to prevent memory leaks
    cleanup_old_progress()
    
    # Initialize progress tracking with timestamp
    download_progress[download_id] = {
        "user_id": user["id"],
        "current": 0,
        "total": len(request.downloads),
        "status": "downloading",
        "processed": 0,
        "failed": 0,
        "downloads": [],
        "created_at": time.time()
    }
    
    # Start downloads in background
    def download_worker():
        try:
            for idx, download_req in enumerate(request.downloads):
                try:
                    result = download_service.download_audio(
                        url=download_req.url,
                        title=download_req.title,
                        artist=download_req.artist,
                        album=download_req.album,
                        output_format=download_req.output_format,
                        embed_thumbnail=download_req.embed_thumbnail,
                        owner_id=user["id"],
                    )
                    db.claim_download(user["id"], _download_filename(result['filename']))
                    download_progress[download_id]["processed"] += 1
                    download_progress[download_id]["downloads"].append({
                        "success": True,
                        "filename": result['filename'],
                        "title": result['title'],
                        "artist": result['artist']
                    })
                except Exception as e:
                    download_progress[download_id]["failed"] += 1
                    download_progress[download_id]["downloads"].append({
                        "success": False,
                        "title": download_req.title,
                        "error": str(e)
                    })
                
                download_progress[download_id]["current"] = idx + 1
                download_progress[download_id]["status"] = f"Downloading {download_req.title}..."
            
            download_progress[download_id]["status"] = "completed"
        except Exception as e:
            download_progress[download_id]["status"] = f"error: {str(e)}"
    
    import threading
    thread = threading.Thread(target=download_worker, daemon=True)
    thread.start()
    
    return {"download_id": download_id, "total": len(request.downloads)}


@app.get("/downloads/progress/{download_id}")
def get_download_progress(download_id: str, request: Request):
    """Get progress for a batch download"""
    if download_id not in download_progress or download_progress[download_id].get("user_id") != _require_current_user(request)["id"]:
        raise HTTPException(status_code=404, detail="Download progress not found")
    return download_progress[download_id]


@app.get("/downloads")
def list_downloads(request: Request):
    """List all downloaded files (including subdirectories from CSV conversions)"""
    try:
        owned = db.owned_downloads(_require_current_user(request)["id"])
        downloads_dir = download_service.output_dir
        files = []
        if os.path.exists(downloads_dir):
            # Recursively search for audio files
            for root, dirs, filenames in os.walk(downloads_dir):
                # Streaming cache entries are implementation details, not saved music.
                dirs[:] = [directory for directory in dirs if directory != "_stream_cache"]
                for filename in filenames:
                    if filename.lower().endswith(('.mp3', '.m4a')):
                        file_path = os.path.join(root, filename)
                        # Use relative path from downloads_dir for filename to preserve subfolder structure
                        rel_path = os.path.relpath(file_path, downloads_dir)
                        if rel_path.replace('\\', '/') not in owned:
                            continue
                        
                        # Try to read metadata from the file
                        title = None
                        artist = None
                        try:
                            if filename.lower().endswith('.m4a'):
                                audio = MP4(file_path)
                                if audio.tags:
                                    title_tags = audio.tags.get('\xa9nam')
                                    artist_tags = audio.tags.get('\xa9ART')
                                    title = title_tags[0] if title_tags else None
                                    artist = artist_tags[0] if artist_tags else None
                            else:  # MP3
                                try:
                                    audio = EasyID3(file_path)
                                    title = audio.get('title')
                                    title = title[0] if title else None
                                    artist = audio.get('artist')
                                    artist = artist[0] if artist else None
                                except Exception as e:
                                    # MP3 might not have ID3 tags, this is expected
                                    pass
                        except Exception:
                            # If metadata reading fails, continue without it
                            pass
                        
                        files.append({
                            "filename": rel_path.replace('\\', '/'),  # Use forward slashes for consistency
                            "file_path": file_path,
                            "size": os.path.getsize(file_path),
                            "title": title,
                            "artist": artist
                        })
        return {"files": files}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/downloads/{filename:path}")
def delete_download_file(filename: str, request: Request):
    """Delete a downloaded file (supports subdirectory paths) and update playlists"""
    try:
        # Safely validate the path using pathlib
        filename = _raw_download_filename(request, filename)
        user_id = _require_current_user(request)["id"]
        filename = _download_filename(filename)
        file_path = _owned_file(user_id, filename)
        
        if not file_path.is_file():
            raise HTTPException(status_code=404, detail="File not found")
        
        # Delete the file
        remaining_owners = db.unclaim_download(user_id, filename)
        if not remaining_owners:
            os.remove(file_path)
        
        # Update all playlists to clear filename for tracks that reference this file
        db.clear_song_file_references(filename, user_id)
        
        return {"success": True, "message": f"File {filename} deleted successfully"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/downloads/{filename:path}/artwork")
async def get_file_artwork(filename: str, request: Request):
    """Extract album artwork from a downloaded audio file"""
    try:
        # Safely validate the path using pathlib
        filename = _raw_download_filename(request, filename, artwork=True)
        file_path = _owned_file(_require_current_user(request)["id"], filename)
        
        if not file_path.is_file():
            raise HTTPException(status_code=404, detail="File not found")
        
        artwork_data = None
        content_type = "image/jpeg"
        
        try:
            if filename.lower().endswith('.m4a'):
                # Extract artwork from MP4/M4A file
                audio = MP4(file_path)
                if audio.tags and 'covr' in audio.tags:
                    covers = audio.tags['covr']
                    if covers:
                        artwork_data = bytes(covers[0])
                        # Determine content type
                        if isinstance(covers[0], MP4Cover):
                            if covers[0].imageformat == MP4Cover.FORMAT_JPEG:
                                content_type = "image/jpeg"
                            elif covers[0].imageformat == MP4Cover.FORMAT_PNG:
                                content_type = "image/png"
            elif filename.lower().endswith('.mp3'):
                # Extract artwork from MP3 file
                audio = ID3(file_path)
                if audio:
                    # Look for APIC (album art) frames
                    for key in audio.keys():
                        if key.startswith('APIC'):
                            apic = audio[key]
                            if isinstance(apic, APIC):
                                artwork_data = apic.data
                                # Determine content type from mime
                                if apic.mime:
                                    content_type = apic.mime
                                break
        except Exception as e:
            print(f"Error extracting artwork: {e}")
            artwork_data = None
        
        if artwork_data:
            return Response(
                content=artwork_data,
                media_type=content_type,
                headers={
                    "Cache-Control": "public, max-age=31536000",  # Cache for 1 year
                }
            )
        else:
            raise HTTPException(status_code=404, detail="No artwork found in file")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.api_route("/downloads/{filename:path}", methods=["GET", "HEAD"])
def get_download_file(filename: str, request: Request):
    """Serve audio after registering more specific download/artwork routes."""
    filename = _raw_download_filename(request, filename)
    file_path = _owned_file(_require_current_user(request)["id"], filename)
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return audio_file_response(file_path, request)


def _normalize_for_comparison(text: str) -> str:
    """Normalize text for fuzzy comparison by lowercasing and removing punctuation."""
    import re
    if not text:
        return ""
    return re.sub(r'[^\w\s]', '', text.lower()).strip()


def _album_cover_cache_key(title: str, artist: str, album: str) -> str:
    """Generate a stable cache key for album cover lookups."""
    parts = []
    if title:
        parts.append(_normalize_for_comparison(title))
    if artist:
        parts.append(_normalize_for_comparison(artist))
    if album:
        parts.append(_normalize_for_comparison(album))
    return "|".join(parts) if parts else "unknown"


def _parse_youtube_metadata(title: str, uploader: str = "") -> dict:
    """Parse YouTube title + uploader into clean song title and artist.
    
    Handles formats like:
      - "Artist - Song (Official Music Video)"
      - "Song - Artist (Lyrics)"
      - "Artist - Song [Official Audio]"
      - "Song (feat. X) (Official Video)"
      - "Artist - Song (Acoustic Version)"
    
    Uses the uploader/channel name as a hint to determine which side of
    the dash is the artist vs. the song title.
    
    Returns:
        {"title": str, "artist": str}
    """
    import re
    
    raw_title = (title or "").strip()
    raw_uploader = (uploader or "").strip()
    
    # --- Clean uploader ---
    clean_uploader = raw_uploader
    # Strip "VEVO" suffix: "BadOmensVEVO" -> "BadOmens" -> insert spaces before caps
    if clean_uploader.upper().endswith("VEVO"):
        clean_uploader = clean_uploader[:-4]
        # Insert spaces before uppercase letters for CamelCase: "BadOmens" -> "Bad Omens"
        clean_uploader = re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', clean_uploader).strip()
    # Strip "- Topic" suffix (YouTube Music auto-generated channels)
    clean_uploader = re.sub(r'\s*-\s*topic\s*$', '', clean_uploader, flags=re.IGNORECASE).strip()
    # Strip " Official" suffix from channel names
    clean_uploader = re.sub(r'\s+official\s*$', '', clean_uploader, flags=re.IGNORECASE).strip()
    
    # --- Strip YouTube suffixes from title (run repeatedly for stacked suffixes) ---
    yt_noise = re.compile(
        r'\s*[(\[]\s*'
        r'(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s*video|'
        r'official\s+visualizer|lyric\s*video|lyrics?\s*(?:video)?|'
        r'audio|visualizer|music\s+video|'
        r'hd|hq|4k|remastered(?:\s+\d{4})?|'
        r'explicit|clean\s+version|deluxe(?:\s+edition)?|bonus\s+track)'
        r'\s*[)\]]\s*',
        re.IGNORECASE,
    )
    cleaned = raw_title
    prev = None
    while cleaned != prev:
        prev = cleaned
        cleaned = yt_noise.sub(' ', cleaned).strip()
    
    # Also strip trailing standalone labels not in parens/brackets
    cleaned = re.sub(
        r'\s*[-|]\s*(?:official\s+(?:music\s+)?video|official\s+audio|'
        r'lyric\s*video|lyrics?|audio|visualizer|music\s+video)\s*$',
        '', cleaned, flags=re.IGNORECASE
    ).strip()
    
    # Strip trailing pipes/dashes left over
    cleaned = re.sub(r'\s*[-|]+\s*$', '', cleaned).strip()
    
    # --- Split artist and song ---
    song_title = cleaned
    artist = ""
    
    norm_uploader = _normalize_for_comparison(clean_uploader)
    
    if " - " in cleaned:
        left, right = cleaned.split(" - ", 1)
        left, right = left.strip(), right.strip()
        norm_left = _normalize_for_comparison(left)
        norm_right = _normalize_for_comparison(right)
        
        # Use uploader as a hint to figure out which side is the artist
        left_matches_uploader = (
            norm_uploader and (
                norm_left == norm_uploader or
                norm_uploader in norm_left or
                norm_left in norm_uploader
            )
        )
        right_matches_uploader = (
            norm_uploader and (
                norm_right == norm_uploader or
                norm_uploader in norm_right or
                norm_right in norm_uploader
            )
        )
        
        if left_matches_uploader and not right_matches_uploader:
            artist = left
            song_title = right
        elif right_matches_uploader and not left_matches_uploader:
            artist = right
            song_title = left
        else:
            # Standard YouTube convention: "Artist - Song"
            artist = left
            song_title = right
    elif norm_uploader:
        # No dash separator; uploader is artist, title is song
        artist = clean_uploader
        song_title = cleaned
    
    # Final cleanup of song title: strip leftover leading/trailing dashes
    song_title = re.sub(r'^[-–—]\s*', '', song_title).strip()
    song_title = re.sub(r'\s*[-–—]$', '', song_title).strip()
    
    return {"title": song_title, "artist": artist}


@app.get("/clean-metadata")
async def clean_metadata(title: str, uploader: str = "",
                         video_id: str = "", video_url: str = ""):
    """Resolve song metadata from a YouTube title using multi-layered strategy.

    When video_id/video_url are provided, uses yt-dlp structured metadata and
    Spotify validation for higher accuracy. Falls back to regex parsing.
    """
    if video_url:
        video_url = _source_url(video_url)
        actual_id = video_url.rsplit("=", 1)[-1]
        if video_id and video_id != actual_id:
            raise HTTPException(status_code=400, detail="Video ID does not match URL")
        video_id = actual_id
    elif video_id and not VIDEO_ID.fullmatch(video_id):
        raise HTTPException(status_code=400, detail="Invalid YouTube video ID")
    return metadata_service.resolve(
        title=title,
        uploader=uploader,
        video_id=video_id or None,
        video_url=video_url or None,
    )


def _build_search_term(title: str, artist: str, album: str, simplified: bool = False) -> str:
    """Build search term for iTunes. If simplified=True, use shorter form for retry."""
    parsed = _enhanced_regex_parse(title, artist or "")
    clean_title, clean_artist = parsed["title"], parsed["artist"]
    
    if simplified:
        # Aggressive simplification: artist + first 2-3 significant words of title
        words = clean_title.split()[:3] if clean_title else []
        title_part = " ".join(w for w in words if len(w) > 1)
        if clean_artist and title_part:
            return f"{clean_artist} {title_part}"
        if clean_artist:
            return clean_artist
        return title_part or clean_title or title
    
    if album and clean_artist:
        return f"{album} {clean_artist}"
    if clean_artist:
        return f"{clean_title} {clean_artist}"
    return clean_title or title


def _score_itunes_result(result: dict, title: str, artist: str, album: str) -> int:
    """Score an iTunes result based on how well it matches the requested track.
    
    Higher score = better match. Max score is 100.
    """
    score = 0
    
    result_artist = _normalize_for_comparison(result.get("artistName", ""))
    result_track = _normalize_for_comparison(result.get("trackName", ""))
    result_album = _normalize_for_comparison(result.get("collectionName", ""))
    
    norm_title = _normalize_for_comparison(title)
    norm_artist = _normalize_for_comparison(artist)
    norm_album = _normalize_for_comparison(album)
    
    # Artist match (40 points max)
    if norm_artist:
        if result_artist == norm_artist:
            score += 40  # Exact match
        elif norm_artist in result_artist or result_artist in norm_artist:
            score += 30  # Partial match
        elif any(word in result_artist for word in norm_artist.split() if len(word) > 2):
            score += 15  # Word match
    
    # Track name match (30 points max)
    if norm_title:
        if result_track == norm_title:
            score += 30  # Exact match
        elif norm_title in result_track or result_track in norm_title:
            score += 20  # Partial match
        elif any(word in result_track for word in norm_title.split() if len(word) > 2):
            score += 10  # Word match
    
    # Album match (30 points max)
    if norm_album:
        if result_album == norm_album:
            score += 30  # Exact match
        elif norm_album in result_album or result_album in norm_album:
            score += 20  # Partial match
        elif any(word in result_album for word in norm_album.split() if len(word) > 2):
            score += 10  # Word match
    
    return score


@app.get("/album-cover")
async def get_album_cover(title: str, artist: str = "", album: str = ""):
    """Fetch album cover from iTunes API based on track metadata.
    
    Improved version that fetches multiple results and scores them to find
    the best matching album cover. Results are cached for 30 days.
    """
    cache_key = _album_cover_cache_key(title, artist or "", album or "")
    
    # Check cache first
    cached = db.get_album_cover_cache(cache_key)
    if cached is not None:
        return {
            "artwork_url": cached["artwork_url"],
            "match_score": cached.get("match_score", 0),
            "cached": True,
        }
    
    try:
        parsed = _enhanced_regex_parse(title, artist or "")
        clean_title, clean_artist = parsed["title"], parsed["artist"]
        clean_album = album or ""

        async def _do_search(search_term: str):
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(
                    "https://itunes.apple.com/search",
                    params={"term": search_term, "media": "music", "limit": 10},
                )
                if response.status_code != 200:
                    return None, [], 0
                data = response.json()
                results = data.get("results", [])
                scored_results = []
                for result in results:
                    artwork_url = result.get("artworkUrl100", "")
                    if artwork_url:
                        score = _score_itunes_result(result, clean_title, clean_artist, clean_album)
                        scored_results.append((score, artwork_url, result))
                scored_results.sort(key=lambda x: x[0], reverse=True)
                best_score = scored_results[0][0] if scored_results else 0
                return search_term, scored_results, best_score
        
        # First attempt with cleaned search term
        search_term = _build_search_term(title, artist or "", album or "", simplified=False)
        _, scored_results, best_score = await _do_search(search_term)
        
        # Retry with simplified term if no results or no good match (score < 20)
        if (not scored_results or best_score < 20):
            retry_term = _build_search_term(title, artist or "", album or "", simplified=True)
            if retry_term != search_term:
                _, scored_results, best_score = await _do_search(retry_term)
        
        if scored_results:
            best_score, best_artwork_url, best_result = scored_results[0]
            if best_score >= 20:
                artwork_url = best_artwork_url.replace("100x100", "600x600")
                db.set_album_cover_cache(cache_key, artwork_url, best_score)
                return {
                    "artwork_url": artwork_url,
                    "match_score": best_score,
                    "matched_artist": best_result.get("artistName"),
                    "matched_track": best_result.get("trackName"),
                }
            # Low confidence fallback: return result but don't cache (wrong track likely)
            artwork_url = scored_results[0][1].replace("100x100", "600x600")
            return {
                "artwork_url": artwork_url,
                "match_score": best_score,
                "low_confidence": True,
            }
        
        db.set_album_cover_cache(cache_key, None, 0)
        return {"artwork_url": None}
    except Exception as e:
        print(f"Error fetching album cover: {e}")
        return {"artwork_url": None}


# CSV Conversion Endpoints

class CsvConversionRequest(BaseModel):
    duration_min: int = 0
    duration_max: float = 600
    exclude_instrumentals: bool = False
    variants: List[str] = []


@app.post("/csv/upload")
async def upload_csv(request: Request, file: UploadFile = File(...)):
    """Upload a CSV file for conversion"""
    try:
        if not file.filename or not file.filename.lower().endswith('.csv'):
            raise HTTPException(status_code=400, detail="File must be a CSV file")
        
        # Save uploaded file to temp directory
        if file.filename != Path(file.filename.replace("\\", "/")).name:
            raise HTTPException(status_code=400, detail="Invalid CSV filename")
        temp_dir = os.path.join(BASE_DIR, "temp", str(_require_current_user(request)["id"]))
        os.makedirs(temp_dir, exist_ok=True)
        
        file_path = validate_path_safety(temp_dir, file.filename)
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        return {
            "success": True,
            "filename": file.filename,
            "file_path": str(file_path)
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))




def format_playlist_name(csv_filename: str) -> str:
    """Format CSV filename to playlist name: remove .csv, replace underscores with spaces, title case"""
    name = csv_filename.replace('.csv', '').replace('.CSV', '')
    name = name.replace('_', ' ')
    name = name.title()
    return name


@app.post("/csv/convert/{filename}")
def convert_csv_file(filename: str, request: CsvConversionRequest, http_request: Request):
    """Convert a specific CSV file to playlist entries (search only, no download)"""
    import time
    current_user = _require_current_user(http_request)
    progress_key = (current_user["id"], filename)
    try:
        temp_dir = os.path.join(BASE_DIR, "temp", str(current_user["id"]))
        csv_path = validate_path_safety(temp_dir, filename)
        
        if not os.path.isfile(csv_path):
            raise HTTPException(status_code=404, detail="CSV file not found")
        
        # Clean up old progress entries to prevent memory leaks
        cleanup_old_progress()
        
        # Initialize progress tracking for this filename with timestamp
        csv_progress[progress_key] = {
            "current": 0, 
            "total": 0, 
            "status": "", 
            "processed": 0, 
            "not_found": 0,
            "created_at": time.time()
        }
        
        def progress_callback(current, total, status):
            csv_progress[progress_key]["current"] = current
            csv_progress[progress_key]["total"] = total
            csv_progress[progress_key]["status"] = status
            csv_progress[progress_key]["processed"] = current
        
        # Search for tracks without downloading
        result = download_service.convert_csv_to_playlist(
            csv_path=csv_path,
            duration_min=request.duration_min,
            duration_max=request.duration_max,
            exclude_instrumentals=request.exclude_instrumentals,
            variants=request.variants if request.variants else [''],
            progress_callback=progress_callback
        )
        for track in result.get('tracks', []):
            track['url'] = _source_url(track.get('url', ''))
        
        # Create playlist from CSV filename
        playlist_name = format_playlist_name(filename)
        playlist_id = None
        playlist_created = False
        
        try:
            # Create the playlist
            current_user = _require_current_user(http_request)
            playlist = db.create_playlist(
                user_id=current_user["id"],
                name=playlist_name,
                playlist_id=str(uuid.uuid4()),
            )
            playlist_id = playlist["id"]
            playlist_created = True
            
            # Add all found tracks to the playlist (with URLs but no filenames)
            tracks = result.get('tracks', [])
            
            for track_info in tracks:
                song_id = str(uuid.uuid4())
                song = {
                    "id": song_id,
                    "title": track_info.get('title', 'Unknown'),
                    "artist": track_info.get('artist', ''),
                    "album": track_info.get('album', ''),
                    "filename": "",
                    "file_path": "",
                    "url": track_info.get('url', ''),
                    "thumbnail": track_info.get('thumbnail', ''),
                    "duration": track_info.get('duration', 0.0)
                }
                
                # Add song to playlist
                db.add_song_to_playlist(current_user["id"], playlist_id, song)
        except Exception as e:
            print(f"Warning: Could not create playlist: {e}")
            import traceback
            traceback.print_exc()
        
        # Update final progress
        csv_progress[progress_key]["processed"] = result['success_count']
        csv_progress[progress_key]["not_found"] = len(result['not_found'])
        csv_progress[progress_key]["status"] = "completed"
        
        return {
            "success": True,
            "tracks": result.get('tracks', []),
            "not_found": result['not_found'],
            "total": result['total'],
            "success_count": result['success_count'],
            "playlist_id": playlist_id,
            "playlist_name": playlist_name,
            "playlist_created": playlist_created
        }
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        error_detail = f"{str(e)}\n\nTraceback:\n{traceback.format_exc()}"
        print(f"CSV conversion error: {error_detail}")
        # Mark as error in progress
        if progress_key in csv_progress:
            csv_progress[progress_key]["status"] = f"error: {str(e)}"
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/csv/progress/{filename}")
def get_csv_progress(filename: str, request: Request):
    """Get progress for a CSV conversion"""
    progress_key = (_require_current_user(request)["id"], filename)
    if progress_key not in csv_progress:
        raise HTTPException(status_code=404, detail="Progress not found")
    return csv_progress[progress_key]


@app.get("/csv/download/{playlist_name}/{filename}")
def download_csv_converted_file(playlist_name: str, filename: str, request: Request):
    """Download a converted M4A file from CSV conversion"""
    try:
        file_path = _owned_file(_require_current_user(request)["id"], f"{playlist_name}/{filename}")
        if not os.path.isfile(file_path):
            raise HTTPException(status_code=404, detail="File not found")
        
        return audio_file_response(file_path, request)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/csv/files/{playlist_name}")
def list_csv_converted_files(playlist_name: str, request: Request):
    """List all files from a CSV conversion"""
    try:
        owned = db.owned_downloads(_require_current_user(request)["id"])
        playlist_dir = validate_path_safety(download_service.output_dir, playlist_name)
        if not os.path.exists(playlist_dir):
            raise HTTPException(status_code=404, detail="Playlist not found")
        
        files = []
        for filename in os.listdir(playlist_dir):
            if filename.lower().endswith('.m4a') and f"{playlist_name}/{filename}" in owned:
                file_path = os.path.join(playlist_dir, filename)
                files.append({
                    "filename": filename,
                    "file_path": file_path,
                    "size": os.path.getsize(file_path),
                    "download_url": f"/csv/download/{playlist_name}/{filename}"
                })
        
        return {"files": files}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# Playlist Endpoints

@app.get("/playlists", response_model=Dict[str, Playlist])
def get_playlists(request: Request):
    """Get all playlists"""
    current_user = _require_current_user(request)
    return db.get_all_playlists(current_user["id"])


@app.post("/playlists", response_model=Playlist)
def create_playlist(request: CreatePlaylistRequest, http_request: Request):
    """Create a new playlist"""
    current_user = _require_current_user(http_request)
    return db.create_playlist(user_id=current_user["id"], name=request.name, playlist_id=str(uuid.uuid4()))


@app.get("/playlists/{playlist_id}", response_model=Playlist)
def get_playlist(playlist_id: str, request: Request):
    """Get a specific playlist"""
    current_user = _require_current_user(request)
    playlist = db.get_playlist(current_user["id"], playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return playlist


@app.delete("/playlists/{playlist_id}")
def delete_playlist(playlist_id: str, request: Request):
    """Delete a playlist"""
    current_user = _require_current_user(request)
    if db.delete_playlist(current_user["id"], playlist_id):
        return {"success": True}
    raise HTTPException(status_code=404, detail="Playlist not found")


class UpdatePlaylistRequest(BaseModel):
    name: str

@app.put("/playlists/{playlist_id}", response_model=Playlist)
def update_playlist(playlist_id: str, request: UpdatePlaylistRequest, http_request: Request):
    """Update a playlist (e.g. rename)"""
    current_user = _require_current_user(http_request)
    updated = db.update_playlist_name(current_user["id"], playlist_id, request.name)
    if not updated:
        raise HTTPException(status_code=404, detail="Playlist not found")
    playlist = db.get_playlist(current_user["id"], playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return playlist

@app.post("/playlists/{playlist_id}/songs", response_model=Playlist)
def add_song_to_playlist(playlist_id: str, song: AddSongRequest, request: Request):
    """Add a song to a playlist"""
    current_user = _require_current_user(request)
    if song.filename:
        song.filename = _download_filename(song.filename)
        _owned_file(current_user["id"], song.filename)
    if song.url:
        song.url = _source_url(song.url)
    song.thumbnail = clean_thumbnail(song.thumbnail or '',
        lambda filename: db.owns_download(current_user['id'], filename),
        lambda playlist_id: bool(db.get_playlist(current_user['id'], playlist_id)))
    song.file_path = ""
    playlist = db.add_song_to_playlist(current_user["id"], playlist_id, song.model_dump())
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return playlist


@app.delete("/playlists/{playlist_id}/songs/{song_id:path}", response_model=Playlist)
def remove_song_from_playlist(playlist_id: str, song_id: str, request: Request):
    """Remove a song from a playlist"""
    current_user = _require_current_user(request)
    # IDs may contain filename separators or an original source URL. Decode
    # raw_path once so literal percent sequences survive framework routing.
    raw_path = request.scope.get("raw_path")
    if raw_path is not None:
        song_id = unquote(raw_path.decode("ascii").split("/songs/", 1)[1])
    playlist = db.remove_song_from_playlist(current_user["id"], playlist_id, song_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return playlist


class UpdatePlaylistCoverRequest(BaseModel):
    coverImage: Optional[str] = None  # URL or base64 data URI

@app.put("/playlists/{playlist_id}/cover")
def update_playlist_cover(playlist_id: str, request: UpdatePlaylistCoverRequest, http_request: Request):
    """Update playlist cover image (URL or base64 data URI)"""
    current_user = _require_current_user(http_request)
    if not db.update_playlist_cover(current_user["id"], playlist_id, request.coverImage):
        raise HTTPException(status_code=404, detail="Playlist not found")
    return {"success": True, "coverImage": request.coverImage}


@app.post("/playlists/{playlist_id}/cover/upload")
async def upload_playlist_cover(playlist_id: str, request: Request, file: UploadFile = File(...)):
    """Upload a cover image file for a playlist"""
    current_user = _require_current_user(request)
    playlist = db.get_playlist(current_user["id"], playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    # Validate file type
    if not file.content_type or not file.content_type.startswith('image/'):
        raise HTTPException(status_code=400, detail="File must be an image")
    
    # Create covers directory
    covers_dir = os.path.join(BASE_DIR, "covers")
    os.makedirs(covers_dir, exist_ok=True)
    
    # Generate filename
    file_ext = os.path.splitext(file.filename or '')[1] or '.jpg'
    cover_filename = f"{playlist_id}{file_ext}"
    cover_path = os.path.join(covers_dir, cover_filename)
    
    # Save file
    with open(cover_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
    
    # Store relative path or URL
    cover_url = f"/playlists/{playlist_id}/cover"
    
    db.update_playlist_cover(current_user["id"], playlist_id, cover_url)
    
    return {"success": True, "coverImage": cover_url}


def _serve_playlist_cover(playlist: Dict, playlist_id: str):
    """Serve a playlist's locally-uploaded cover file. Shared by the owner and the
    public (friend-viewing) cover endpoints."""
    cover_image = playlist.get("coverImage")
    if not cover_image:
        raise HTTPException(status_code=404, detail="Cover image not found")

    # If it's a local file path
    if cover_image.startswith("/playlists/") and cover_image.endswith("/cover"):
        covers_dir = os.path.join(BASE_DIR, "covers")
        cover_filename = f"{playlist_id}.jpg"
        cover_path = os.path.join(covers_dir, cover_filename)

        # Try different extensions
        for ext in ['.jpg', '.jpeg', '.png', '.gif', '.webp']:
            test_path = os.path.join(covers_dir, f"{playlist_id}{ext}")
            if os.path.exists(test_path):
                cover_path = test_path
                break

        if os.path.exists(cover_path):
            # Determine content type from extension
            ext = os.path.splitext(cover_path)[1].lower()
            content_type = {
                '.jpg': 'image/jpeg',
                '.jpeg': 'image/jpeg',
                '.png': 'image/png',
                '.gif': 'image/gif',
                '.webp': 'image/webp'
            }.get(ext, 'image/jpeg')

            return FileResponse(
                cover_path,
                media_type=content_type,
                headers={
                    "Cache-Control": "public, max-age=31536000",
                }
            )
        else:
            raise HTTPException(status_code=404, detail="Cover image file not found")

    # If it's a URL, redirect or return it
    raise HTTPException(status_code=400, detail="External URL covers not supported via this endpoint")


@app.get("/playlists/{playlist_id}/cover")
def get_playlist_cover(playlist_id: str, request: Request):
    """Get playlist cover image"""
    current_user = _require_current_user(request)
    playlist = db.get_playlist(current_user["id"], playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return _serve_playlist_cover(playlist, playlist_id)


# Friends / social endpoints (one-way follow + public playlists)

class SetVisibilityRequest(BaseModel):
    isPublic: bool


@app.put("/playlists/{playlist_id}/visibility")
def set_playlist_visibility(playlist_id: str, payload: SetVisibilityRequest, request: Request):
    """Toggle whether one of the current user's playlists is publicly visible to followers."""
    current_user = _require_current_user(request)
    if not db.set_playlist_public(current_user["id"], playlist_id, payload.isPublic):
        raise HTTPException(status_code=404, detail="Playlist not found")
    return {"success": True, "isPublic": payload.isPublic}


@app.get("/users/search")
def search_users(request: Request, q: str = ""):
    """Search users by username. Excludes the caller and annotates follow state."""
    current_user = _require_current_user(request)
    query = (q or "").strip()
    if not query:
        return []
    results = db.search_users(query, current_user["id"])
    for user in results:
        user["is_following"] = db.is_following(current_user["id"], user["id"])
    return results


@app.get("/following")
def get_following(request: Request):
    """List the users the current user follows."""
    current_user = _require_current_user(request)
    return db.get_following(current_user["id"])


@app.get("/users/{user_id}")
def get_public_user(user_id: int, request: Request):
    """Public profile for another user."""
    current_user = _require_current_user(request)
    profile = db.get_user_profile(user_id)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found")
    return {
        "id": profile["id"],
        "username": profile["username"],
        "tagline": profile.get("tagline") or "",
        "created_at": profile.get("created_at"),
        "is_following": db.is_following(current_user["id"], user_id),
        "public_playlist_count": db.count_public_playlists(user_id),
        "follower_count": db.count_followers(user_id),
        "following_count": db.count_following(user_id),
    }


@app.get("/users/{user_id}/playlists", response_model=Dict[str, Playlist])
def get_public_user_playlists(user_id: int, request: Request):
    """A user's public playlists (same shape as GET /playlists)."""
    viewer = _require_current_user(request)
    playlists = db.get_public_playlists(user_id)
    for playlist in playlists.values():
        _filter_private_file_references(playlist, viewer["id"])
    return playlists


def _filter_private_file_references(playlist, viewer_id):
    owned = db.owned_downloads(viewer_id)
    for song in playlist.get("songs", []):
        if song.get("filename") not in owned:
            song["filename"] = ""
        song["file_path"] = ""
        try:
            song['thumbnail'] = clean_thumbnail(song.get('thumbnail') or '',
                lambda filename: filename in owned,
                lambda playlist_id: bool(db.get_playlist(viewer_id, playlist_id)))
        except HTTPException:
            # Legacy metadata may contain stale capabilities or invalid URLs.
            song['thumbnail'] = ''
    return playlist


@app.get("/users/{user_id}/playlists/{playlist_id}", response_model=Playlist)
def get_public_user_playlist(user_id: int, playlist_id: str, request: Request):
    """A single public playlist owned by user_id."""
    viewer = _require_current_user(request)
    playlist = db.get_public_playlist(user_id, playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return _filter_private_file_references(playlist, viewer["id"])


@app.get("/users/{user_id}/playlists/{playlist_id}/cover")
def get_public_user_playlist_cover(user_id: int, playlist_id: str, request: Request):
    """Serve a public playlist's cover (only if the playlist is public)."""
    _require_current_user(request)
    playlist = db.get_public_playlist(user_id, playlist_id)
    if not playlist:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return _serve_playlist_cover(playlist, playlist_id)


@app.post("/users/{user_id}/playlists/{playlist_id}/save", response_model=Playlist)
def save_public_playlist(user_id: int, playlist_id: str, request: Request):
    """Clone a friend's public playlist into the current user's own playlists."""
    current_user = _require_current_user(request)
    source = db.get_public_playlist(user_id, playlist_id)
    if not source:
        raise HTTPException(status_code=404, detail="Playlist not found")
    _filter_private_file_references(source, current_user['id'])
    new_playlist = db.create_playlist(
        user_id=current_user["id"],
        name=source["name"],
        playlist_id=str(uuid.uuid4()),
    )
    for song in source.get("songs", []):
        # playlist_songs.id is a global primary key, so a copied song needs a
        # fresh id to avoid colliding with the source playlist's rows.
        song_copy = dict(song)
        song_copy["id"] = uuid.uuid4().hex
        # Public playlist visibility shares metadata; local files remain private.
        if song_copy.get("filename") and not db.owns_download(current_user["id"], song_copy["filename"]):
            song_copy["filename"] = ""
            song_copy["file_path"] = ""
        db.add_song_to_playlist(current_user["id"], new_playlist["id"], song_copy)
    saved = db.get_playlist(current_user["id"], new_playlist["id"])
    return saved


@app.post("/follow/{user_id}")
def follow_user(user_id: int, request: Request):
    """Follow another user (idempotent)."""
    current_user = _require_current_user(request)
    if user_id == current_user["id"]:
        raise HTTPException(status_code=400, detail="Cannot follow yourself")
    if not db.get_user_by_id(user_id):
        raise HTTPException(status_code=404, detail="User not found")
    db.follow_user(current_user["id"], user_id)
    return {"success": True, "is_following": True}


@app.delete("/follow/{user_id}")
def unfollow_user(user_id: int, request: Request):
    """Unfollow another user (idempotent)."""
    current_user = _require_current_user(request)
    db.unfollow_user(current_user["id"], user_id)
    return {"success": True, "is_following": False}


# History & Recommendations Endpoints

@app.post("/history/listening")
def report_listening(metadata: Dict, request: Request):
    user = _require_current_user(request)
    report = validate_report(metadata)
    try:
        row, accepted = db.upsert_listening(user['id'], report)
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from None
    return {'success': True, 'accepted': accepted, 'event_id': row['event_id'],
            'sequence': row['sequence'], 'listened_seconds': row['duration_played'],
            'qualified': bool(row['qualified']), 'closed': bool(row['closed'])}

class HistoryEntry(BaseModel):
    song_title: str
    artist: str
    duration_played: float
    spotify_id: Optional[str] = None

@app.post("/history")
def add_history(entry: HistoryEntry, request: Request):
    """Legacy clients remain compatible; new clients use cumulative events."""
    current_user = _require_current_user(request)
    report = validate_report({'event_id': uuid.uuid4().hex, 'sequence': 1,
        'song_title': entry.song_title, 'artist': entry.artist,
        'listened_seconds': entry.duration_played, 'spotify_id': entry.spotify_id})
    db.add_history(current_user['id'], report['song_title'], report['artist'],
                   report['listened_seconds'], report['spotify_id'] or None)
    return {'success': True, 'spotify_id': report['spotify_id'] or None}


@app.get("/history/recent")
def get_recent_history(request: Request, limit: int = 20):
    current_user = _require_current_user(request)
    safe_limit = max(1, min(limit, 100))
    return db.get_recent_history(current_user["id"], limit=safe_limit)


@app.get("/analytics/recap")
def get_analytics_recap(request: Request, period: str = "weekly"):
    current_user = _require_current_user(request)
    normalized_period = (period or "weekly").strip().lower()
    if normalized_period not in {"weekly", "monthly"}:
        raise HTTPException(status_code=400, detail="period must be weekly or monthly")

    now = datetime.now(timezone.utc)
    start_ts = now - (timedelta(days=7) if normalized_period == "weekly" else timedelta(days=30))
    start_iso = start_ts.isoformat()
    end_iso = now.isoformat()

    summary = db.get_history_summary(current_user["id"], start_iso, end_iso)
    top_artists = db.get_top_artists_in_range(current_user["id"], start_iso, end_iso, limit=5)
    top_tracks = db.get_top_tracks_in_range(current_user["id"], start_iso, end_iso, limit=5)
    top_genres = db.get_cache(f'listening_genres:{current_user["id"]}') or []

    return {
        "period": normalized_period,
        "start_date": start_iso,
        "end_date": end_iso,
        "totals": {
            "plays": summary["plays"],
            "minutes": round(summary["total_duration_played"] / 60.0, 1),
            "unique_artists": summary["unique_artists"],
        },
        "top_artists": top_artists,
        "top_tracks": top_tracks,
        "top_genres": top_genres,
    }

def _recommendation_context(request):
    user_id = _require_current_user(request)['id']
    library = get_saved_library(request)
    preferences = ListeningPreferences(db.get_listening_signals(user_id), library)
    filenames = db.owned_downloads(user_id)

    def owns_filename(filename):
        if filename not in filenames:
            return False
        try:
            _owned_file(user_id, filename)
            return True
        except HTTPException:
            return False

    playlists = db.get_all_playlists(user_id)
    def clean(candidate):
        return safe_track(candidate, owns_filename, lambda playlist_id: playlist_id in playlists)

    local = list(library['tracks'])
    for playlist in playlists.values():
        local.extend(playlist.get('songs', []))
    local.extend(preferences.track_metadata.values())
    # Downloads belong to the library even before a like or playlist is added.
    # Prefer curated metadata when that physical file is already represented.
    represented_files = {candidate.get('filename') for candidate in local if isinstance(candidate, dict)}
    for download in list_downloads(request)['files']:
        filename = download['filename']
        if filename not in represented_files and owns_filename(filename):
            local.append({'id': filename, 'filename': filename,
                          'title': download.get('title') or Path(filename).stem,
                          'artist': download.get('artist') or 'Unknown Artist',
                          'thumbnail': '/downloads/' + quote(filename, safe='/') + '/artwork'})
    local = [track for candidate in local[:5000] if (track := clean(candidate)) is not None]
    return user_id, library, preferences, local, clean


def _recommendation_seeds(user_id, preferences):
    tracks, artists, genre_weights = [], [], {}
    for track in preferences.top_tracks(limit=3):
        spotify_id = track.get('spotify_id')
        info = None
        if not spotify_id:
            info = available(spotify_service.search_track, track['title'], track.get('artist') or 'Unknown')
            if isinstance(info, dict):
                spotify_id = info.get('id')
                artist_key = normalized(info.get('artist') or track.get('artist'))
                if info.get('artist_id'):
                    preferences.artist_metadata.setdefault(artist_key, {'name': info.get('artist') or track.get('artist')})
                    preferences.artist_metadata[artist_key].update(id=info['artist_id'], thumbnail=info.get('thumbnail') or '')
        if spotify_id and spotify_id not in tracks:
            tracks.append(spotify_id)
    for artist in preferences.top_artists(limit=3):
        artist_id = artist.get('id')
        if artist_id and artist_id not in artists:
            artists.append(artist_id)
            for genre in available(spotify_service.get_artist_genres, artist_id):
                if isinstance(genre, str) and len(genre) <= 80:
                    genre_weights[genre] = genre_weights.get(genre, 0) + preferences.artists[normalized(artist['name'])]
    genres = sorted(genre_weights, key=lambda genre: (-genre_weights[genre], genre))[:5]
    db.set_cache(f'listening_genres:{user_id}', genres, ttl_seconds=3600)
    track_seeds, artist_seeds = tracks[:3], artists[:2]
    remaining = max(0, 5 - len(track_seeds) - len(artist_seeds))
    return {'seed_tracks': track_seeds or None, 'seed_artists': artist_seeds or None,
            'seed_genres': genres[:remaining] or None}


def _personalized_tracks(request, limit):
    user_id, library, preferences, local, clean = _recommendation_context(request)
    seeds = _recommendation_seeds(user_id, preferences)
    candidates = available(spotify_service.get_recommendations, **seeds, limit=limit)
    if not candidates and not any(seeds.values()):
        # The track endpoints must never return album-shaped new-release rows.
        candidates = available(spotify_service.get_genre_recommendations, 'pop', limit=limit)
    candidates = [track for candidate in candidates if (track := clean(candidate)) is not None]
    return preferences.rank(candidates + local, limit=limit)


@app.get("/recommendations/daily")
def get_daily_mix(request: Request):
    return _personalized_tracks(request, 20)


@app.get("/recommendations/for-you")
def get_personalized_recommendations(request: Request):
    return _personalized_tracks(request, 30)

@app.get("/recommendations/new-releases")
def get_new_releases(request: Request):
    user_id, library, preferences, local, clean = _recommendation_context(request)
    _recommendation_seeds(user_id, preferences)
    releases = {}
    for artist in preferences.top_artists(limit=5):
        if artist.get('id'):
            for release in available(spotify_service.get_artist_new_releases, artist['id'], limit=5):
                releases.setdefault(release['id'], release)
    if not releases:
        for release in available(spotify_service.get_new_releases, country='US', limit=20):
            releases.setdefault(release['id'], release)
    if not releases:
        for album in library['albums']:
            releases[album['id']] = {**album, 'name': album['title'], 'release_date': ''}
    return sorted(releases.values(), key=lambda item: item.get('release_date') or '', reverse=True)[:20]

@app.get("/recommendations/genre/{genre}")
def get_genre_content(genre: str):
    """Get recommended tracks for a genre (using Spotify's recommendation engine)"""
    try:
        # Use genre recommendations instead of searching for user playlists
        tracks = spotify_service.get_genre_recommendations(genre, limit=30)
        return tracks
    except Exception as e:
        print(f"Error getting genre content: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/genre/{genre}/playlists")
def get_genre_playlists(genre: str):
    """Get user playlists for a genre (legacy - use /genre/{genre} for better results)"""
    try:
        playlists = spotify_service.get_genre_playlists(genre)
        return playlists
    except Exception as e:
        print(f"Error getting genre playlists: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/browse/new-releases")
def get_browse_new_releases(country: str = "US"):
    """Get new album releases from Spotify"""
    try:
        releases = spotify_service.get_new_releases(country=country, limit=20)
        return releases
    except Exception as e:
        print(f"Error getting new releases: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/genres")
def get_available_genres():
    """Get list of available genre seeds for recommendations"""
    try:
        genres = spotify_service.get_available_genre_seeds()
        return {"genres": genres}
    except Exception as e:
        print(f"Error getting available genres: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/playlist/{playlist_id}")
def get_spotify_playlist_tracks(playlist_id: str):
    """Get tracks from a Spotify playlist"""
    try:
        tracks = spotify_service.get_playlist_tracks(playlist_id)
        return tracks
    except SpotifyCatalogError:
        raise HTTPException(status_code=503, detail='Playlist tracks are temporarily unavailable. Please try again.') from None
    except Exception as e:
        print(f"Error getting playlist tracks: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/recommendations/album/{album_id}/tracks")
def get_album_tracks(album_id: str):
    """Get tracks from a Spotify album"""
    try:
        tracks = spotify_service.get_album_tracks(album_id)
        return tracks
    except SpotifyCatalogError:
        raise HTTPException(status_code=503, detail='Album tracks are temporarily unavailable. Please try again.') from None
    except Exception as e:
        print(f"Error getting album tracks: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# Spotify-style Home Shelves

@app.get("/recommendations/mixes")
def get_made_for_you_mixes(request: Request):
    user_id, library, preferences, local, clean = _recommendation_context(request)
    _recommendation_seeds(user_id, preferences)
    genres = db.get_cache(f'listening_genres:{user_id}') or ['pop', 'hip-hop', 'rock', 'electronic']
    mixes = []
    for genre in genres[:4]:
        tracks = [track for raw in available(spotify_service.get_genre_recommendations, genre, limit=15)
                  if (track := clean(raw)) is not None]
        if tracks:
            mixes.append({'id': f'mix_{genre.lower().replace(" ", "-")}', 'title': f'{genre.title()} Mix',
                          'genre': genre, 'tracks': preferences.rank(tracks, limit=15)})
    if not mixes and local:
        mixes.append({'id': 'mix_library', 'title': 'Your Rotation', 'genre': 'library',
                      'tracks': preferences.rank(local, limit=15)})
    return mixes


@app.get("/recommendations/curated")
def get_curated_playlists_endpoint(request: Request):
    """A row of curated/themed playlists (featured-playlists API is deprecated)."""
    try:
        _require_current_user(request)
        queries = [
            "today's top hits", "viral hits", "new music friday",
            "rap caviar", "rock classics", "all out 2010s",
            "mega hits", "pop rising", "indie chill",
        ]
        return spotify_service.get_curated_playlists(queries, limit=15)
    except Exception as e:
        print(f"Error getting curated playlists: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/recommendations/moods")
def get_mood_categories(request: Request):
    """List of mood/activity categories rendered as gradient cards."""
    try:
        _require_current_user(request)
        return [{"mood": m, "title": m} for m in spotify_service.get_moods()]
    except Exception as e:
        print(f"Error getting moods: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/recommendations/mood/{mood}/playlists")
def get_mood_playlists_endpoint(mood: str):
    """Playlists for a given mood/activity."""
    try:
        return spotify_service.get_mood_playlists(mood, limit=20)
    except Exception as e:
        print(f"Error getting mood playlists: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/recommendations/because-you-listened")
def get_because_you_listened(request: Request):
    user_id, library, preferences, local, clean = _recommendation_context(request)
    _recommendation_seeds(user_id, preferences)
    rows, seen = [], set()
    for artist in preferences.top_artists(limit=3):
        artist_id, name = artist.get('id') or '', artist['name']
        raw = available(spotify_service.get_recommendations, seed_artists=[artist_id], limit=15) if artist_id else []
        candidates = [track for candidate in raw if (track := clean(candidate)) is not None]
        candidates.extend(track for track in local if normalized(track.get('artist')) == normalized(name))
        tracks = []
        for track in preferences.rank(candidates, limit=15):
            key = (normalized(track['title']), normalized(track['artist']))
            if key not in seen:
                seen.add(key)
                tracks.append(track)
        if tracks:
            rows.append({'seed_artist_id': artist_id, 'seed_artist_name': name,
                         'title': f'Because you enjoy {name}', 'tracks': tracks})
        if len(rows) >= 2:
            break
    return rows


@app.get("/recommendations/artists")
def get_recommended_artists_endpoint(request: Request):
    user_id, library, preferences, local, clean = _recommendation_context(request)
    seeds = _recommendation_seeds(user_id, preferences)
    candidates = available(spotify_service.get_recommended_artists, seed_artist_ids=seeds['seed_artists'],
                           fallback_query=None if seeds['seed_artists'] else 'pop', limit=15)
    candidates += library['artists']
    artists = {}
    for artist in candidates:
        if not isinstance(artist, dict) or not artist.get('name'):
            continue
        safe = clean({**artist, 'title': artist['name']})
        if safe:
            artists.setdefault(normalized(safe['title']), {'id': safe['id'], 'name': safe['title'], 'thumbnail': safe['thumbnail']})
    return sorted(artists.values(), key=lambda artist: (-preferences.artists[normalized(artist['name'])], normalized(artist['name'])))[:15]


# Album & Artist detail endpoints

@app.get("/album/{album_id}")
def get_album_metadata(album_id: str):
    """Get album metadata for the album detail screen (tracks via /recommendations/album/{id}/tracks)."""
    try:
        album = spotify_service.get_album(album_id)
        if not album:
            raise HTTPException(status_code=404, detail="Album not found")
        return album
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error getting album metadata: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/artist/{artist_id}")
def get_artist_profile(artist_id: str):
    """Get an artist profile (name, image, genres, followers)."""
    try:
        artist = spotify_service.get_artist(artist_id)
        if not artist:
            raise HTTPException(status_code=404, detail="Artist not found")
        return artist
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error getting artist profile: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/artist/{artist_id}/top-tracks")
def get_artist_top_tracks_endpoint(artist_id: str):
    """Get an artist's top tracks."""
    try:
        return spotify_service.get_artist_top_tracks(artist_id, limit=10)
    except Exception as e:
        print(f"Error getting artist top tracks: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/artist/{artist_id}/albums")
def get_artist_albums_endpoint(artist_id: str):
    """Get an artist's albums and singles."""
    try:
        return spotify_service.get_artist_albums(artist_id, limit=20)
    except SpotifyCatalogError:
        raise HTTPException(status_code=503, detail='Artist releases are temporarily unavailable. Please try again.') from None
    except Exception as e:
        print(f"Error getting artist albums: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/artist/{artist_id}/related")
def get_artist_related_endpoint(artist_id: str):
    """Get artists related to a given artist ('Fans also like')."""
    try:
        return spotify_service.get_related_artists(artist_id, limit=12)
    except Exception as e:
        print(f"Error getting related artists: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# Lyrics Endpoints

@app.get("/lyrics")
def get_lyrics(track_name: str, artist_name: str = "", 
               album_name: str = "", duration: Optional[int] = None):
    """Get lyrics for a song from LRCLIB"""
    try:
        if not track_name or not artist_name:
            raise HTTPException(status_code=400, detail="track_name and artist_name are required")
        
        lyrics = lyrics_service.get_lyrics(
            track_name=track_name,
            artist_name=artist_name,
            album_name=album_name or "",
            duration=duration
        )
        
        if lyrics:
            return lyrics
        else:
            raise HTTPException(status_code=404, detail="Lyrics not found")
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error getting lyrics: {e}")
        raise HTTPException(status_code=500, detail=str(e))


app.include_router(build_search_router(
    database=lambda: db, spotify=lambda: spotify_service, downloads=lambda: download_service,
    current_user=_require_current_user, saved_library=get_saved_library, list_downloads=list_downloads,
))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
