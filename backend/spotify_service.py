import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
from config import settings
from database import db
import time

class SpotifyService:
    def __init__(self):
        self.client_id = settings.SPOTIFY_CLIENT_ID
        self.client_secret = settings.SPOTIFY_CLIENT_SECRET
        self.sp = None
        self._authenticate()

    def _authenticate(self):
        try:
            if self.client_id == "your_client_id_here" or self.client_secret == "your_client_secret_here":
                print("Warning: Spotify credentials not set in config.py")
                return

            client_credentials_manager = SpotifyClientCredentials(
                client_id=self.client_id,
                client_secret=self.client_secret
            )
            self.sp = spotipy.Spotify(client_credentials_manager=client_credentials_manager)
        except Exception as e:
            print(f"Failed to authenticate with Spotify: {e}")
            self.sp = None

    def _get_cache_key(self, prefix, *args):
        return f"{prefix}:{':'.join(str(arg) for arg in args)}"

    def search_track(self, title, artist):
        if not self.sp: return None
        
        cache_key = self._get_cache_key("search", title, artist)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            # Search strictly by track and artist
            q = f"track:{title} artist:{artist}"
            results = self.sp.search(q=q, type='track', limit=1)
            
            items = results.get('tracks', {}).get('items', [])
            if not items:
                # Fallback to broader search
                q = f"{title} {artist}"
                results = self.sp.search(q=q, type='track', limit=1)
                items = results.get('tracks', {}).get('items', [])
            
            if items:
                track = items[0]
                result = {
                    'id': track['id'],
                    'title': track['name'],  # Standardized: use 'title' everywhere
                    'name': track['name'],   # Keep 'name' for backward compatibility
                    'artist': track['artists'][0]['name'],
                    'artist_id': track['artists'][0]['id'],
                    'album': track['album']['name'],
                    'thumbnail': track['album']['images'][0]['url'] if track['album']['images'] else None,
                    'image': track['album']['images'][0]['url'] if track['album']['images'] else None,  # Backward compat
                    'preview_url': track['preview_url'],
                    'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0  # Duration in seconds
                }
                db.set_cache(cache_key, result, ttl_seconds=86400*7) # Cache for 1 week
                return result
            
            return None
        except Exception as e:
            print(f"Spotify search error: {e}")
            return None

    def get_recommendations(self, seed_tracks=None, seed_artists=None, seed_genres=None, limit=20):
        if not self.sp: return []
        
        # Ensure we have max 5 seeds total (Spotify limit)
        seeds_count = (len(seed_tracks) if seed_tracks else 0) + \
                      (len(seed_artists) if seed_artists else 0) + \
                      (len(seed_genres) if seed_genres else 0)
        if seeds_count == 0: return []
        
        # Truncate seeds to stay within limit of 5
        if seeds_count > 5:
            if seed_tracks and len(seed_tracks) >= 3:
                seed_tracks = seed_tracks[:3]
                seed_genres = seed_genres[:2] if seed_genres else None
                seed_artists = None
            elif seed_tracks:
                remaining = 5 - len(seed_tracks)
                seed_genres = seed_genres[:remaining] if seed_genres else None
                seed_artists = None
            else:
                seed_genres = seed_genres[:5] if seed_genres else None
                seed_artists = None

        cache_key = self._get_cache_key("recs", seed_tracks, seed_artists, seed_genres, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.recommendations(
                seed_tracks=seed_tracks,
                seed_artists=seed_artists,
                seed_genres=seed_genres,
                limit=limit
            )
            
            tracks = []
            for track in results.get('tracks', []):
                tracks.append({
                    'id': track['id'],
                    'title': track['name'],
                    'artist': track['artists'][0]['name'],
                    'album': track['album']['name'],
                    'thumbnail': track['album']['images'][0]['url'] if track['album']['images'] else None,
                    'url': track['external_urls']['spotify'],
                    'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0  # Duration in seconds
                })
            
            db.set_cache(cache_key, tracks, ttl_seconds=3600) # Cache for 1 hour
            return tracks
        except Exception as e:
            print(f"Spotify recommendations error: {e}")
            return []

    def get_artist_new_releases(self, artist_id, limit=5):
        if not self.sp: return []
        
        cache_key = self._get_cache_key("new_releases", artist_id, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.artist_albums(
                artist_id, 
                album_type='album,single', 
                limit=limit
            )
            
            albums = []
            for album in results.get('items', []):
                albums.append({
                    'id': album['id'],
                    'name': album['name'],
                    'artist': album['artists'][0]['name'],
                    'type': album['album_type'],
                    'release_date': album['release_date'],
                    'thumbnail': album['images'][0]['url'] if album['images'] else None,
                    'url': album['external_urls']['spotify']
                })
            
            db.set_cache(cache_key, albums, ttl_seconds=86400) # Cache for 1 day
            return albums
        except Exception as e:
            print(f"Spotify new releases error: {e}")
            return []
    
    def get_artist_genres(self, artist_id):
        """Get genres for an artist - used to track user's genre preferences"""
        if not self.sp: return []
        
        cache_key = self._get_cache_key("artist_genres", artist_id)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            artist = self.sp.artist(artist_id)
            genres = artist.get('genres', [])
            db.set_cache(cache_key, genres, ttl_seconds=86400*7)  # Cache for 1 week
            return genres
        except Exception as e:
            print(f"Error getting artist genres: {e}")
            return []

    def get_genre_recommendations(self, genre, limit=20):
        """Get recommendations seeded by genre - much better than searching for user playlists!"""
        if not self.sp: return []
        
        # Normalize genre for Spotify (lowercase, hyphens)
        normalized_genre = genre.lower().replace(' ', '-')
        
        cache_key = self._get_cache_key("genre_recs", normalized_genre, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.recommendations(
                seed_genres=[normalized_genre],
                limit=limit
            )
            
            tracks = []
            for track in results.get('tracks', []):
                tracks.append({
                    'id': track['id'],
                    'title': track['name'],
                    'artist': track['artists'][0]['name'],
                    'album': track['album']['name'],
                    'thumbnail': track['album']['images'][0]['url'] if track['album']['images'] else None,
                    'url': track['external_urls']['spotify'],
                    'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0  # Duration in seconds
                })
            
            db.set_cache(cache_key, tracks, ttl_seconds=3600)  # Cache for 1 hour (fresher!)
            return tracks
        except Exception as e:
            print(f"Spotify genre recommendations error: {e}")
            return []

    def get_available_genre_seeds(self):
        """Get list of available genre seeds from Spotify"""
        if not self.sp: return []
        
        cache_key = "available_genres"
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            result = self.sp.recommendation_genre_seeds()
            genres = result.get('genres', [])
            db.set_cache(cache_key, genres, ttl_seconds=86400*7)  # Cache for 1 week
            return genres
        except Exception as e:
            print(f"Error getting available genres: {e}")
            return []

    def get_new_releases(self, country='US', limit=20):
        """Get new album releases from Spotify"""
        if not self.sp: return []
        
        cache_key = self._get_cache_key("new_releases_browse", country, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.new_releases(country=country, limit=limit)
            albums = []
            for album in results.get('albums', {}).get('items', []):
                albums.append({
                    'id': album['id'],
                    'name': album['name'],
                    'artist': album['artists'][0]['name'],
                    'type': album['album_type'],
                    'release_date': album['release_date'],
                    'thumbnail': album['images'][0]['url'] if album['images'] else None,
                    'url': album['external_urls']['spotify']
                })
            
            db.set_cache(cache_key, albums, ttl_seconds=3600)  # Cache for 1 hour
            return albums
        except Exception as e:
            print(f"Error getting new releases: {e}")
            return []

    def get_genre_playlists(self, genre, limit=10):
        """DEPRECATED: Use get_genre_recommendations instead for better results"""
        if not self.sp: return []

        cache_key = self._get_cache_key("genre_playlists", genre, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.search(q=f"genre:{genre}", type='playlist', limit=limit)
            
            playlists = []
            for pl in results.get('playlists', {}).get('items', []):
                if not pl: continue
                playlists.append({
                    'id': pl['id'],
                    'name': pl['name'],
                    'description': pl['description'],
                    'thumbnail': pl['images'][0]['url'] if pl['images'] else None,
                    'url': pl['external_urls']['spotify'],
                    'owner': pl['owner']['display_name']
                })
            
            db.set_cache(cache_key, playlists, ttl_seconds=86400*3) # Cache for 3 days
            return playlists
        except Exception as e:
            print(f"Spotify genre playlists error: {e}")
            return []

    def get_playlist_tracks(self, playlist_id, limit=50):
        if not self.sp: return []

        cache_key = self._get_cache_key("playlist_tracks", playlist_id, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            results = self.sp.playlist_tracks(playlist_id, limit=limit)
            
            tracks = []
            for item in results.get('items', []):
                track = item.get('track')
                if not track: continue
                tracks.append({
                    'id': track['id'],
                    'title': track['name'],
                    'artist': track['artists'][0]['name'],
                    'album': track['album']['name'],
                    'thumbnail': track['album']['images'][0]['url'] if track['album']['images'] else None,
                    'url': track['external_urls']['spotify'],
                    'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0  # Duration in seconds
                })
            
            db.set_cache(cache_key, tracks, ttl_seconds=3600) # Cache for 1 hour
            return tracks
        except Exception as e:
            print(f"Spotify playlist tracks error: {e}")
            return []

spotify_service = SpotifyService()

