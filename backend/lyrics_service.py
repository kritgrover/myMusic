import httpx
from typing import Optional, Dict, List
from database import db
import time

class LyricsService:
    BASE_URL = "https://lrclib.net/api"
    USER_AGENT = "myMusic/1.0"
    
    def _get_cache_key(self, track_name: str, artist_name: str, album_name: str = ""):
        """Generate cache key for lyrics"""
        return f"lyrics:{track_name}:{artist_name}:{album_name}"
    
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
            # Build query parameters
            params = {
                "track_name": track_name,
                "artist_name": artist_name,
                "album_name": album_name or "",
            }
            
            # Add duration if provided (LRCLIB requires it for exact matching)
            if duration is not None:
                params["duration"] = duration
            
            # Try the main endpoint first (searches internal + external sources)
            with httpx.Client(timeout=10.0, headers={"User-Agent": self.USER_AGENT}) as client:
                response = client.get(f"{self.BASE_URL}/get", params=params)
                
                if response.status_code == 200:
                    data = response.json()
                    
                    # Format response
                    result = {
                        "trackName": data.get("trackName", track_name),
                        "artistName": data.get("artistName", artist_name),
                        "albumName": data.get("albumName", album_name),
                        "plainLyrics": data.get("plainLyrics", ""),
                        "syncedLyrics": data.get("syncedLyrics", ""),
                        "instrumental": data.get("instrumental", False),
                        "source": "lrclib"
                    }
                    
                    # Cache for 7 days
                    db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                    return result
                
                elif response.status_code == 404:
                    # Try search endpoint as fallback
                    return self._search_lyrics_fallback(track_name, artist_name, album_name)
                
                else:
                    print(f"LRCLIB API error: {response.status_code}")
                    return None
                    
        except Exception as e:
            print(f"Error fetching lyrics from LRCLIB: {e}")
            # Try search fallback on error
            return self._search_lyrics_fallback(track_name, artist_name, album_name)
    
    def _search_lyrics_fallback(self, track_name: str, artist_name: str, 
                                 album_name: str = "") -> Optional[Dict]:
        """
        Fallback to search endpoint if exact match fails.
        This searches for tracks and returns the first match.
        """
        try:
            # Build search query
            search_query = f"{track_name} {artist_name}"
            if album_name:
                search_query += f" {album_name}"
            
            with httpx.Client(timeout=10.0, headers={"User-Agent": self.USER_AGENT}) as client:
                response = client.get(
                    f"{self.BASE_URL}/search",
                    params={"q": search_query}
                )
                
                if response.status_code == 200:
                    results = response.json()
                    
                    # Find best match (first result is usually best)
                    if results and len(results) > 0:
                        best_match = results[0]
                        
                        result = {
                            "trackName": best_match.get("trackName", track_name),
                            "artistName": best_match.get("artistName", artist_name),
                            "albumName": best_match.get("albumName", album_name),
                            "plainLyrics": best_match.get("plainLyrics", ""),
                            "syncedLyrics": best_match.get("syncedLyrics", ""),
                            "instrumental": best_match.get("instrumental", False),
                            "source": "lrclib"
                        }
                        
                        # Cache for 7 days
                        cache_key = self._get_cache_key(track_name, artist_name, album_name)
                        db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                        return result
            
            return None
            
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
