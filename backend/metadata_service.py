import re
import json
import subprocess
import asyncio
import hashlib
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from database import db


KNOWN_RECORD_LABELS = {
    "atlantic records", "atlantic", "warner music", "warner records",
    "warner bros records", "warner bros", "universal music", "universal",
    "sony music", "sony", "columbia records", "columbia", "rca records",
    "rca", "interscope records", "interscope", "republic records",
    "republic", "def jam", "def jam recordings", "island records",
    "island", "capitol records", "capitol", "epic records", "epic",
    "parlophone", "polydor", "virgin records", "virgin", "elektra",
    "elektra records", "geffen records", "geffen", "a&m records",
    "motown", "motown records", "mercury records", "mercury",
    "hollywood records", "hollywood", "arista records", "arista",
    "jive records", "jive", "laface records", "laface",
    "bad boy records", "bad boy", "young money", "cash money",
    "top dawg entertainment", "tde", "aftermath entertainment",
    "aftermath", "shady records", "dreamville", "dreamville records",
    "ovo sound", "good music", "getting out our dreams",
    "fueled by ramen", "fearless records", "hopeless records",
    "epitaph records", "epitaph", "roadrunner records", "roadrunner",
    "nuclear blast", "nuclear blast records", "metal blade",
    "metal blade records", "sumerian records", "sumerian",
    "rise records", "rise", "spinefarm records", "spinefarm",
    "loma vista", "loma vista recordings",
    "monstercat", "ncs", "nocopyrightsounds", "proximity",
    "trap nation", "bass nation", "mr suicide sheep",
    "majestic casual", "the vibe guide", "selected",
    "ultra music", "ultra records", "spinnin records", "spinnin",
    "armada music", "armada", "musical freedom", "revealed recordings",
    "owsla", "mad decent", "dim mak", "dim mak records",
    "big beat records", "astralwerks", "because music",
    "domino recording", "domino", "xl recordings", "xl",
    "rough trade", "rough trade records", "4ad", "matador",
    "matador records", "sub pop", "sub pop records", "merge records",
    "merge", "warp records", "warp", "ninja tune",
    "stones throw", "stones throw records", "rhymesayers",
    "rhymesayers entertainment", "top dawg", "mass appeal",
    "mass appeal records", "300 entertainment", "quality control",
    "quality control music", "capitol music group", "umg",
    "smg", "wmg", "bmg", "cmg",
    "t series", "tseries", "zee music company", "zee music",
    "speed records", "tips official", "tips", "saregama",
    "yrf", "eros now", "sony music india",
}

YT_NOISE_PATTERN = re.compile(
    r'\s*[(\[]\s*'
    r'(?:official\s+(?:music\s+)?video|official\s+audio|official\s+lyric\s*video|'
    r'official\s+visualizer|lyric\s*video|lyrics?\s*(?:video)?|'
    r'audio|visualizer|music\s+video|'
    r'hd|hq|4k|remastered(?:\s+\d{4})?|'
    r'explicit|clean\s+version|deluxe(?:\s+edition)?|bonus\s+track)'
    r'\s*[)\]]\s*',
    re.IGNORECASE,
)

TRAILING_LABEL_PATTERN = re.compile(
    r'\s*[-|]\s*(?:official\s+(?:music\s+)?video|official\s+audio|'
    r'lyric\s*video|lyrics?|audio|visualizer|music\s+video)\s*$',
    re.IGNORECASE,
)


def _normalize(text: str) -> str:
    if not text:
        return ""
    return re.sub(r'[^\w\s]', '', text.lower()).strip()


def _clean_uploader(raw_uploader: str) -> str:
    clean = raw_uploader.strip()
    if clean.upper().endswith("VEVO"):
        clean = clean[:-4]
        clean = re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', clean).strip()
    clean = re.sub(r'\s*-\s*topic\s*$', '', clean, flags=re.IGNORECASE).strip()
    clean = re.sub(r'\s+official\s*$', '', clean, flags=re.IGNORECASE).strip()
    return clean


