"""Validated cumulative listening reports; no provider requests or media tokens."""

import math
import re
import unicodedata
from fastapi import HTTPException
from saved_library import _reject_credentials
from source_security import youtube_url

END_REASONS = {"ongoing", "paused", "completed", "skipped", "stopped", "error"}
TERMINAL_REASONS = {"completed", "skipped", "stopped", "error"}


def normalized(value):
    return " ".join(unicodedata.normalize("NFKC", value or "").casefold().split())


def track_key(title, artist):
    return normalized(title), normalized(artist)


def qualified(listened, duration):
    return listened >= (min(30.0, duration * 0.5) if duration > 0 else 30.0)


def early_skip(row):
    duration = float(row.get("duration_seconds") or 0)
    return row.get("end_reason") == "skipped" and float(row.get("duration_played") or 0) < (
        min(10.0, duration * 0.25) if duration > 0 else 10.0)


def validate_report(value):
    allowed = {"event_id", "sequence", "song_title", "artist", "source_url", "spotify_id",
               "duration_seconds", "listened_seconds", "end_reason"}
    if not isinstance(value, dict) or set(value) - allowed:
        raise HTTPException(400, "Unsupported listening report fields")
    result = {}
    for field, limit in (("event_id", 128), ("song_title", 300), ("artist", 300),
                         ("source_url", 2048), ("spotify_id", 128)):
        text = value.get(field)
        text = "" if text is None else text
        if not isinstance(text, str) or len(text) > limit or any(ord(c) < 32 for c in text):
            raise HTTPException(400, f"Invalid listening {field}")
        result[field] = text.strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", result["event_id"]):
        raise HTTPException(400, "Invalid listening event ID")
    if not result["song_title"] or not result["artist"]:
        raise HTTPException(400, "Listening title and artist are required")
    _reject_credentials(result["spotify_id"])
    if result["spotify_id"] and not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", result["spotify_id"]):
        raise HTTPException(400, "Invalid Spotify track ID")
    sequence = value.get("sequence")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or not 1 <= sequence <= 2147483647:
        raise HTTPException(400, "Listening sequence must be a positive integer")
    result["sequence"] = sequence
    for field in ("duration_seconds", "listened_seconds"):
        number = value.get(field, 0)
        if isinstance(number, bool) or not isinstance(number, (float, int)) or not math.isfinite(number) or not 0 <= number <= 86400:
            raise HTTPException(400, f"Invalid listening {field}")
        result[field] = float(number)
    reason = value.get("end_reason", "ongoing")
    if not isinstance(reason, str) or reason not in END_REASONS:
        raise HTTPException(400, "Invalid listening end reason")
    result["end_reason"] = reason
    if result["source_url"]:
        _reject_credentials(result["source_url"])
        try:
            result["source_url"] = youtube_url(result["source_url"])
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from None
    return result
