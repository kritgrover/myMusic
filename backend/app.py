from fastapi import FastAPI, HTTPException, Request, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse, Response
from pydantic import BaseModel
from typing import List, Optional, Dict
import os
import json
import uuid
import shutil
import asyncio
from datetime import datetime
from pathlib import Path
import httpx
from download_service import DownloadService
from database import db
from spotify_service import spotify_service
from lyrics_service import lyrics_service
from mutagen.mp4 import MP4
from mutagen.easyid3 import EasyID3
from mutagen.id3 import ID3, APIC
from mutagen.mp4 import MP4Cover


def validate_path_safety(base_dir: str, requested_path: str) -> Path:
    """
    Safely validate that a requested path is within the base directory.
    Prevents path traversal attacks.
    
    Args:
        base_dir: The base directory that paths must be within
        requested_path: The user-requested path/filename
        
    Returns:
        The resolved safe path
        
    Raises:
        HTTPException: If the path is unsafe or attempts traversal
    """
    try:
        base = Path(base_dir).resolve()
        # Normalize path separators and join
        requested = (base / requested_path.replace('\\', '/').replace('//', '/')).resolve()
        
        # Verify the resolved path is within the base directory
        if not str(requested).startswith(str(base)):
            raise HTTPException(status_code=400, detail="Invalid file path: path traversal detected")
        
        return requested
    except Exception as e:
        if isinstance(e, HTTPException):
            raise
        raise HTTPException(status_code=400, detail=f"Invalid file path: {str(e)}")

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
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],  # Explicitly list allowed methods
    allow_headers=["Content-Type", "Authorization", "Range", "Accept"],  # Only needed headers
    expose_headers=["Content-Length", "Content-Range", "Accept-Ranges"],  # For streaming support
)

# Initialize download service
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOADS_DIR = os.path.join(BASE_DIR, "downloads")
PLAYLISTS_FILE = os.path.join(BASE_DIR, "playlists.json")
os.makedirs(DOWNLOADS_DIR, exist_ok=True)

download_service = DownloadService(output_dir=DOWNLOADS_DIR)

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


# Helper functions for playlists
def load_playlists() -> Dict:
    if os.path.exists(PLAYLISTS_FILE):
        try:
            with open(PLAYLISTS_FILE, 'r') as f:
                return json.load(f)
        except json.JSONDecodeError as e:
            print(f"Warning: Playlists file is corrupted: {e}. Starting fresh.")
            return {}
        except PermissionError as e:
            print(f"Error: Cannot read playlists file - permission denied: {e}")
            return {}
        except Exception as e:
            print(f"Error loading playlists: {e}")
            return {}
    return {}

def save_playlists(playlists_data: Dict):
    with open(PLAYLISTS_FILE, 'w') as f:
        json.dump(playlists_data, f, indent=4)


@app.get("/")
def read_root():
    return {"message": "Music Download API", "status": "running"}


