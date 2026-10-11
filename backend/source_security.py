"""Canonical YouTube inputs. No user supplied URL reaches a generic extractor."""

import re
from urllib.parse import parse_qs, urlsplit

VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}\Z")
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}


def youtube_url(value: str) -> str:
    """Accept one video on an exact YouTube host, discard tracking parameters."""
    if not isinstance(value, str) or not value or value != value.strip() or any(ord(c) < 33 for c in value):
        raise ValueError("A valid YouTube video URL is required")
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in ("http", "https") or parsed.username or parsed.password or parsed.port not in (None, 443, 80):
            raise ValueError()
        host = (parsed.hostname or "").lower()
        if host == "youtu.be":
            video_id = parsed.path.removeprefix("/")
        elif host in YOUTUBE_HOSTS:
            if parsed.path == "/watch":
                ids = parse_qs(parsed.query).get("v", [])
                video_id = ids[0] if len(ids) == 1 else ""
            elif re.fullmatch(r"/(shorts|embed|live)/[A-Za-z0-9_-]{11}", parsed.path):
                video_id = parsed.path.split("/")[-1]
            else:
                raise ValueError()
        else:
            raise ValueError()
        if not VIDEO_ID.fullmatch(video_id):
            raise ValueError()
        return "https://www.youtube.com/watch?v=" + video_id
    except (ValueError, TypeError):
        raise ValueError("Only individual YouTube video URLs are supported") from None


def search_query(value: str) -> str:
    value = value.strip()
    if not value or len(value) > 500 or any(ord(c) < 32 for c in value):
        raise ValueError("Search must contain 1–500 printable characters")
    # URL-like searches are validated too; plain text always uses ytsearch.
    if re.search(r"^(?:[a-z][a-z0-9+.-]*://|(?:https?|file|data|javascript|ftp|ytsearch\d*):|//|www\.|youtube\.com|youtu\.be)", value, re.I):
        return youtube_url(value)
    return value


def streaming_target(value: str) -> str:
    """Only the Google video CDN may be fetched by the backend audio proxy."""
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
            raise ValueError()
        if not host.endswith(".googlevideo.com") or any(ord(c) < 33 for c in value):
            raise ValueError()
        return value
    except (TypeError, ValueError):
        raise ValueError("Invalid YouTube streaming CDN URL") from None
