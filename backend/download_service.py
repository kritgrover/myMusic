import os
import subprocess
import re
import json
import platform
import shutil
import csv
import time
from pathlib import Path
from datetime import timedelta
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
        
        ret = subprocess.run(cmd_dl, capture_output=True, text=True, creationflags=creationflags)
        if ret.returncode != 0:
            raise Exception(f"Download failed: {ret.stderr}")
        
        # Find the downloaded file
        out_ext = '.m4a' if output_format == 'm4a' else '.mp3'
        candidate_path = output_path + out_ext
        if not os.path.isfile(candidate_path):
            # Try to find the file with any extension
            for ext in ['.m4a', '.mp3', '.webm', '.opus']:
                candidate = output_path + ext
                if os.path.isfile(candidate):
                    candidate_path = candidate
                    break
            else:
                raise Exception(f"Downloaded file not found at {candidate_path}")
        
        # Read metadata from the downloaded file
        title_meta = title
        artist_meta = artist
        album_meta = album
        
        try:
            if candidate_path.endswith('.m4a'):
                audio = MP4(candidate_path)
                if not audio.tags:
                    audio.add_tags()
                audio.tags['\xa9nam'] = title_meta
                if artist_meta:
                    audio.tags['\xa9ART'] = artist_meta
                if album_meta:
                    audio.tags['\xa9alb'] = album_meta
                audio.save()
            else:  # MP3
                audio = EasyID3(candidate_path)
                audio['title'] = title_meta
                if artist_meta:
                    audio['artist'] = artist_meta
                if album_meta:
                    audio['album'] = album_meta
                audio.save()
        except Exception as e:
            print(f"Warning: Could not write metadata: {e}")
        
        filename = os.path.basename(candidate_path)
        return {
            'file_path': candidate_path,
            'filename': filename,
            'title': title_meta,
            'artist': artist_meta,
            'album': album_meta
        }
    
    def get_streaming_url(self, url: str):
        """Get direct streaming URL from YouTube URL without downloading"""
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
        
        # Get the best audio stream URL using -g flag (get URL without downloading)
        cmd_stream = yt_cmd([
            '-f', 'bestaudio[ext=m4a]/bestaudio/best',
            '-g'  # Get URL only, don't download
        ], url)
        
        ret = subprocess.run(cmd_stream, capture_output=True, text=True, creationflags=creationflags)
        if ret.returncode != 0:
            raise Exception(f"Failed to get streaming URL: {ret.stderr}")
        
        streaming_url = ret.stdout.strip()
        if not streaming_url or not streaming_url.startswith('http'):
            raise Exception("Invalid streaming URL received")
        
        return streaming_url
        
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
    
    def convert_csv_to_m4a(self, csv_path: str, deep_search: bool = True, 
                           duration_min: int = 0, duration_max: float = 600,
                           exclude_instrumentals: bool = False, 
                           variants: list = None, progress_callback=None):
        """
        Convert CSV playlist to M4A files.
        Returns a dict with 'downloaded', 'not_found', and 'output_dir' keys.
        """
        if variants is None:
            variants = ['']
        
        creationflags = subprocess.CREATE_NO_WINDOW if platform.system() == 'Windows' else 0
        
        # Check if yt-dlp is available
        if not self.yt_dlp_exe:
            raise Exception(f"yt-dlp not found. Please install it: pip install yt-dlp")
        
        playlist_name = os.path.splitext(os.path.basename(csv_path))[0]
        output_dir = os.path.join(self.output_dir, playlist_name)
        os.makedirs(output_dir, exist_ok=True)
        
        def yt_cmd(extra_args, search_spec):
            if isinstance(self.yt_dlp_exe, list):
                cmd = self.yt_dlp_exe.copy()
            else:
                cmd = [self.yt_dlp_exe]
            cmd.append("--no-config")
            ffmpeg_dir = os.path.dirname(self.ffmpeg_exe) if isinstance(self.ffmpeg_exe, str) and os.path.dirname(self.ffmpeg_exe) else ""
            if ffmpeg_dir and os.path.isdir(ffmpeg_dir):
                cmd.append(f"--ffmpeg-location={ffmpeg_dir}")
            cmd += extra_args + [search_spec]
            return cmd
        
        rows = list(csv.DictReader(open(csv_path, newline='', encoding='utf-8')))
        total = len(rows)
        archive_file = os.path.join(output_dir, 'downloaded.txt')
        downloaded = []
        not_found_songs = []
        start_time = time.time()
        
        for i, row in enumerate(rows, start=1):
            title = row.get('Track Name') or row.get('Track name') or 'Unknown'
            artist_raw = row.get('Artist Name(s)') or row.get('Artist name') or 'Unknown'
            artist_primary = re.split(r'[,/&]| feat\.| ft\.', artist_raw, flags=re.I)[0].strip()
            safe_artist = re.sub(r"[^\w\s]", '', artist_primary)
            album = row.get('Album Name') or row.get('Album') or playlist_name
            spotify_ms = row.get('Duration (ms)')
            spotify_sec = int(spotify_ms) / 1000 if spotify_ms and spotify_ms.isdigit() else None
            
            safe_title = re.sub(r"[^\w\s]", '', title)
            search_variants = variants.copy()
            if 'instrumental' in title.lower():
                search_variants.insert(0, 'instrumental')
            
            best_file = None
            for variant in search_variants:
                parts = [safe_title]
                if safe_artist and safe_artist.lower() != 'unknown':
                    parts.append(safe_artist)
                if variant:
                    parts.append(variant)
                q = ' '.join(parts)
                
                if progress_callback:
                    progress_callback(i, total, f"Searching: {q}")
                
                if deep_search:
                    # Phase 1: quick flat-playlist probe
                    proc_q = subprocess.run(
                        yt_cmd(["--flat-playlist", "--dump-single-json", "--no-playlist"], f"ytsearch1:{q}"),
                        capture_output=True, text=True, creationflags=creationflags, timeout=30
                    )
                    try:
                        data_q = json.loads(proc_q.stdout) or {}
                    except Exception:
                        data_q = {}
                    if not isinstance(data_q, dict):
                        data_q = {}
                    entries_q = data_q.get('entries') if isinstance(data_q.get('entries'), list) else []
                    top = entries_q[0] if entries_q else {}
                    
                    vid_title = top.get('title', '')
                    upl = (top.get('uploader') or '').lower()
                    duration = top.get('duration') or 0
                    passes = (
                        safe_title.lower() in vid_title.lower()
                        and (not safe_artist or safe_artist.lower() in upl)
                        and (not spotify_sec or abs(duration - spotify_sec) <= 10)
                        and (duration >= duration_min and duration <= duration_max)
                    )
                    if passes:
                        download_spec = top.get('webpage_url', f"https://www.youtube.com/watch?v={top.get('id','')}")
                    else:
                        # Phase 2: deep-search candidate IDs
                        proc_ids = subprocess.run(
                            yt_cmd(["--flat-playlist", "--dump-single-json", "--no-playlist"], f"ytsearch3:{q}"),
                            capture_output=True, text=True, creationflags=creationflags, timeout=30
                        )
                        try:
                            tmp = json.loads(proc_ids.stdout) or {}
                        except Exception:
                            tmp = {}
                        data_ids = tmp if isinstance(tmp, dict) else {}
                        entries_ids = data_ids.get('entries') if isinstance(data_ids.get('entries'), list) else []
                        ids = [e for e in entries_ids if isinstance(e, dict)][:3]
                        
                        scored = []
                        first_words = self.normalize(title).split()[:5]
                        for entry in ids:
                            vid = entry.get('id')
                            if not vid:
                                continue
                            url = f"https://www.youtube.com/watch?v={vid}"
                            proc_i = subprocess.run(
                                yt_cmd(["--dump-single-json", "--no-playlist"], url),
                                capture_output=True, text=True, creationflags=creationflags, timeout=30
                            )
                            if "Sign in to confirm your age" in (proc_i.stderr or ''):
                                continue
                            try:
                                info = json.loads(proc_i.stdout) or {}
                            except Exception:
                                continue
                            
                            raw_title = info.get('title', '')
                            low = raw_title.lower()
                            up2 = (info.get('uploader') or '').lower()
                            dur2 = info.get('duration') or 0
                            if dur2 < duration_min or dur2 > duration_max:
                                continue
                            if 'shorts/' in info.get('webpage_url', '') or '#shorts' in low:
                                continue
                            if safe_artist.lower() and safe_artist.lower() not in up2:
                                continue
                            if variant and variant.lower() not in low:
                                continue
                            if not self.contains_keywords_in_order(raw_title, first_words):
                                continue
                            score = 100 if low.startswith(safe_title.lower()) else 80
                            if spotify_sec:
                                score -= abs(dur2 - spotify_sec)
                            scored.append((score, url))
                        download_spec = scored and max(scored, key=lambda x: x[0])[1] or f"ytsearch1:{q}"
                else:
                    download_spec = f"ytsearch1:{q}"
                
                # Download
                file_title = re.sub(r"[^\w\s]", "", title).strip()
                base = f"{i:03d} - {file_title}" + (f" - {variant}" if variant else "")
                tmpl = base + ".%(ext)s"
                cmd_dl = yt_cmd([
                    '--download-archive', archive_file,
                    '-f', 'bestaudio[ext=m4a]/bestaudio',
                    '--output', os.path.join(output_dir, tmpl),
                    '--no-playlist',
                    '--remux-video', 'm4a'
                ], download_spec)
                
                if exclude_instrumentals:
                    cmd_dl += ['--reject-title', 'instrumental']
                
                ret = subprocess.run(cmd_dl, capture_output=True, text=True, creationflags=creationflags, timeout=300)
                if ret.returncode != 0:
                    stderr = ret.stderr or ''
                    if 'Sign in to confirm your age' in stderr:
                        not_found_songs.append({
                            'Track Name': title,
                            'Artist Name(s)': artist_primary,
                            'Album Name': album,
                            'Track Number': i,
                            'Error': 'Age-restricted video'
                        })
                        break
                    else:
                        continue
                
                candidate_path = os.path.join(output_dir, base + '.m4a')
                if os.path.isfile(candidate_path):
                    best_file = candidate_path
                    # Embed metadata
                    try:
                        audio = MP4(best_file)
                        tags = audio.tags or MP4Tags()
                        tags['\xa9nam'] = [title]
                        tags['\xa9ART'] = [artist_primary]
                        tags['\xa9alb'] = [album]
                        audio.save()
                    except Exception as e:
                        print(f"Warning: Could not embed metadata: {e}")
                    downloaded.append(os.path.basename(best_file))
                    break
            
            if not best_file:
                not_found_songs.append({
                    'Track Name': title,
                    'Artist Name(s)': artist_primary,
                    'Album Name': album,
                    'Track Number': i,
                    'Error': 'No valid download'
                })
            
            if progress_callback:
                elapsed = time.time() - start_time
                eta = timedelta(seconds=int((elapsed/i)*(total-i))) if i > 0 else timedelta(0)
                progress_callback(i, total, f"Downloaded {i}/{total}, ETA: {eta}")
        
        # Save not found songs to CSV
        if not_found_songs:
            nf_path = os.path.join(output_dir, f"{playlist_name}_not_found.csv")
            with open(nf_path, 'w', newline='', encoding='utf-8') as cf:
                writer = csv.DictWriter(cf, fieldnames=['Track Name', 'Artist Name(s)', 'Album Name', 'Track Number', 'Error'])
                writer.writeheader()
                writer.writerows(not_found_songs)
        
        return {
            'downloaded': downloaded,
            'not_found': not_found_songs,
            'output_dir': output_dir,
            'total': total,
            'success_count': len(downloaded)
        }