@app.post("/search", response_model=List[VideoInfo])
def search_youtube(request: SearchRequest):
    """Search YouTube for videos"""
    try:
        results = download_service.search_youtube(
            query=request.query,
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

@app.get("/stream/{encoded_url:path}")
async def stream_audio(encoded_url: str, request: Request):
    """Stream audio directly from YouTube with range request support"""
    try:
        # Decode the URL
        import urllib.parse
        youtube_url = urllib.parse.unquote(encoded_url)
        
        # Get direct streaming URL from YouTube
        loop = asyncio.get_event_loop()
        stream_url = await loop.run_in_executor(
            None,
            download_service.get_streaming_url,
            youtube_url
        )
        
        # Get range header from request if present
        range_header = request.headers.get("range")
        
        # Proxy the stream with range request support
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=10.0)) as client:
            headers = {}
            if range_header:
                headers["Range"] = range_header
            
            # Make request to YouTube's streaming URL
            async with client.stream("GET", stream_url, headers=headers, follow_redirects=True) as response:
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
                
                # Check if it is a range request
                is_range_request = range_header is not None and response.status_code == 206
                
                if is_range_request:
                    # Read all bytes from the range response
                    content_bytes = b""
                    async for chunk in response.aiter_bytes():
                        content_bytes += chunk
                    
                    # Copy Content-Range
                    if "Content-Range" in response.headers:
                        response_headers["Content-Range"] = response.headers["Content-Range"]
                    
                    # Set Content-Length to actual bytes read
                    response_headers["Content-Length"] = str(len(content_bytes))
                    
                    # Return the response with the content bytes
                    return Response(
                        content=content_bytes,
                        status_code=206,
                        headers=response_headers,
                        media_type=content_type,
                    )
                else:
                    # For full requests (200), use chunked encoding
                    async def generate_full():
                        try:
                            async for chunk in response.aiter_bytes():
                                yield chunk
                        except Exception as e:
                            print(f"Error streaming full: {e}")
                            raise
                    
                    return StreamingResponse(
                        generate_full(),
                        status_code=response.status_code,
                        headers=response_headers,
                    )
    except Exception as e:
        import traceback
        print(f"Stream error: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/download")
def download_audio(request: DownloadRequest):
    """Download audio from YouTube URL"""
    try:
        result = download_service.download_audio(
            url=request.url,
            title=request.title,
            artist=request.artist,
            album=request.album,
            output_format=request.output_format,
            embed_thumbnail=request.embed_thumbnail
        )
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
def start_batch_download(request: BatchDownloadRequest):
    """Start a batch download with progress tracking"""
    import uuid
    import time
    download_id = str(uuid.uuid4())
    
    # Clean up old progress entries to prevent memory leaks
    cleanup_old_progress()
    
    # Initialize progress tracking with timestamp
    download_progress[download_id] = {
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
                        embed_thumbnail=download_req.embed_thumbnail
                    )
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
def get_download_progress(download_id: str):
    """Get progress for a batch download"""
    if download_id not in download_progress:
        raise HTTPException(status_code=404, detail="Download progress not found")
    return download_progress[download_id]


@app.get("/downloads")
def list_downloads():
    """List all downloaded files (including subdirectories from CSV conversions)"""
    try:
        downloads_dir = download_service.output_dir
        files = []
        if os.path.exists(downloads_dir):
            # Recursively search for audio files
            for root, dirs, filenames in os.walk(downloads_dir):
                for filename in filenames:
                    if filename.lower().endswith(('.mp3', '.m4a')):
                        file_path = os.path.join(root, filename)
                        # Use relative path from downloads_dir for filename to preserve subfolder structure
                        rel_path = os.path.relpath(file_path, downloads_dir)
                        
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


@app.get("/downloads/{filename:path}")
def get_download_file(filename: str, request: Request):
    """Serve download file for streaming with Range request support"""
    # Safely validate the path using pathlib
    file_path = validate_path_safety(download_service.output_dir, filename)
    
    if not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    
    # Get just the filename for the download (without subdirectory)
    download_filename = os.path.basename(filename)
    
    # FileResponse automatically handles Range requests
    return FileResponse(
        file_path,
        media_type='audio/mpeg' if filename.endswith('.mp3') else 'audio/mp4',
        filename=download_filename,
        headers={
            "Accept-Ranges": "bytes",
        }
    )