def _is_record_label(name: str) -> bool:
    return _normalize(name) in KNOWN_RECORD_LABELS


def _strip_yt_noise(title: str) -> str:
    cleaned = title
    prev = None
    while cleaned != prev:
        prev = cleaned
        cleaned = YT_NOISE_PATTERN.sub(' ', cleaned).strip()
    cleaned = TRAILING_LABEL_PATTERN.sub('', cleaned).strip()
    cleaned = re.sub(r'\s*[-|]+\s*$', '', cleaned).strip()
    return cleaned


def _regex_parse(title: str, uploader: str) -> dict:
    """Parse YouTube title + uploader into song title and artist using regex heuristics."""
    raw_title = (title or "").strip()
    raw_uploader = (uploader or "").strip()

    clean_uploader = _clean_uploader(raw_uploader)
    cleaned = _strip_yt_noise(raw_title)

    song_title = cleaned
    artist = ""

    norm_uploader = _normalize(clean_uploader)
    uploader_is_label = _is_record_label(clean_uploader) or _is_record_label(raw_uploader)

    if " - " in cleaned:
        left, right = cleaned.split(" - ", 1)
        left, right = left.strip(), right.strip()
        norm_left = _normalize(left)
        norm_right = _normalize(right)

        if not uploader_is_label:
            left_matches = norm_uploader and (
                norm_left == norm_uploader
                or norm_uploader in norm_left
                or norm_left in norm_uploader
            )
            right_matches = norm_uploader and (
                norm_right == norm_uploader
                or norm_uploader in norm_right
                or norm_right in norm_uploader
            )

            if left_matches and not right_matches:
                artist = left
                song_title = right
            elif right_matches and not left_matches:
                artist = right
                song_title = left
            else:
                artist = left
                song_title = right
        else:
            artist = left
            song_title = right
    elif norm_uploader and not uploader_is_label:
        artist = clean_uploader
        song_title = cleaned

    song_title = re.sub(r'^[-–—]\s*', '', song_title).strip()
    song_title = re.sub(r'\s*[-–—]$', '', song_title).strip()

    return {"title": song_title, "artist": artist}


