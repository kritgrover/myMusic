from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from typing import List, Optional, Dict
import os
import json
import uuid
from datetime import datetime
from download_service import DownloadService

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
    deep_search: bool = True
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
            deep_search=request.deep_search,
            duration_min=request.duration_min,
            duration_max=request.duration_max
        )
        return results
    except Exception as e:
        import traceback
        error_detail = f"{str(e)}\n\nTraceback:\n{traceback.format_exc()}"
        print(f"Search error: {error_detail}")  # Log to console
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
    """List all downloaded files"""
    try:
        downloads_dir = download_service.output_dir
        files = []
        if os.path.exists(downloads_dir):
            for filename in os.listdir(downloads_dir):
                if filename.lower().endswith(('.mp3', '.m4a')):
                    file_path = os.path.join(downloads_dir, filename)
                    files.append({
                        "filename": filename,
                        "file_path": file_path,
                        "size": os.path.getsize(file_path)
                    })
        return {"files": files}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/downloads/{filename}")
def get_download_file(filename: str, request: Request):
    """Serve download file for streaming with Range request support"""
    file_path = os.path.join(download_service.output_dir, filename)
    if not os.path.isfile(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    
    # FileResponse automatically handles Range requests
    return FileResponse(
        file_path,
        media_type='audio/mpeg' if filename.endswith('.mp3') else 'audio/mp4',
        filename=filename,
        headers={
            "Accept-Ranges": "bytes",
        }
    )


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


@app.post("/playlists/{playlist_id}/songs", response_model=Playlist)
def add_song_to_playlist(playlist_id: str, song: AddSongRequest):
    """Add a song to a playlist"""
    playlists = load_playlists()
    if playlist_id not in playlists:
        raise HTTPException(status_code=404, detail="Playlist not found")
    
    # Check if song already exists in playlist (by filename)
    for existing_song in playlists[playlist_id]["songs"]:
        if existing_song["filename"] == song.filename:
             return playlists[playlist_id] # Already exists, just return

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