@app.delete("/downloads/{filename:path}")
def delete_download_file(filename: str):
    """Delete a downloaded file (supports subdirectory paths) and update playlists"""
    try:
        # Safely validate the path using pathlib
        file_path = validate_path_safety(download_service.output_dir, filename)
        
        if not file_path.is_file():
            raise HTTPException(status_code=404, detail="File not found")
        
        # Delete the file
        os.remove(file_path)
        
        # Update all playlists to clear filename for tracks that reference this file
        normalized_deleted_filename = filename.replace('\\', '/')
        playlists = load_playlists()
        playlists_updated = False
        
        for playlist_id, playlist_data in playlists.items():
            songs_updated = False
            for song in playlist_data.get("songs", []):
                song_filename = song.get("filename", "")
                if song_filename:
                    # Normalize the song filename for comparison
                    normalized_song_filename = song_filename.replace('\\', '/')
                    # Check if filenames match
                    if normalized_song_filename == normalized_deleted_filename or \
                       normalized_song_filename.endswith('/' + normalized_deleted_filename) or \
                       normalized_song_filename == os.path.basename(normalized_deleted_filename):
                        song["filename"] = ""
                        song["file_path"] = ""
                        songs_updated = True
            
            if songs_updated:
                playlist_data["updatedAt"] = datetime.now().isoformat()
                playlists_updated = True
        
        if playlists_updated:
            save_playlists(playlists)
        
        return {"success": True, "message": f"File {filename} deleted successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/downloads/{filename:path}/artwork")
async def get_file_artwork(filename: str):
    """Extract album artwork from a downloaded audio file"""
    try:
        # Safely validate the path using pathlib
        file_path = validate_path_safety(download_service.output_dir, filename)
        
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