def _similarity(a: str, b: str) -> float:
    """Simple word-overlap similarity between two strings (0.0 to 1.0)."""
    na, nb = _normalize(a), _normalize(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0
    words_a = set(na.split())
    words_b = set(nb.split())
    if not words_a or not words_b:
        return 0.0
    intersection = words_a & words_b
    return len(intersection) / max(len(words_a), len(words_b))


def _score_spotify_match(spotify_result: dict, youtube_title: str, uploader: str) -> float:
    """Score how well a Spotify result matches the original YouTube video.

    Returns a score from 0.0 to 100.0 where higher is better.
    """
    sp_title = spotify_result.get("name", "") or spotify_result.get("title", "")
    sp_artist = spotify_result.get("artist", "")

    cleaned_yt = _strip_yt_noise(youtube_title)
    norm_yt = _normalize(cleaned_yt)
    norm_up = _normalize(_clean_uploader(uploader))

    score = 0.0

    norm_sp_title = _normalize(sp_title)
    norm_sp_artist = _normalize(sp_artist)

    # Title appears in YouTube title (40 pts max)
    if norm_sp_title and norm_sp_title in norm_yt:
        score += 40
    elif norm_sp_title:
        sim = _similarity(sp_title, cleaned_yt)
        score += sim * 30

    # Artist appears in YouTube title or matches uploader (40 pts max)
    if norm_sp_artist:
        if norm_sp_artist in norm_yt:
            score += 35
        if norm_sp_artist == norm_up or norm_sp_artist in norm_up or norm_up in norm_sp_artist:
            score += 5
        elif _similarity(sp_artist, uploader) > 0.5:
            score += 3

    # Both track title AND artist found within the YouTube title (20 pts bonus)
    if norm_sp_title in norm_yt and norm_sp_artist in norm_yt:
        score += 20

    return min(score, 100.0)


class MetadataService:
    def __init__(self, download_service=None, spotify_service=None, *,
                 max_workers=2, response_timeout=0.75, work_timeout=12.0):
        if max_workers < 1 or response_timeout <= 0 or work_timeout <= 0:
            raise ValueError('Metadata worker limits and timeouts must be positive.')
        self._dl = download_service
        self._spotify = spotify_service
        self._max_workers = max_workers
        self._response_timeout = response_timeout
        self._work_timeout = work_timeout
        self._pool = None
        self._pending = {}
        self._lock = threading.Lock()
        self._closed = False

    @staticmethod
    def fallback(title, uploader=''):
        return {**_regex_parse(title, uploader), 'album': '', 'spotify_id': '',
                'thumbnail': '', 'source': 'regex_parsed'}

    @staticmethod
    def _request_key(title, uploader='', video_id=None, video_url=None):
        # Caller-supplied labels must not share a persistent cache entry with
        # different labels for the same video. This also versions old guesses.
        identity = json.dumps([video_id or '', video_url or '', title, uploader],
                              ensure_ascii=False, separators=(',', ':'))
        return 'metadata-v2:' + hashlib.sha256(identity.encode()).hexdigest()

    async def resolve_async(self, title, uploader='', video_id=None, video_url=None):
        """Bound request latency while at most two enrichment jobs run.

        A timed-out/disconnected caller does not cancel shared work or free its
        slot early. Completed enrichment may warm only its exact request cache.
        There is no waiting-job queue: saturation immediately returns labels.
        """
        fallback = self.fallback(title, uploader)
        key = self._request_key(title, uploader, video_id, video_url)
        added = False
        with self._lock:
            if self._closed:
                return fallback
            future = self._pending.get(key)
            if future is None:
                if len(self._pending) >= self._max_workers:
                    return fallback
                if self._pool is None:
                    self._pool = ThreadPoolExecutor(max_workers=self._max_workers,
                                                    thread_name_prefix='music-metadata')
                future = self._pool.submit(self.resolve, title, uploader, video_id, video_url)
                self._pending[key] = future
                added = True
        if added:
            def complete(done):
                with self._lock:
                    if self._pending.get(key) is done:
                        self._pending.pop(key, None)
            # Register outside the lock: already-finished futures call it inline.
            future.add_done_callback(complete)
        wrapped = asyncio.wrap_future(future)
        # The caller may time out before a provider fails. Retrieve exceptions
        # on the loop wrapper too, avoiding unhandled-future diagnostics.
        wrapped.add_done_callback(lambda done: None if done.cancelled() else done.exception())
        try:
            return await asyncio.wait_for(asyncio.shield(wrapped), self._response_timeout)
        except Exception:
            return fallback

    def close(self):
        """Stop new enrichment; never block server shutdown on an external call."""
        with self._lock:
            self._closed = True
            pool = self._pool
        if pool is not None:
            pool.shutdown(wait=False, cancel_futures=True)

    def resolve(self, title: str, uploader: str = "",
                video_id: str = None, video_url: str = None) -> dict:
        """Resolve song metadata through multiple layers.

        Returns dict with keys: title, artist, album, spotify_id, thumbnail, source
        """
        deadline = time.monotonic() + self._work_timeout
        cache_key = self._request_key(title, uploader, video_id, video_url)
        if video_id:
            cached = db.get_metadata_cache(cache_key)
            if cached:
                return cached

        # Layer 1: yt-dlp structured metadata
        ytdlp_meta = None
        if video_url and self._dl:
            ytdlp_meta = self._extract_ytdlp_metadata(video_url, deadline=deadline)

        if ytdlp_meta and ytdlp_meta.get("title") and ytdlp_meta.get("artist"):
            result = {
                "title": ytdlp_meta["title"],
                "artist": ytdlp_meta["artist"],
                "album": ytdlp_meta.get("album", ""),
                "spotify_id": "",
                "thumbnail": "",
                "source": "ytdlp_structured",
            }
            spotify_enriched = self._spotify_validate(
                result["title"], result["artist"], title, uploader, deadline=deadline
            )
            if spotify_enriched:
                result["spotify_id"] = spotify_enriched.get("id", "")
                result["thumbnail"] = spotify_enriched.get("thumbnail", "")
                if not result["album"]:
                    result["album"] = spotify_enriched.get("album", "")
                result["source"] = "ytdlp_structured+spotify"

            if video_id:
                db.set_metadata_cache(cache_key, result)
            return result

        # Layer 2: regex parsing
        parsed = _regex_parse(title, uploader)

        # Layer 3: Spotify validation
        spotify_result = self._spotify_validate(
            parsed["title"], parsed["artist"], title, uploader, deadline=deadline
        )

        if spotify_result:
            result = {
                "title": spotify_result["title"],
                "artist": spotify_result["artist"],
                "album": spotify_result.get("album", ""),
                "spotify_id": spotify_result.get("id", ""),
                "thumbnail": spotify_result.get("thumbnail", ""),
                "source": "spotify_validated",
            }
        else:
            result = {
                "title": parsed["title"],
                "artist": parsed["artist"],
                "album": "",
                "spotify_id": "",
                "thumbnail": "",
                "source": "regex_parsed",
            }

        if video_id and spotify_result:
            db.set_metadata_cache(cache_key, result)
        return result

    def _extract_ytdlp_metadata(self, video_url: str, *, deadline=None) -> dict | None:
        """Extract structured track/artist metadata from a YouTube video via yt-dlp."""
        if not self._dl or not self._dl.yt_dlp_exe:
            return None
        remaining = deadline - time.monotonic() if deadline is not None else 8
        if remaining <= 0:
            return None

        try:
            creationflags = self._dl._get_creationflags()
            cmd = self._dl._yt_cmd(
                ["--dump-json", "--skip-download", "--no-playlist"],
                video_url,
            )
            ret = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=min(8, remaining), creationflags=creationflags,
            )
            if ret.returncode != 0:
                return None

            data = json.loads(ret.stdout)
            track = (data.get("track") or "").strip()
            artist = (data.get("artist") or "").strip()
            album = (data.get("album") or "").strip()

            if not track and not artist:
                return None

            return {"title": track, "artist": artist, "album": album}
        except Exception as e:
            print(f"yt-dlp metadata extraction failed: {e}")
            return None

    def _spotify_validate(self, parsed_title: str, parsed_artist: str,
                          raw_yt_title: str, uploader: str, *, deadline=None) -> dict | None:
        """Validate/correct parsed metadata against Spotify using multiple search strategies."""
        if not self._spotify or not self._spotify.sp:
            return None

        cleaned_yt = _strip_yt_noise(raw_yt_title)

        candidates = []

        queries = []
        if parsed_title and parsed_artist:
            queries.append(f'track:{parsed_title} artist:{parsed_artist}')
        if cleaned_yt:
            queries.append(cleaned_yt)
        if parsed_title and parsed_artist and parsed_title != parsed_artist:
            queries.append(f'track:{parsed_artist} artist:{parsed_title}')
        for query in dict.fromkeys(queries):
            if deadline is not None and time.monotonic() >= deadline:
                break
            # Each Spotify request is already bounded by its six-second client
            # timeout. Do not start another provider call after the work budget.
            result = self._spotify._search_spotify_raw(query)
            if result:
                score = _score_spotify_match(result, raw_yt_title, uploader)
                candidates.append((score, result))
                if score >= 90:
                    break

        if not candidates:
            return None

        candidates.sort(key=lambda x: x[0], reverse=True)
        best_score, best_result = candidates[0]

        if best_score >= 40:
            return {
                "id": best_result.get("id", ""),
                "title": best_result.get("name", "") or best_result.get("title", ""),
                "artist": best_result.get("artist", ""),
                "album": best_result.get("album", ""),
                "thumbnail": best_result.get("thumbnail", ""),
            }

        return None
