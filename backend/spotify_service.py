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
        """Get recommendations based on seeds (uses related artists/search fallback since recommendations API deprecated)"""
        if not self.sp: return []
        
        # Ensure we have some seeds
        seeds_count = (len(seed_tracks) if seed_tracks else 0) + \
                      (len(seed_artists) if seed_artists else 0) + \
                      (len(seed_genres) if seed_genres else 0)
        if seeds_count == 0: return []

        cache_key = self._get_cache_key("recs_v2", seed_tracks, seed_artists, seed_genres, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        all_tracks = []
        seen_track_ids = set()
        
        try:
            # Strategy 1: If we have seed tracks, get related artists and their top tracks
            if seed_tracks:
                for track_id in seed_tracks[:3]:
                    try:
                        # Get track info to find artist
                        track_info = self.sp.track(track_id)
                        if track_info and track_info.get('artists'):
                            artist_id = track_info['artists'][0]['id']
                            
                            # Get related artists
                            related = self.sp.artist_related_artists(artist_id)
                            for related_artist in related.get('artists', [])[:3]:
                                # Get top tracks from related artist
                                top_tracks = self.sp.artist_top_tracks(related_artist['id'], country='US')
                                for track in top_tracks.get('tracks', [])[:3]:
                                    if track['id'] not in seen_track_ids and len(all_tracks) < limit:
                                        seen_track_ids.add(track['id'])
                                        all_tracks.append(self._format_track(track))
                    except Exception as e:
                        print(f"Error getting related for track {track_id}: {e}")
                        continue
            
            # Strategy 2: If we have genres, search for genre playlists
            if seed_genres and len(all_tracks) < limit:
                for genre in seed_genres[:2]:
                    tracks_from_genre = self.get_genre_recommendations(genre, limit=10)
                    for track in tracks_from_genre:
                        if track['id'] not in seen_track_ids and len(all_tracks) < limit:
                            seen_track_ids.add(track['id'])
                            all_tracks.append(track)
            
            # Strategy 3: If we have seed artists, get their related artists' top tracks
            if seed_artists and len(all_tracks) < limit:
                for artist_id in seed_artists[:2]:
                    try:
                        related = self.sp.artist_related_artists(artist_id)
                        for related_artist in related.get('artists', [])[:3]:
                            top_tracks = self.sp.artist_top_tracks(related_artist['id'], country='US')
                            for track in top_tracks.get('tracks', [])[:3]:
                                if track['id'] not in seen_track_ids and len(all_tracks) < limit:
                                    seen_track_ids.add(track['id'])
                                    all_tracks.append(self._format_track(track))
                    except Exception as e:
                        print(f"Error getting related for artist {artist_id}: {e}")
                        continue
            
            if all_tracks:
                db.set_cache(cache_key, all_tracks, ttl_seconds=3600)  # Cache for 1 hour
            
            return all_tracks
        except Exception as e:
            print(f"Spotify recommendations error: {e}")
            return []
    
    def _format_track(self, track):
        """Helper to format a Spotify track object into our standard format"""
        return {
            'id': track['id'],
            'title': track['name'],
            'artist': track['artists'][0]['name'] if track.get('artists') else 'Unknown',
            'album': track['album']['name'] if track.get('album') else '',
            'thumbnail': track['album']['images'][0]['url'] if track.get('album', {}).get('images') else None,
            'url': track['external_urls']['spotify'] if track.get('external_urls') else '',
            'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0
        }

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
        """Get tracks for a genre using playlist search (recommendations API deprecated Nov 2024)"""
        if not self.sp: return []
        
        # Normalize genre for Spotify (lowercase, hyphens)
        normalized_genre = genre.lower().replace(' ', '-')
        
        cache_key = self._get_cache_key("genre_recs_v2", normalized_genre, limit)
        cached = db.get_cache(cache_key)
        if cached: return cached

        try:
            # Search for playlists matching the genre
            # Try multiple search strategies for better coverage
            search_queries = [
                f"{genre} hits",
                f"best of {genre}",
                f"{genre} essentials",
                f"{genre}",
            ]
            
            all_tracks = []
            seen_track_ids = set()
            
            for query in search_queries:
                if len(all_tracks) >= limit:
                    break
                    
                try:
                    # Search for playlists
                    results = self.sp.search(q=query, type='playlist', limit=3)
                    playlists = results.get('playlists', {}).get('items', [])
                    
                    for playlist in playlists:
                        if not playlist or len(all_tracks) >= limit:
                            break
                        
                        # Get tracks from playlist
                        try:
                            playlist_tracks = self.sp.playlist_tracks(
                                playlist['id'], 
                                limit=min(20, limit - len(all_tracks))
                            )
                            
                            for item in playlist_tracks.get('items', []):
                                if len(all_tracks) >= limit:
                                    break
                                    
                                track = item.get('track')
                                if not track or not track.get('id'):
                                    continue
                                
                                # Skip duplicates
                                if track['id'] in seen_track_ids:
                                    continue
                                seen_track_ids.add(track['id'])
                                
                                all_tracks.append({
                                    'id': track['id'],
                                    'title': track['name'],
                                    'artist': track['artists'][0]['name'] if track.get('artists') else 'Unknown',
                                    'album': track['album']['name'] if track.get('album') else '',
                                    'thumbnail': track['album']['images'][0]['url'] if track.get('album', {}).get('images') else None,
                                    'url': track['external_urls']['spotify'] if track.get('external_urls') else '',
                                    'duration': track.get('duration_ms', 0) / 1000 if track.get('duration_ms') else 0
                                })
                        except Exception as playlist_err:
                            print(f"Error fetching playlist tracks: {playlist_err}")
                            continue
                            
                except Exception as search_err:
                    print(f"Error searching for '{query}': {search_err}")
                    continue
            
            if all_tracks:
                db.set_cache(cache_key, all_tracks, ttl_seconds=3600)  # Cache for 1 hour
            
            return all_tracks
        except Exception as e:
            print(f"Spotify genre recommendations error: {e}")
            return []

    def get_available_genre_seeds(self):
        """Get list of available genre seeds (hardcoded fallback since API deprecated)"""
        # Return common genres since the recommendation_genre_seeds endpoint is deprecated
        return [
            "acoustic", "afrobeat", "alt-rock", "alternative", "ambient",
            "anime", "black-metal", "bluegrass", "blues", "bossanova",
            "brazil", "breakbeat", "british", "cantopop", "chicago-house",
            "children", "chill", "classical", "club", "comedy",
            "country", "dance", "dancehall", "death-metal", "deep-house",
            "detroit-techno", "disco", "disney", "drum-and-bass", "dub",
            "dubstep", "edm", "electro", "electronic", "emo",
            "folk", "forro", "french", "funk", "garage",
            "german", "gospel", "goth", "grindcore", "groove",
            "grunge", "guitar", "happy", "hard-rock", "hardcore",
            "hardstyle", "heavy-metal", "hip-hop", "holidays", "honky-tonk",
            "house", "idm", "indian", "indie", "indie-pop",
            "industrial", "iranian", "j-dance", "j-idol", "j-pop",
            "j-rock", "jazz", "k-pop", "kids", "latin",
            "latino", "malay", "mandopop", "metal", "metal-misc",
            "metalcore", "minimal-techno", "movies", "mpb", "new-age",
            "new-release", "opera", "pagode", "party", "philippines-opm",
            "piano", "pop", "pop-film", "post-dubstep", "power-pop",
            "progressive-house", "psych-rock", "punk", "punk-rock", "r-n-b",
            "rainy-day", "reggae", "reggaeton", "road-trip", "rock",
            "rock-n-roll", "rockabilly", "romance", "sad", "salsa",
            "samba", "sertanejo", "show-tunes", "singer-songwriter", "ska",
            "sleep", "songwriter", "soul", "soundtracks", "spanish",
            "study", "summer", "swedish", "synth-pop", "tango",
            "techno", "trance", "trip-hop", "turkish", "work-out", "world-music"
        ]

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

