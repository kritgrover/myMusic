import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
from config import settings
from database import db
import time
import json
from datetime import datetime, timezone
from urllib.parse import quote


class SpotifyCatalogError(RuntimeError):
    """The catalog could not be loaded completely; callers should offer retry."""


class SpotifyCapabilityError(SpotifyCatalogError):
    """This connection cannot access a Spotify feature; retry is not a remedy."""


class SpotifyService:

    def __init__(self):
        self.client_id = settings.SPOTIFY_CLIENT_ID
        self.client_secret = settings.SPOTIFY_CLIENT_SECRET
        self.sp = None
        self._authenticate()

    def _authenticate(self):
        try:
            if (not self.client_id or not self.client_secret
                    or self.client_id == "your_client_id_here"
                    or self.client_secret == "your_client_secret_here"):
                print("Spotify credentials not set (CLIENT_ID/CLIENT_SECRET) — "
                      "add them to backend/.env or the repo-root .env, then restart.")
                return

            client_credentials_manager = SpotifyClientCredentials(
                client_id=self.client_id,
                client_secret=self.client_secret
            )
            self.sp = spotipy.Spotify(
                client_credentials_manager=client_credentials_manager,
                requests_timeout=6, retries=0, status_retries=0,
            )
        except Exception as e:
            print(f"Failed to authenticate with Spotify: {e}")
            self.sp = None

    def _get_cache_key(self, prefix, *args):
        return f"{prefix}:{':'.join(str(arg) for arg in args)}"

    def catalog_status(self):
        return {
            'status': 'configured' if self.sp is not None else 'unconfigured',
            'authorization': 'client_credentials',
            'playlist_contents': 'restricted',
            'message': (
                'Spotify catalog search is configured. Playlist contents require Spotify user access '
                'and may be unavailable with this connection.' if self.sp is not None else
                'Spotify catalog search is not configured. Your saved music is still available.'
            ),
        }

    @staticmethod

    def _image(images):
        return next((image.get('url') for image in images or []
                     if isinstance(image, dict) and image.get('url')), None)

    @staticmethod

    def _credited_to(item, artist_id):
        return any(artist.get('id') == artist_id for artist in item.get('artists') or []
                   if isinstance(artist, dict))

    def _search_items(self, query, kind, limit=10, *, market='US', deadline=None):
        """Bounded discovery search, with the Development Mode page size of 10.

        Discovery intentionally selects a small candidate pool, rather than
        claiming to return every match. Album/discography reads use the stricter
        complete pagination helper below.
        """
        wanted = min(50, max(1, int(limit)))
        deadline = deadline if deadline is not None else time.monotonic() + 15
        items, seen = [], set()
        offset = 0
        for _ in range(5):
            if time.monotonic() >= deadline or len(items) >= wanted:
                break
            size = min(10, wanted - len(items))
            response = self.sp.search(q=query, type=kind, limit=size, offset=offset, market=market)
            page = response.get(kind + 's') if isinstance(response, dict) else None
            if not isinstance(page, dict) or not isinstance(page.get('items'), list):
                raise SpotifyCatalogError('The music catalog returned an invalid search response. Please retry.')
            batch = page['items']
            for item in batch:
                if isinstance(item, dict) and item.get('id') and item['id'] not in seen:
                    seen.add(item['id'])
                    items.append(item)
            offset += len(batch)
            if (len(batch) < size or ('next' in page and not page['next'])
                    or (isinstance(page.get('total'), int) and offset >= page['total'])):
                break
        return items[:wanted]

    def _artist_tracks(self, artist_id, limit=10, *, deadline=None):
        deadline = deadline if deadline is not None else time.monotonic() + 15
        artist = self.get_artist(artist_id)
        if not artist or not artist.get('name'):
            return []
        name = artist['name'].replace('"', '')
        candidates = self._search_items(f'artist:"{name}"', 'track', min(30, limit * 2), deadline=deadline)
        return [self._format_track(track) for track in candidates
                if self._credited_to(track, artist_id)][:limit]

    def _format_album(self, album, *, group=None):
        artists = [a for a in album.get('artists') or [] if isinstance(a, dict)]
        return {
            'id': album.get('id'), 'name': album.get('name', ''),
            'artist': artists[0].get('name', '') if artists else '',
            'artist_id': artists[0].get('id') if artists else None,
            'type': album.get('album_type', 'album'),
            'group': group or album.get('album_type', 'album'),
            'total_tracks': album.get('total_tracks'),
            'release_date': album.get('release_date', ''),
            'thumbnail': self._image(album.get('images')),
            'url': (album.get('external_urls') or {}).get('spotify', ''),
        }

    def _catalog_pages(self, fetch_page, page_size, *, max_pages=500, deadline=None, allow_repeats=False):
        """Read every provider page or fail explicitly, never return a partial list.

        Request offsets ourselves instead of following arbitrary next URLs. The
        page and time guards protect against broken pagination and rate limits;
        a guarded response must not be cached as a complete discography.
        """
        offset = 0
        deadline = deadline if deadline is not None else time.monotonic() + 45
        page_signatures = set()
        items = []
        for _ in range(max_pages):
            if time.monotonic() > deadline:
                raise SpotifyCatalogError('The catalog is taking too long. Please retry.')
            page = fetch_page(offset, page_size)
            if not isinstance(page, dict) or not isinstance(page.get('items'), list):
                raise SpotifyCatalogError('The catalog returned an invalid page. Please retry.')
            if page.get('offset', offset) != offset:
                raise SpotifyCatalogError('The catalog returned an unexpected page. Please retry.')
            batch = page['items']
            signature = json.dumps(batch, sort_keys=True, separators=(',', ':'))
            if batch and signature in page_signatures and not allow_repeats:
                raise SpotifyCatalogError('The catalog repeated a page. Please retry.')
            page_signatures.add(signature)
            items.extend(item for item in batch if isinstance(item, dict))
            offset += len(batch)
            if not page.get('next'):
                total = page.get('total')
                if isinstance(total, int) and offset < total:
                    raise SpotifyCatalogError('The catalog response was incomplete. Please retry.')
                return items
            if not batch:
                raise SpotifyCatalogError('The catalog response was incomplete. Please retry.')
        raise SpotifyCatalogError('The catalog has too many pages to load. Please retry.')

    def search_track(self, title, artist):
        if not self.sp:
            return None
        cache_key = self._get_cache_key('track_search_v3', title, artist)
        cached = db.get_cache(cache_key)
        if cached:
            return cached
        for query in (f'track:{title} artist:{artist}', f'{title} {artist}'):
            result = self._search_spotify_raw(query)
            if result:
                db.set_cache(cache_key, result, ttl_seconds=86400 * 7)
                return result
        return None

    def _search_spotify_raw(self, query: str):
        if not self.sp:
            return None
        try:
            items = self._search_items(query, 'track', 1)
            if items:
                result = self._format_track(items[0])
                result.update(name=result['title'], image=result['thumbnail'],
                              preview_url=items[0].get('preview_url'))
                return result
        except Exception:
            pass
        return None

    def search_track_multi_strategy(self, parsed_title: str, parsed_artist: str,
                                     cleaned_yt_title: str) -> list[dict | None]:
        """Try multiple Spotify search strategies and return all results.

        Returns a list of result dicts (or Nones). The caller scores and picks
        the best match.
        """
        if not self.sp:
            return []

        seen_ids = set()
        results = []

        def _add(result):
            if result and result.get("id") not in seen_ids:
                seen_ids.add(result["id"])
                results.append(result)

        cache_key = self._get_cache_key("multi_v3", parsed_title, parsed_artist, cleaned_yt_title)
        cached = db.get_cache(cache_key)
        if cached:
            return cached

        # Strategy 1: strict parsed title + artist
        if parsed_title and parsed_artist:
            _add(self._search_spotify_raw(f"track:{parsed_title} artist:{parsed_artist}"))

        # Strategy 2: swapped — in case regex got artist/title backwards
        if parsed_title and parsed_artist and parsed_title != parsed_artist:
            _add(self._search_spotify_raw(f"track:{parsed_artist} artist:{parsed_title}"))

        # Strategy 3: general search with the full cleaned YouTube title
        if cleaned_yt_title:
            _add(self._search_spotify_raw(cleaned_yt_title))

        # Strategy 4: broad search combining parsed fields without Spotify field syntax
        if parsed_title and parsed_artist:
            _add(self._search_spotify_raw(f"{parsed_title} {parsed_artist}"))

        if results:
            db.set_cache(cache_key, results, ttl_seconds=86400 * 7)

        return results

    def get_recommendations(self, seed_tracks=None, seed_artists=None, seed_genres=None, limit=20):
        """Build a varied candidate pool using supported catalog search calls."""
        if not self.sp:
            return []
        limit = min(50, max(1, int(limit)))
        cache_key = self._get_cache_key('recs_search_v3', seed_tracks, seed_artists, seed_genres, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        deadline = time.monotonic() + 15
        artist_ids = list(dict.fromkeys(seed_artists or []))[:2]
        genres = list(dict.fromkeys(seed_genres or []))[:2]
        candidates, seen = [], set(seed_tracks or [])

        def add(track):
            if track.get('id') and track['id'] not in seen:
                seen.add(track['id'])
                candidates.append(track)

        # A track seed supplies an exact artist identity, never a same-name guess.
        for track_id in (seed_tracks or [])[:2]:
            if len(artist_ids) >= 2 or time.monotonic() >= deadline:
                break
            try:
                track = self.sp.track(track_id)
                for artist in track.get('artists') or []:
                    if artist.get('id') and artist['id'] not in artist_ids:
                        artist_ids.append(artist['id'])
                        break
            except Exception:
                continue
        if not genres:
            for artist_id in artist_ids:
                if time.monotonic() >= deadline:
                    break
                profile = self.get_artist(artist_id) or {}
                genres.extend(g for g in profile.get('genres', []) if g not in genres)
                if len(genres) >= 2:
                    break
        # Genre search contributes unfamiliar artists; artist search contributes
        # other recordings from familiar artists. Ranking happens per listener.
        for genre in genres[:2]:
            if time.monotonic() >= deadline:
                break
            try:
                term = str(genre).replace('"', '')
                for track in self._search_items(f'genre:"{term}"', 'track', 10, deadline=deadline):
                    add(self._format_track(track))
            except Exception:
                continue
        for artist_id in artist_ids[:2]:
            if time.monotonic() >= deadline:
                break
            try:
                for track in self._artist_tracks(artist_id, limit=10, deadline=deadline):
                    add(track)
            except Exception:
                continue
        if candidates:
            db.set_cache(cache_key, candidates[:limit], ttl_seconds=3600)
        return candidates[:limit]

    def _format_track(self, track):
        """Keep canonical catalog identity and album artwork with every track."""
        artists = [a for a in track.get('artists') or [] if isinstance(a, dict)]
        album = track.get('album') or {}
        track_id = track.get('id') or ''
        return {
            'id': track_id, 'spotify_id': track_id,
            'title': track.get('name', ''),
            'artist': artists[0].get('name', 'Unknown') if artists else 'Unknown',
            'artist_id': artists[0].get('id') if artists else None,
            'artist_ids': [a['id'] for a in artists if a.get('id')],
            'album': album.get('name', ''), 'album_id': album.get('id'),
            'thumbnail': self._image(album.get('images')),
            'url': (track.get('external_urls') or {}).get('spotify') or
                   (f'https://open.spotify.com/track/{track_id}' if track_id else ''),
            'duration': (track.get('duration_ms') or 0) / 1000,
        }

    def get_artist_new_releases(self, artist_id, limit=5):
        if not self.sp:
            return []
        limit = min(20, max(1, int(limit)))
        cache_key = self._get_cache_key('artist_releases_verified_v2', artist_id, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            # The artist endpoint supplies release relationships; verify IDs to
            # exclude same-name artists and wrongly attributed compilations.
            response = self.sp.artist_albums(artist_id, album_type='album,single',
                                             limit=min(50, limit), country='US')
            albums = [self._format_album(album) for album in response.get('items', [])
                      if isinstance(album, dict) and album.get('id')
                      and self._credited_to(album, artist_id)]
            albums.sort(key=lambda item: item['release_date'], reverse=True)
            db.set_cache(cache_key, albums[:limit], ttl_seconds=3600)
            return albums[:limit]
        except Exception:
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
        """Find genre tracks directly; public playlist contents are restricted."""
        if not self.sp:
            return []
        limit = min(50, max(1, int(limit)))
        term = str(genre or '').strip().replace('"', '')
        if not term:
            return []
        cache_key = self._get_cache_key('genre_tracks_search_v3', term.casefold(), limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            tracks = [self._format_track(track) for track in
                      self._search_items(f'genre:"{term}"', 'track', limit)]
            if tracks:
                db.set_cache(cache_key, tracks, ttl_seconds=3600)
            return tracks
        except Exception:
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

    def get_album_tracks(self, album_id, limit=50, market='US'):
        """Get every available track, in disc/track order, including box sets."""
        if not self.sp:
            raise SpotifyCatalogError('The music catalog is unavailable. Please retry.')
        cache_key = self._get_cache_key("album_tracks_complete_v1", album_id, market)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            items = self._catalog_pages(
                lambda offset, size: self.sp.album_tracks(
                    album_id, limit=size, offset=offset, market=market),
                min(50, max(1, int(limit))),
            )
            tracks = []
            seen = set()
            for item in items:
                if not item.get('id') or item['id'] in seen:
                    continue
                seen.add(item['id'])
                track = self._format_track(item)
                track.update(album_id=album_id,
                             disc_number=item.get('disc_number', 1),
                             track_number=item.get('track_number', 0))
                tracks.append(track)
            tracks.sort(key=lambda track: (track['disc_number'], track['track_number']))
            db.set_cache(cache_key, tracks, ttl_seconds=3600)
            return tracks
        except SpotifyCatalogError:
            raise
        except Exception as e:
            print(f"Error getting album tracks: {e}")
            raise SpotifyCatalogError('Could not load the album tracks. Please retry.') from e

    def get_new_releases(self, country='US', limit=20):
        """Recent album selections from search, without the removed browse API."""
        if not self.sp:
            return []
        year = datetime.now(timezone.utc).year
        cache_key = self._get_cache_key('recent_album_search_v2', country, year, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            albums = [self._format_album(album) for album in self._search_items(
                f'year:{year - 1}-{year}', 'album', limit, market=country)]
            albums.sort(key=lambda item: item['release_date'], reverse=True)
            if albums:
                db.set_cache(cache_key, albums, ttl_seconds=3600)
            return albums
        except Exception:
            return []

    def get_genre_playlists(self, genre, limit=10):
        """Playlist metadata remains searchable even when contents are restricted."""
        return self.get_curated_playlists([str(genre)], limit=limit)

    def get_playlist_tracks(self, playlist_id, limit=50):
        if not self.sp:
            raise SpotifyCatalogError('Spotify catalog search is unavailable. Please retry.')
        restricted = ('Spotify does not allow this catalog connection to read these playlist contents. '
                      'Search for the songs or import a playlist CSV instead.')
        cache_key = self._get_cache_key('playlist_items_complete_v3', playlist_id)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            def fetch(offset, size):
                # Spotipy 2.x's playlist_items still targets the old /tracks URL.
                # Its authenticated transport lets us use the current endpoint.
                page = self.sp._get(f'playlists/{quote(str(playlist_id), safe="")}/items',
                                    limit=size, offset=offset, market='US', additional_types='track')
                if isinstance(page, dict) and 'items' not in page:
                    raise SpotifyCapabilityError(restricted)
                return page
            # Playlists may intentionally repeat the same recordings, including
            # across page boundaries. Offset/total/deadline guards still apply.
            items = self._catalog_pages(fetch, min(50, max(1, int(limit))), allow_repeats=True)
            tracks = []
            for item in items:
                track = item.get('item') or item.get('track')
                if not isinstance(track, dict) or not track.get('id') or track.get('type', 'track') != 'track':
                    continue
                tracks.append(self._format_track(track))
            db.set_cache(cache_key, tracks, ttl_seconds=3600)
            return tracks
        except SpotifyCatalogError:
            raise
        except Exception as exc:
            if getattr(exc, 'http_status', None) in (403, 404):
                raise SpotifyCapabilityError(restricted) from None
            raise SpotifyCatalogError('Could not load the playlist tracks. Please retry.') from None
    # ------------------------------------------------------------------
    # Discovery helpers (curated playlists, moods, artists, albums)
    # ------------------------------------------------------------------

    def _format_artist(self, artist):
        """Format a Spotify artist object into our standard shape."""
        if not artist:
            return None
        images = artist.get('images') or []
        followers = artist.get('followers') or {}
        return {
            'id': artist.get('id'),
            'name': artist.get('name', 'Unknown'),
            'thumbnail': images[0]['url'] if images else None,
            'genres': artist.get('genres') or [],
            'followers': followers.get('total'),
        }

    def _format_playlist(self, pl):
        """Format a Spotify playlist object into our standard shape."""
        if not pl:
            return None
        images = pl.get('images') or []
        owner = pl.get('owner') or {}
        return {
            'id': pl.get('id'),
            'name': pl.get('name', ''),
            'description': pl.get('description', ''),
            'thumbnail': images[0]['url'] if images else None,
            'url': pl.get('external_urls', {}).get('spotify', ''),
            'owner': owner.get('display_name', ''),
        }

    def get_curated_playlists(self, queries, limit=12):
        """Search Spotify playlists by free-text queries; returns playlist objects.

        Generalizes get_genre_playlists to arbitrary search terms so it can power
        mood/activity and themed playlist rows (featured-playlists API is deprecated).
        """
        if not self.sp:
            return []
        if isinstance(queries, str):
            queries = [queries]

        cache_key = self._get_cache_key("curated_pl", "|".join(queries), limit)
        cached = db.get_cache(cache_key)
        if cached:
            return cached

        playlists = []
        seen_ids = set()
        try:
            for query in queries:
                if len(playlists) >= limit:
                    break
                try:
                    results = self.sp.search(q=query, type='playlist', limit=min(10, limit))
                    for pl in results.get('playlists', {}).get('items', []):
                        if not pl or pl.get('id') in seen_ids:
                            continue
                        formatted = self._format_playlist(pl)
                        if not formatted or not formatted['id']:
                            continue
                        seen_ids.add(formatted['id'])
                        playlists.append(formatted)
                        if len(playlists) >= limit:
                            break
                except Exception as e:
                    print(f"Curated playlist search error for '{query}': {e}")
                    continue
            if playlists:
                db.set_cache(cache_key, playlists, ttl_seconds=86400)  # Cache for 1 day
            return playlists
        except Exception as e:
            print(f"Spotify curated playlists error: {e}")
            return []

    def get_moods(self):
        """Ordered list of mood/activity categories (rendered as gradient cards)."""
        return [
            "Workout", "Chill", "Focus", "Party", "Sleep",
            "Romance", "Commute", "Throwback", "Happy", "Sad",
        ]

    def get_mood_playlists(self, mood, limit=12):
        """Playlists for a mood/activity, built from curated playlist search."""
        mood_queries = {
            'workout': ['workout', 'gym workout', 'beast mode'],
            'chill': ['chill', 'chill vibes', 'lofi chill'],
            'focus': ['focus', 'deep focus', 'concentration'],
            'party': ['party hits', 'dance party', 'party'],
            'sleep': ['sleep', 'deep sleep', 'calm sleep'],
            'romance': ['love songs', 'romance', 'romantic'],
            'commute': ['commute', 'road trip', 'driving'],
            'throwback': ['throwback', '2000s hits', 'oldies'],
            'happy': ['happy', 'feel good', 'good vibes'],
            'sad': ['sad songs', 'heartbreak', 'sad'],
        }
        key = (mood or '').strip().lower()
        queries = mood_queries.get(key, [mood, f"{mood} hits"])
        return self.get_curated_playlists(queries, limit=limit)

    def get_artist(self, artist_id):
        """Fetch an artist profile (name, image, genres, followers)."""
        if not self.sp:
            return None
        cache_key = self._get_cache_key("artist_profile", artist_id)
        cached = db.get_cache(cache_key)
        if cached:
            return cached
        try:
            result = self._format_artist(self.sp.artist(artist_id))
            if result:
                db.set_cache(cache_key, result, ttl_seconds=86400 * 7)  # Cache for 1 week
            return result
        except Exception as e:
            print(f"Error getting artist {artist_id}: {e}")
            return None

    def get_artist_top_tracks(self, artist_id, limit=10):
        """Artist track selections; Spotify's removed popularity endpoint is unused."""
        if not self.sp:
            return []
        cache_key = self._get_cache_key('artist_tracks_search_v2', artist_id, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            tracks = self._artist_tracks(artist_id, limit=limit)
            if tracks:
                db.set_cache(cache_key, tracks, ttl_seconds=3600)
            return tracks
        except Exception:
            return []

    def _album_contains_artist(self, album_id, artist_id, market, deadline):
        cache_key = self._get_cache_key('album_artist_credit_v1', album_id, artist_id, market)
        cached = db.get_cache(cache_key)
        if isinstance(cached, bool):
            return cached
        offset, seen_pages = 0, set()
        for _ in range(500):
            if time.monotonic() >= deadline:
                raise SpotifyCatalogError('The catalog is taking too long. Please retry.')
            page = self.sp.album_tracks(album_id, limit=50, offset=offset, market=market)
            if (not isinstance(page, dict) or not isinstance(page.get('items'), list)
                    or page.get('offset', offset) != offset):
                raise SpotifyCatalogError('The catalog returned an invalid page. Please retry.')
            items = page['items']
            signature = json.dumps(items, sort_keys=True, separators=(',', ':'))
            if items and signature in seen_pages:
                raise SpotifyCatalogError('The catalog repeated a page. Please retry.')
            seen_pages.add(signature)
            if any(self._credited_to(track, artist_id) for track in items if isinstance(track, dict)):
                # One exact track credit proves the appearance. Do not download
                # the rest of a large compilation just to reconfirm it.
                db.set_cache(cache_key, True, ttl_seconds=86400 * 7)
                return True
            offset += len(items)
            if not page.get('next'):
                if isinstance(page.get('total'), int) and offset < page['total']:
                    raise SpotifyCatalogError('The catalog response was incomplete. Please retry.')
                db.set_cache(cache_key, False, ttl_seconds=86400 * 7)
                return False
            if not items:
                raise SpotifyCatalogError('The catalog response was incomplete. Please retry.')
        raise SpotifyCatalogError('The catalog has too many pages to load. Please retry.')

    def get_artist_albums(self, artist_id, limit=10, market='US'):
        """Complete release pages with exact artist credit and explicit appearances."""
        if not self.sp:
            raise SpotifyCatalogError('The music catalog is unavailable. Please retry.')
        cache_key = self._get_cache_key('artist_discography_verified_v3', artist_id, market)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            deadline = time.monotonic() + 45
            items = self._catalog_pages(
                lambda offset, size: self.sp.artist_albums(
                    artist_id, album_type='album,single,compilation',
                    limit=size, offset=offset, country=market),
                min(50, max(1, int(limit))), deadline=deadline)
            appearances = self._catalog_pages(
                lambda offset, size: self.sp.artist_albums(
                    artist_id, album_type='appears_on',
                    limit=size, offset=offset, country=market),
                min(50, max(1, int(limit))), deadline=deadline)
            albums, seen = [], set()
            for album, appearance in ([(item, False) for item in items] +
                                      [(item, True) for item in appearances]):
                album_id = album.get('id')
                if not album_id or album_id in seen:
                    continue
                appearance = appearance or album.get('album_group') == 'appears_on'
                if not self._credited_to(album, artist_id):
                    # An album attributed to a different primary artist belongs
                    # here only when this exact artist has a verified track credit.
                    if not appearance or not self._album_contains_artist(
                            album_id, artist_id, market, deadline):
                        continue
                seen.add(album_id)
                group = 'appears_on' if appearance else album.get('album_type', 'album')
                albums.append(self._format_album(album, group=group))
            albums.sort(key=lambda item: item['release_date'], reverse=True)
            db.set_cache(cache_key, albums, ttl_seconds=3600)
            return albums
        except SpotifyCatalogError:
            raise
        except Exception:
            raise SpotifyCatalogError('Could not load the discography. Please retry.') from None

    def get_related_artists(self, artist_id, limit=12):
        """Similar-genre artist selections using supported artist search."""
        if not self.sp:
            return []
        cache_key = self._get_cache_key('similar_genre_artists_v2', artist_id, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        artist = self.get_artist(artist_id) or {}
        artists, seen = [], {artist_id}
        for genre in artist.get('genres', [])[:2]:
            term = str(genre).replace('"', '')
            for candidate in self.search_artists(f'genre:"{term}"', limit=min(10, limit)):
                if candidate['id'] not in seen:
                    seen.add(candidate['id'])
                    artists.append(candidate)
            if len(artists) >= limit:
                break
        if artists:
            db.set_cache(cache_key, artists[:limit], ttl_seconds=3600)
        return artists[:limit]

    def search_artists(self, query, limit=12):
        """Artist search paginated within the Development Mode limit of ten."""
        if not self.sp:
            return []
        cache_key = self._get_cache_key('search_artists_paged_v2', query, limit)
        cached = db.get_cache(cache_key)
        if cached is not None:
            return cached
        try:
            artists = [self._format_artist(artist) for artist in
                       self._search_items(query, 'artist', limit)]
            if artists:
                db.set_cache(cache_key, artists, ttl_seconds=3600)
            return artists
        except Exception:
            return []

    def get_recommended_artists(self, seed_artist_ids=None, fallback_query=None, limit=12):
        """Recommend artists from related artists of seeds, with a search fallback."""
        if not self.sp:
            return []
        artists = []
        seen = set()
        if seed_artist_ids:
            for sid in [s for s in seed_artist_ids if s][:3]:
                for a in self.get_related_artists(sid, limit=8):
                    if a['id'] and a['id'] not in seen:
                        seen.add(a['id'])
                        artists.append(a)
                    if len(artists) >= limit:
                        break
                if len(artists) >= limit:
                    break
        if len(artists) < limit and fallback_query:
            for a in self.search_artists(fallback_query, limit=limit):
                if a['id'] and a['id'] not in seen:
                    seen.add(a['id'])
                    artists.append(a)
                if len(artists) >= limit:
                    break
        return artists[:limit]

    def get_album(self, album_id):
        """Fetch album metadata (name, artist, cover, release date, track count)."""
        if not self.sp:
            return None
        cache_key = self._get_cache_key("album_meta", album_id)
        cached = db.get_cache(cache_key)
        if cached:
            return cached
        try:
            album = self.sp.album(album_id)
            images = album.get('images') or []
            artists = album.get('artists') or []
            result = {
                'id': album['id'],
                'name': album['name'],
                'artist': artists[0]['name'] if artists else '',
                'artist_id': artists[0]['id'] if artists else None,
                'thumbnail': images[0]['url'] if images else None,
                'release_date': album.get('release_date', ''),
                'total_tracks': album.get('total_tracks', 0),
                'type': album.get('album_type', 'album'),
                'url': album.get('external_urls', {}).get('spotify', ''),
            }
            db.set_cache(cache_key, result, ttl_seconds=86400 * 7)  # Cache for 1 week
            return result
        except Exception as e:
            print(f"Error getting album {album_id}: {e}")
            return None

spotify_service = SpotifyService()

