from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List, Optional
import os
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
download_service = DownloadService(output_dir="downloads")


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
def get_download_file(filename: str):
    """Serve download file for streaming"""
    file_path = os.path.join(download_service.output_dir, filename)
    if not os.path.isfile(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(
        file_path,
        media_type='audio/mpeg' if filename.endswith('.mp3') else 'audio/mp4',
        filename=filename
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