def _normalize_for_comparison(text: str) -> str:
    """Normalize text for fuzzy comparison by lowercasing and removing punctuation."""
    import re
    if not text:
        return ""
    return re.sub(r'[^\w\s]', '', text.lower()).strip()


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
    the best matching album cover.
    """
    try:
        # Build search query - prefer album if available, otherwise use title + artist
        if album and artist:
            search_term = f"{album} {artist}"
        elif artist:
            search_term = f"{title} {artist}"
        else:
            search_term = title
        
        # Search iTunes API with more results for better matching
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(
                "https://itunes.apple.com/search",
                params={
                    "term": search_term,
                    "media": "music",
                    "limit": 10,  # Get more results for better matching
                }
            )
            
            if response.status_code == 200:
                data = response.json()
                results = data.get("results", [])
                
                if results:
                    # Score each result and find the best match
                    scored_results = []
                    for result in results:
                        artwork_url = result.get("artworkUrl100", "")
                        if artwork_url:
                            score = _score_itunes_result(result, title, artist, album)
                            scored_results.append((score, artwork_url, result))
                    
                    if scored_results:
                        # Sort by score (highest first) and get best match
                        scored_results.sort(key=lambda x: x[0], reverse=True)
                        best_score, best_artwork_url, best_result = scored_results[0]
                        
                        # Only use result if it has a reasonable score (at least 20)
                        if best_score >= 20:
                            # Replace with higher resolution (600x600 is max)
                            artwork_url = best_artwork_url.replace("100x100", "600x600")
                            return {
                                "artwork_url": artwork_url,
                                "match_score": best_score,
                                "matched_artist": best_result.get("artistName"),
                                "matched_track": best_result.get("trackName"),
                            }
                        
                        # If no good match, still return the first result but with low confidence
                        artwork_url = results[0].get("artworkUrl100", "").replace("100x100", "600x600")
                        if artwork_url:
                            return {
                                "artwork_url": artwork_url,
                                "match_score": best_score,
                                "low_confidence": True
                            }
            
            # If no results, return None
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
async def upload_csv(file: UploadFile = File(...)):
    """Upload a CSV file for conversion"""
    try:
        if not file.filename.endswith('.csv'):
            raise HTTPException(status_code=400, detail="File must be a CSV file")
        
        # Save uploaded file to temp directory
        temp_dir = os.path.join(BASE_DIR, "temp")
        os.makedirs(temp_dir, exist_ok=True)
        
        file_path = os.path.join(temp_dir, file.filename)
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        return {
            "success": True,
            "filename": file.filename,
            "file_path": file_path
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))




def format_playlist_name(csv_filename: str) -> str:
    """Format CSV filename to playlist name: remove .csv, replace underscores with spaces, title case"""
    name = csv_filename.replace('.csv', '').replace('.CSV', '')
    name = name.replace('_', ' ')
    name = name.title()
    return name


@app.post("/csv/convert/{filename}")
def convert_csv_file(filename: str, request: CsvConversionRequest):
    """Convert a specific CSV file to playlist entries (search only, no download)"""
    import time
    try:
        temp_dir = os.path.join(BASE_DIR, "temp")
        csv_path = os.path.join(temp_dir, filename)
        
        if not os.path.isfile(csv_path):
            raise HTTPException(status_code=404, detail="CSV file not found")
        
        # Clean up old progress entries to prevent memory leaks
        cleanup_old_progress()
        
        # Initialize progress tracking for this filename with timestamp
        csv_progress[filename] = {
            "current": 0, 
            "total": 0, 
            "status": "", 
            "processed": 0, 
            "not_found": 0,
            "created_at": time.time()
        }
        
        def progress_callback(current, total, status):
            csv_progress[filename]["current"] = current
            csv_progress[filename]["total"] = total
            csv_progress[filename]["status"] = status
            csv_progress[filename]["processed"] = current
        
        # Search for tracks without downloading
        result = download_service.convert_csv_to_playlist(
            csv_path=csv_path,
            duration_min=request.duration_min,
            duration_max=request.duration_max,
            exclude_instrumentals=request.exclude_instrumentals,
            variants=request.variants if request.variants else [''],
            progress_callback=progress_callback
        )
        
        # Create playlist from CSV filename
        playlist_name = format_playlist_name(filename)
        playlist_id = None
        playlist_created = False
        
        try:
            # Create the playlist
            playlists = load_playlists()
            playlist_id = str(uuid.uuid4())
            now = datetime.now().isoformat()
            new_playlist = {
                "id": playlist_id,
                "name": playlist_name,
                "songs": [],
                "createdAt": now,
                "updatedAt": now,
                "coverImage": None
            }
            playlists[playlist_id] = new_playlist
            save_playlists(playlists)
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
                playlists[playlist_id]["songs"].append(song)
            
            # Update playlist timestamp
            playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()
            save_playlists(playlists)
        except Exception as e:
            print(f"Warning: Could not create playlist: {e}")
            import traceback
            traceback.print_exc()
        
        # Update final progress
        csv_progress[filename]["processed"] = result['success_count']
        csv_progress[filename]["not_found"] = len(result['not_found'])
        csv_progress[filename]["status"] = "completed"
        
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
    except Exception as e:
        import traceback
        error_detail = f"{str(e)}\n\nTraceback:\n{traceback.format_exc()}"
        print(f"CSV conversion error: {error_detail}")
        # Mark as error in progress
        if filename in csv_progress:
            csv_progress[filename]["status"] = f"error: {str(e)}"
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/csv/progress/{filename}")
def get_csv_progress(filename: str):
    """Get progress for a CSV conversion"""
    if filename not in csv_progress:
        raise HTTPException(status_code=404, detail="Progress not found")
    return csv_progress[filename]


@app.get("/csv/download/{playlist_name}/{filename}")
def download_csv_converted_file(playlist_name: str, filename: str):
    """Download a converted M4A file from CSV conversion"""
    try:
        file_path = os.path.join(download_service.output_dir, playlist_name, filename)
        if not os.path.isfile(file_path):
            raise HTTPException(status_code=404, detail="File not found")
        
        return FileResponse(
            file_path,
            media_type='audio/mp4',
            filename=filename,
            headers={
                "Accept-Ranges": "bytes",
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/csv/files/{playlist_name}")
def list_csv_converted_files(playlist_name: str):
    """List all files from a CSV conversion"""
    try:
        playlist_dir = os.path.join(download_service.output_dir, playlist_name)
        if not os.path.exists(playlist_dir):
            raise HTTPException(status_code=404, detail="Playlist not found")
        
        files = []
        for filename in os.listdir(playlist_dir):
            if filename.lower().endswith('.m4a'):
                file_path = os.path.join(playlist_dir, filename)
                files.append({
                    "filename": filename,
                    "file_path": file_path,
                    "size": os.path.getsize(file_path),
                    "download_url": f"/csv/download/{playlist_name}/{filename}"
                })
        
        return {"files": files}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# Playlist Endpoints

@app.get("/playlists", response_model=Dict[str, Playlist])
def get_playlists():
    """Get all playlists"""
    return load_playlists()


@app.post("/playlists", response_model=Playlist)
def create_playlist(request: CreatePlaylistRequest):
    """Create a new playlist"""
    playlists = load_playlists()
    playlist_id = str(uuid.uuid4())
    now = datetime.now().isoformat()
    new_playlist = {
        "id": playlist_id,
        "name": request.name,
        "songs": [],
        "createdAt": now,
        "updatedAt": now,
        "coverImage": None
    }
    playlists[playlist_id] = new_playlist
    save_playlists(playlists)
    return new_playlist


@app.get("/playlists/{playlist_id}", response_model=Playlist)
def get_playlist(playlist_id: str):
    """Get a specific playlist"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    return playlists[playlist_id]


