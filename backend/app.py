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
import httpx
from download_service import DownloadService
from mutagen.mp4 import MP4
from mutagen.easyid3 import EasyID3

app = FastAPI(title="Music Download API")

# CORS middleware to allow Flutter app to connect
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify your Flutter app's origin
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize download service
# Use absolute path for downloads directory
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOADS_DIR = os.path.join(BASE_DIR, "downloads")
PLAYLISTS_FILE = os.path.join(BASE_DIR, "playlists.json")
os.makedirs(DOWNLOADS_DIR, exist_ok=True)

download_service = DownloadService(output_dir=DOWNLOADS_DIR)


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
        except:
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
    """Stream audio directly from YouTube with range request support - no download required"""
    try:
        # Decode the URL
        import urllib.parse
        youtube_url = urllib.parse.unquote(encoded_url)
        
        # Get direct streaming URL from YouTube (no download)
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
                
                # For range requests (206 Partial Content), we MUST include Content-Length
                # and NOT use chunked encoding. Read all data first to ensure exact match.
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
                    
                    # Return Response (not StreamingResponse) for range requests
                    # This ensures Content-Length matches exactly
                    return Response(
                        content=content_bytes,
                        status_code=206,
                        headers=response_headers,
                        media_type=content_type,
                    )
                else:
                    # For full requests (200), use chunked encoding
                    # Don't set Content-Length to allow progressive streaming
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
                                except:
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
    # Handle subdirectory paths (e.g., "playlist_name/song.m4a")
    # Normalize path separators and prevent directory traversal
    filename = filename.replace('\\', os.sep).replace('/', os.sep)
    if '..' in filename or filename.startswith('/'):
        raise HTTPException(status_code=400, detail="Invalid file path")
    
    file_path = os.path.join(download_service.output_dir, filename)
    if not os.path.isfile(file_path):
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
    """Delete a downloaded file (supports subdirectory paths)"""
    try:
        # Handle subdirectory paths and prevent directory traversal
        filename = filename.replace('\\', os.sep).replace('/', os.sep)
        if '..' in filename or filename.startswith('/'):
            raise HTTPException(status_code=400, detail="Invalid file path")
        
        file_path = os.path.join(download_service.output_dir, filename)
        if not os.path.isfile(file_path):
            raise HTTPException(status_code=404, detail="File not found")
        
        os.remove(file_path)
        return {"success": True, "message": f"File {filename} deleted successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


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
    # Remove .csv extension
    name = csv_filename.replace('.csv', '').replace('.CSV', '')
    # Replace underscores with spaces
    name = name.replace('_', ' ')
    # Title case (capitalize first letter of each word)
    name = name.title()
    return name


@app.post("/csv/convert/{filename}")
def convert_csv_file(filename: str, request: CsvConversionRequest):
    """Convert a specific CSV file to playlist entries (search only, no download)"""
    try:
        temp_dir = os.path.join(BASE_DIR, "temp")
        csv_path = os.path.join(temp_dir, filename)
        
        if not os.path.isfile(csv_path):
            raise HTTPException(status_code=404, detail="CSV file not found")
        
        # Progress tracking
        progress_data = {"current": 0, "total": 0, "status": ""}
        
        def progress_callback(current, total, status):
            progress_data["current"] = current
            progress_data["total"] = total
            progress_data["status"] = status
        
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
                "updatedAt": now
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
                    "filename": "",  # Empty filename - not downloaded yet
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
            # Continue even if playlist creation fails
        
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
        raise HTTPException(status_code=500, detail=str(e))


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
        "updatedAt": now
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
    
    # Check if song already exists in playlist (by ID)
    for existing_song in playlists[playlist_id]["songs"]:
        if existing_song.get("id") == song.id:
             return playlists[playlist_id] # Already exists
        # Also check filename if it's a downloaded file (non-empty filename)
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
