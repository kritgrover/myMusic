import httpx
import re
from typing import Optional, Dict, List
from database import db


def _simple_similarity(a: str, b: str) -> float:
    """Token-based similarity: fraction of tokens from a that appear in b."""
    if not a or not b:
        return 0.0
    a_tokens = set(re.findall(r'\w+', a.lower()))
    b_tokens = set(re.findall(r'\w+', b.lower()))
    if not a_tokens:
        return 0.0
    return len(a_tokens & b_tokens) / len(a_tokens)


class LyricsService:
    BASE_URL = "https://lrclib.net/api"
    USER_AGENT = "myMusic/1.0"
    
    def _get_cache_key(self, track_name: str, artist_name: str, album_name: str = ""):
        """Generate cache key for lyrics"""
        return f"lyrics:{track_name}:{artist_name}:{album_name}"

    def _clean_track_name(self, name: str) -> str:
        """Strip common YouTube junk from track names for better LRCLIB matching."""
        patterns = [
            r'\(Official\s*(Music\s*)?Video\)',
            r'\(Official\s*Audio\)',
            r'\(Lyric\s*Video\)',
            r'\[Official\s*(Music\s*)?Video\]',
            r'\[Lyrics?\]',
            r'\(Audio\)',
            r'\(Visualizer\)',
            r'\(Official\s*Visualizer\)',
            r'\bft\.?\s+',
            r'\bfeat\.?\s+',
            r'\(HD\)',
            r'\[HD\]',
        ]
        for p in patterns:
            name = re.sub(p, '', name, flags=re.IGNORECASE)
        return name.strip()

    def _try_get_lyrics(self, track_name: str, artist_name: str, album_name: str,
                        duration: Optional[int]) -> Optional[Dict]:
        """Call LRCLIB /api/get and return formatted result or None."""
        params = {
            "track_name": track_name,
            "artist_name": artist_name,
            "album_name": album_name or "",
        }
        if duration is not None:
            params["duration"] = duration
        with httpx.Client(timeout=10.0, headers={"User-Agent": self.USER_AGENT}) as client:
            response = client.get(f"{self.BASE_URL}/get", params=params)
            if response.status_code == 200:
                data = response.json()
                return {
                    "trackName": data.get("trackName", track_name),
                    "artistName": data.get("artistName", artist_name),
                    "albumName": data.get("albumName", album_name),
                    "plainLyrics": data.get("plainLyrics", ""),
                    "syncedLyrics": data.get("syncedLyrics", ""),
                    "instrumental": data.get("instrumental", False),
                    "source": "lrclib"
                }
        return None
    
    def get_lyrics(self, track_name: str, artist_name: str, 
                   album_name: str = "", duration: Optional[int] = None) -> Optional[Dict]:
        """
        Get lyrics for a track from LRCLIB API.
        
        Args:
            track_name: Song title
            artist_name: Artist name
            album_name: Album name (optional)
            duration: Track duration in seconds (optional, but helps with matching)
        
        Returns:
            Dict with lyrics data or None if not found
        """
        if not track_name or not artist_name:
            return None
        
        # Check cache first
        cache_key = self._get_cache_key(track_name, artist_name, album_name)
        cached = db.get_cache(cache_key)
        if cached:
            return cached
        
        try:
            # Try original name first
            result = self._try_get_lyrics(track_name, artist_name, album_name, duration)
            if result is not None:
                db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                return result
            # Try cleaned name as fallback if different
            cleaned = self._clean_track_name(track_name)
            if cleaned and cleaned != track_name:
                result = self._try_get_lyrics(cleaned, artist_name, album_name, duration)
                if result is not None:
                    db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                    return result
        except Exception as e:
            print(f"Error fetching lyrics from LRCLIB: {e}")
        return self._search_lyrics_fallback(track_name, artist_name, album_name, duration)
    
    def _score_search_result(self, r: Dict, track_name: str, artist_name: str,
                             duration: Optional[int]) -> float:
        """Score a search result. Higher is better."""
        score = 0.0
        res_artist = (r.get("artistName") or "").lower()
        req_artist = artist_name.lower()
        # Title similarity (0-1)
        score += _simple_similarity(track_name, r.get("trackName") or "") * 3.0
        # Artist match
        if req_artist and res_artist and (req_artist in res_artist or res_artist in req_artist):
            score += 2.0
        elif _simple_similarity(artist_name, r.get("artistName") or "") > 0.5:
            score += 1.0
        # Duration proximity (if duration provided)
        if duration is not None:
            res_dur = r.get("duration")
            if res_dur is not None:
                diff = abs(res_dur - duration)
                if diff <= 5:
                    score += 2.0
                elif diff <= 15:
                    score += 1.0
                elif diff <= 30:
                    score += 0.5
        # Prefer synced lyrics
        if r.get("syncedLyrics") and (r.get("syncedLyrics") or "").strip():
            score += 1.5
        return score

    def _search_lyrics_fallback(self, track_name: str, artist_name: str,
                               album_name: str = "",
                               duration: Optional[int] = None) -> Optional[Dict]:
        """
        Fallback to search endpoint if exact match fails.
        Scores results by title similarity, artist match, duration proximity,
        and preference for synced lyrics.
        """
        try:
            search_query = f"{track_name} {artist_name}"
            if album_name:
                search_query += f" {album_name}"

            with httpx.Client(timeout=10.0, headers={"User-Agent": self.USER_AGENT}) as client:
                response = client.get(f"{self.BASE_URL}/search", params={"q": search_query})
                if response.status_code != 200:
                    return None
                responses = response.json() or []
                if not responses:
                    return None

                # Score and pick best
                best = max(responses, key=lambda r: self._score_search_result(
                    r, track_name, artist_name, duration))
                result = {
                    "trackName": best.get("trackName", track_name),
                    "artistName": best.get("artistName", artist_name),
                    "albumName": best.get("albumName", album_name),
                    "plainLyrics": best.get("plainLyrics", ""),
                    "syncedLyrics": best.get("syncedLyrics", ""),
                    "instrumental": best.get("instrumental", False),
                    "source": "lrclib"
                }
                cache_key = self._get_cache_key(track_name, artist_name, album_name)
                db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                return result
        except Exception as e:
            print(f"Error in lyrics search fallback: {e}")
        return None
    
    def search_lyrics(self, track_name: str, artist_name: str = "") -> List[Dict]:
        """
        Search for lyrics records matching the query.
        
        Args:
            track_name: Song title to search for
            artist_name: Artist name (optional)
        
        Returns:
            List of matching lyrics records
        """
        try:
            params = {}
            if track_name:
                params["track_name"] = track_name
            if artist_name:
                params["artist_name"] = artist_name
            
            if not params:
                return []
            
            with httpx.Client(timeout=10.0, headers={"User-Agent": self.USER_AGENT}) as client:
                response = client.get(f"{self.BASE_URL}/search", params=params)
                
                if response.status_code == 200:
                    results = response.json()
                    return [
                        {
                            "id": r.get("id"),
                            "trackName": r.get("trackName"),
                            "artistName": r.get("artistName"),
                            "albumName": r.get("albumName"),
                            "duration": r.get("duration"),
                            "instrumental": r.get("instrumental", False),
                        }
                        for r in results
                    ]
            
            return []
            
        except Exception as e:
            print(f"Error searching lyrics: {e}")
            return []


# Singleton instance
lyrics_service = LyricsService()