@app.delete("/playlists/{playlist_id}")
def delete_playlist(playlist_id: str):
    """Delete a playlist"""
    playlists = load_playlists()
    if playlist_id in playlists:
        del playlists[playlist_id]
        save_playlists(playlists)
        return {"success": True}
    raise HTTPException(status_code=404, detail="Playlist not found")


class UpdatePlaylistRequest(BaseModel):
    name: str

@app.put("/playlists/{playlist_id}", response_model=Playlist)
def update_playlist(playlist_id: str, request: UpdatePlaylistRequest):
    """Update a playlist (e.g. rename)"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    playlists[playlist_id]["name"] = request.name
    playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()
    save_playlists(playlists)
    return playlists[playlist_id]

@app.post("/playlists/{playlist_id}/songs", response_model=Playlist)
def add_song_to_playlist(playlist_id: str, song: AddSongRequest):
    """Add a song to a playlist"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    # Check if song already exists in playlist
    for existing_song in playlists[playlist_id]["songs"]:
        if existing_song.get("id") == song.id:
             return playlists[playlist_id]
        # Also check filename if it's a downloaded file
        if song.filename and existing_song.get("filename") == song.filename:
             return playlists[playlist_id]

    playlists[playlist_id]["songs"].append(song.model_dump())
    playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()
    save_playlists(playlists)
    return playlists[playlist_id]


@app.delete("/playlists/{playlist_id}/songs/{song_id}", response_model=Playlist)
def remove_song_from_playlist(playlist_id: str, song_id: str):
    """Remove a song from a playlist"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    initial_count = len(playlists[playlist_id]["songs"])
    playlists[playlist_id]["songs"] = [
        s for s in playlists[playlist_id]["songs"] 
        if s["id"] != song_id
    ]
    
    if len(playlists[playlist_id]["songs"]) != initial_count:
        playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()

    save_playlists(playlists)
    return playlists[playlist_id]


class UpdatePlaylistCoverRequest(BaseModel):
    coverImage: Optional[str] = None  # URL or base64 data URI

@app.put("/playlists/{playlist_id}/cover")
def update_playlist_cover(playlist_id: str, request: UpdatePlaylistCoverRequest):
    """Update playlist cover image (URL or base64 data URI)"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    playlists[playlist_id]["coverImage"] = request.coverImage
    playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()
    save_playlists(playlists)
    return {"success": True, "coverImage": request.coverImage}


@app.post("/playlists/{playlist_id}/cover/upload")
async def upload_playlist_cover(playlist_id: str, file: UploadFile = File(...)):
    """Upload a cover image file for a playlist"""
    playlists = load_playlists()
    if playlist_id not in playlists:
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
    
    playlists[playlist_id]["coverImage"] = cover_url
    playlists[playlist_id]["updatedAt"] = datetime.now().isoformat()
    save_playlists(playlists)
    
    return {"success": True, "coverImage": cover_url}


