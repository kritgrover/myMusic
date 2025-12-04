import os
import subprocess
import re
import json
import platform
import shutil
from pathlib import Path
from mutagen.easyid3 import EasyID3
from mutagen.mp4 import MP4, MP4Tags


class DownloadService:
    def __init__(self, output_dir="downloads"):
        self.output_dir = output_dir
        os.makedirs(output_dir, exist_ok=True)
        self._init_executables()
    
    def _init_executables(self):
        """Initialize paths to yt-dlp and ffmpeg"""
        import sys
        
        if platform.system() == "Darwin":
            # macOS - assume installed via brew or in PATH
            self.ffmpeg_exe = shutil.which("ffmpeg") or "ffmpeg"
            self.yt_dlp_exe = shutil.which("yt-dlp") or "yt-dlp"
        elif platform.system() == "Linux":
            self.ffmpeg_exe = shutil.which("ffmpeg") or "ffmpeg"
            self.yt_dlp_exe = shutil.which("yt-dlp") or "yt-dlp"
        else:  # Windows
            base_dir = os.path.dirname(os.path.abspath(__file__))
            self.ffmpeg_exe = os.path.join(base_dir, "ffmpeg", "ffmpeg.exe")
            self.yt_dlp_exe = os.path.join(base_dir, "yt-dlp", "yt-dlp.exe")
            # Fallback to PATH if not found
            if not os.path.isfile(self.ffmpeg_exe):
                self.ffmpeg_exe = shutil.which("ffmpeg") or "ffmpeg"
            if not os.path.isfile(self.yt_dlp_exe):
                self.yt_dlp_exe = shutil.which("yt-dlp") or None
        
        # If yt-dlp not found as executable, try python -m yt_dlp
        if not self.yt_dlp_exe or (not shutil.which(self.yt_dlp_exe) and not os.path.isfile(self.yt_dlp_exe)):
            # Try to use python -m yt_dlp
            try:
                result = subprocess.run(
                    [sys.executable, "-m", "yt_dlp", "--version"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    creationflags=subprocess.CREATE_NO_WINDOW if platform.system() == 'Windows' else 0
                )
                if result.returncode == 0:
                    self.yt_dlp_exe = [sys.executable, "-m", "yt_dlp"]
                    print("Using yt-dlp via python -m yt_dlp")
                else:
                    self.yt_dlp_exe = None
            except Exception:
                self.yt_dlp_exe = None
        
        # Verify yt-dlp is accessible
        if self.yt_dlp_exe:
            try:
                cmd = self.yt_dlp_exe if isinstance(self.yt_dlp_exe, list) else [self.yt_dlp_exe]
                result = subprocess.run(
                    cmd + ["--version"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    creationflags=subprocess.CREATE_NO_WINDOW if platform.system() == 'Windows' else 0
                )
                if result.returncode != 0:
                    print(f"Warning: yt-dlp may not be working correctly. Error: {result.stderr}")
            except Exception as e:
                print(f"Warning: Could not verify yt-dlp installation: {e}")
    
    def normalize(self, text: str) -> str:
        """Lowercase and strip out any punctuation, leaving only word chars and spaces."""
        return re.sub(r"[^\w\s]", "", text.lower())
    
    def contains_keywords_in_order(self, candidate_title: str, keywords: list[str]) -> bool:
        txt = self.normalize(candidate_title)
        pos = 0
        for kw in keywords:
            idx = txt.find(kw, pos)
            if idx < 0:
                return False
            pos = idx + len(kw)
        return True
    
    def search_youtube(self, query: str, deep_search: bool = True, duration_min: int = 0, duration_max: float = float("inf")):
        """Search YouTube and return video information"""
        creationflags = subprocess.CREATE_NO_WINDOW if platform.system() == 'Windows' else 0
        
        # Check if yt-dlp is available
        if not self.yt_dlp_exe:
            raise Exception(f"yt-dlp not found. Please install it: pip install yt-dlp")
        
        def yt_cmd(extra_args, search_spec):
            # Handle both string (executable path) and list (python -m yt_dlp) formats
            if isinstance(self.yt_dlp_exe, list):
                cmd = self.yt_dlp_exe.copy()
            else:
                cmd = [self.yt_dlp_exe]
            cmd.append("--no-config")
            # Only add ffmpeg-location if ffmpeg is in a specific directory (not in PATH)
            ffmpeg_dir = os.path.dirname(self.ffmpeg_exe) if isinstance(self.ffmpeg_exe, str) and os.path.dirname(self.ffmpeg_exe) else ""
            if ffmpeg_dir and os.path.isdir(ffmpeg_dir):
                cmd.append(f"--ffmpeg-location={ffmpeg_dir}")
            cmd += extra_args + [search_spec]
            return cmd
        
        if deep_search:
            # Phase 1: quick flat-playlist probe
            proc_q = subprocess.run(
                yt_cmd(["--flat-playlist", "--dump-single-json", "--no-playlist"], f"ytsearch3:{query}"),
                capture_output=True, text=True, creationflags=creationflags, timeout=30
            )
            if proc_q.returncode != 0:
                error_msg = proc_q.stderr or proc_q.stdout or "Unknown error"
                raise Exception(f"yt-dlp search failed: {error_msg[:500]}")
            try:
                data_q = json.loads(proc_q.stdout) or {}
            except json.JSONDecodeError as e:
                raise Exception(f"Failed to parse yt-dlp output: {e}. Output: {proc_q.stdout[:200]}")
            if not isinstance(data_q, dict):
                data_q = {}
            
            entries = data_q.get('entries') if isinstance(data_q.get('entries'), list) else []
            results = []
            
            for entry in entries[:10]:  # Get top 10 results
                if not isinstance(entry, dict):
                    continue
                vid_id = entry.get('id', '')
                vid_title = entry.get('title', '')
                uploader = entry.get('uploader', '')
                duration = entry.get('duration', 0)
                url = f"https://www.youtube.com/watch?v={vid_id}"
                
                # Filter by duration
                if duration < duration_min or duration > duration_max:
                    continue
                
                results.append({
                    'id': vid_id,
                    'title': vid_title,
                    'uploader': uploader,
                    'duration': duration,
                    'url': url,
                    'thumbnail': f"https://img.youtube.com/vi/{vid_id}/maxresdefault.jpg"
                })
            
            return results
        else:
            # Fast search - single result
            proc = subprocess.run(
                yt_cmd(["--flat-playlist", "--dump-single-json", "--no-playlist"], f"ytsearch1:{query}"),
                capture_output=True, text=True, creationflags=creationflags, timeout=30
            )
            if proc.returncode != 0:
                error_msg = proc.stderr or proc.stdout or "Unknown error"
                raise Exception(f"yt-dlp search failed: {error_msg[:500]}")
            try:
                data = json.loads(proc.stdout) or {}
            except json.JSONDecodeError as e:
                raise Exception(f"Failed to parse yt-dlp output: {e}. Output: {proc.stdout[:200]}")
            
            if not isinstance(data, dict):
                return []
            
            entries = data.get('entries') if isinstance(data.get('entries'), list) else []
            if not entries:
                return []
            
            entry = entries[0] if isinstance(entries[0], dict) else {}
            vid_id = entry.get('id', '')
            if not vid_id:
                return []
            
            return [{
                'id': vid_id,
                'title': entry.get('title', ''),
                'uploader': entry.get('uploader', ''),
                'duration': entry.get('duration', 0),
                'url': f"https://www.youtube.com/watch?v={vid_id}",
                'thumbnail': f"https://img.youtube.com/vi/{vid_id}/maxresdefault.jpg"
            }]
    
    def download_audio(self, url: str, title: str, artist: str = "", album: str = "", 
                      output_format: str = "m4a", embed_thumbnail: bool = False):
        """Download audio from YouTube URL"""
        creationflags = subprocess.CREATE_NO_WINDOW if platform.system() == 'Windows' else 0
        
        # Sanitize filename
        safe_title = re.sub(r"[^\w\s]", "", title).strip()
        if not safe_title:
            safe_title = "Unknown"
        
        filename = f"{safe_title}"
        if artist:
            safe_artist = re.sub(r"[^\w\s]", "", artist).strip()
            if safe_artist:
                filename += f" - {safe_artist}"
        
        output_path = os.path.join(self.output_dir, filename)
        
        def yt_cmd(extra_args, search_spec):
            # Handle both string (executable path) and list (python -m yt_dlp) formats
            if isinstance(self.yt_dlp_exe, list):
                cmd = self.yt_dlp_exe.copy()
            else:
                cmd = [self.yt_dlp_exe]
            cmd.append("--no-config")
            # Only add ffmpeg-location if ffmpeg is in a specific directory (not in PATH)
            ffmpeg_dir = os.path.dirname(self.ffmpeg_exe) if isinstance(self.ffmpeg_exe, str) and os.path.dirname(self.ffmpeg_exe) else ""
            if ffmpeg_dir and os.path.isdir(ffmpeg_dir):
                cmd.append(f"--ffmpeg-location={ffmpeg_dir}")
            cmd += extra_args + [search_spec]
            return cmd
        
        # Build download command
        cmd_dl = yt_cmd([
            '-f', 'bestaudio[ext=m4a]/bestaudio',
            '--output', output_path + '.%(ext)s',
            '--no-playlist'
        ], url)
        
        if embed_thumbnail:
            cmd_dl += ['--embed-thumbnail', '--add-metadata']
        
        if output_format == 'mp3':
            cmd_dl += ['--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0']
        else:
            cmd_dl += ['--remux-video', 'm4a']
        
        # Execute download
        ret = subprocess.run(cmd_dl, capture_output=True, text=True, creationflags=creationflags)
        
        if ret.returncode != 0:
            error_msg = ret.stderr or ret.stdout or "Unknown error"
            raise Exception(f"Download failed: {error_msg[:200]}")
        
        # Find the downloaded file
        ext = '.mp3' if output_format == 'mp3' else '.m4a'
        downloaded_file = output_path + ext
        
        # If file doesn't exist, try to find it
        if not os.path.isfile(downloaded_file):
            # yt-dlp might have added a number suffix
            for f in os.listdir(self.output_dir):
                if f.startswith(filename) and f.endswith(ext):
                    downloaded_file = os.path.join(self.output_dir, f)
                    break
        
        if not os.path.isfile(downloaded_file):
            raise Exception("Downloaded file not found")
        
        # Embed metadata
        try:
            if ext == '.m4a':
                audio = MP4(downloaded_file)
                tags = audio.tags or MP4Tags()
                tags['\xa9nam'] = [title]
                if artist:
                    tags['\xa9ART'] = [artist]
                if album:
                    tags['\xa9alb'] = [album]
                audio.save()
            else:  # MP3
                try:
                    audio = EasyID3(downloaded_file)
                except:
                    audio = EasyID3()
                audio['title'] = title
                if artist:
                    audio['artist'] = artist
                if album:
                    audio['album'] = album
                audio.save()
        except Exception as e:
            print(f"Warning: Could not embed metadata: {e}")
        
        return {
            'file_path': downloaded_file,
            'filename': os.path.basename(downloaded_file),
            'title': title,
            'artist': artist,
            'album': album
        }
    
    def get_download_progress(self, url: str):
        """Get download progress for a URL (for streaming progress)"""
        # This is a simplified version - yt-dlp doesn't easily provide progress via API
        # In a real implementation, you might want to parse yt-dlp output or use callbacks
        return {"status": "downloading", "progress": 0}