@app.get("/playlists/{playlist_id}/cover")
def get_playlist_cover(playlist_id: str):
    """Get playlist cover image"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    cover_image = playlists[playlist_id].get("coverImage")
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


# History & Recommendations Endpoints

class HistoryEntry(BaseModel):
    song_title: str
    artist: str
    duration_played: float
    spotify_id: Optional[str] = None

@app.post("/history")
def add_history(entry: HistoryEntry):
    """Log a song play to history and track genre preferences"""
    try:
        artist_id = None
        
        # If no spotify_id provided, try to find it
        if not entry.spotify_id:
            track_info = spotify_service.search_track(entry.song_title, entry.artist)
            if track_info:
                entry.spotify_id = track_info['id']
                artist_id = track_info.get('artist_id')
        
        db.add_history(
            entry.song_title, 
            entry.artist, 
            entry.duration_played, 
            entry.spotify_id
        )
        
        # Track genre preferences for better recommendations
        if artist_id:
            genres = spotify_service.get_artist_genres(artist_id)
            if genres:
                db.increment_genres(genres)
        
        return {"success": True, "spotify_id": entry.spotify_id}
    except Exception as e:
        print(f"Error adding history: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/daily")
def get_daily_mix():
    """Get personalized song recommendations based on history and genre preferences"""
    try:
        # Get recent history for seeding
        recent = db.get_recent_history(limit=5)
        
        seed_tracks = []
        
        for item in recent:
            if item['spotify_id']:
                seed_tracks.append(item['spotify_id'])
            else:
                # If no spotify_id in history, try to find one
                track_info = spotify_service.search_track(item['song_title'], item['artist'])
                if track_info:
                    seed_tracks.append(track_info['id'])
        
        # Get user's top genres for better personalization
        top_genres = db.get_top_genres(limit=2)
        
        # Get recommendations with tracks + genres (much better than random playlists!)
        recommendations = spotify_service.get_recommendations(
            seed_tracks=seed_tracks[:3] if seed_tracks else None,
            seed_genres=top_genres if top_genres else None,
            limit=20
        )
        
        return recommendations
    except Exception as e:
        print(f"Error getting recommendations: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/for-you")
def get_personalized_recommendations():
    """Smart recommendations based on user's genre preferences + listening history"""
    try:
        # Get user's top genres
        top_genres = db.get_top_genres(limit=3)
        
        # Get recent track seeds
        recent = db.get_recent_history(limit=5)
        seed_tracks = [r['spotify_id'] for r in recent if r.get('spotify_id')][:2]
        
        # If user has no history, return trending/popular
        if not top_genres and not seed_tracks:
            return spotify_service.get_new_releases(limit=20)
        
        # Combine genre + track seeds (max 5 total for Spotify API)
        recommendations = spotify_service.get_recommendations(
            seed_tracks=seed_tracks if seed_tracks else None,
            seed_genres=top_genres[:3] if top_genres else None,
            limit=30
        )
        
        return recommendations
    except Exception as e:
        print(f"Error getting personalized recommendations: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/recommendations/new-releases")
def get_new_releases():
    """Get new releases from top artists in history"""
    try:
        top_artists = db.get_top_artists(limit=5)
        all_releases = []
        
        for artist in top_artists:
            # Search for artist ID first
            # We use a trick: search for a track by this artist to get artist ID
            track_info = spotify_service.search_track("", artist['artist'])
            if track_info:
                releases = spotify_service.get_artist_new_releases(track_info['artist_id'], limit=3)
                all_releases.extend(releases)
        
        # Sort by release date descending
        all_releases.sort(key=lambda x: x['release_date'], reverse=True)
        return all_releases[:20]
    except Exception as e:
        print(f"Error getting new releases: {e}")
        raise HTTPException(status_code=500, detail=str(e))

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
    except Exception as e:
        print(f"Error getting playlist tracks: {e}")
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
