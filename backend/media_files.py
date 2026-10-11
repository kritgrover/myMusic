"""Safe local media delivery, including seeking on supported FastAPI versions."""

import re
from pathlib import Path

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse


def validate_path_safety(base_dir: str, requested_path: str) -> Path:
    """Resolve a filename and require containment by path components."""
    try:
        base = Path(base_dir).resolve()
        requested = (base / requested_path.replace("\\", "/")).resolve()
        requested.relative_to(base)
        return requested
    except (ValueError, OSError, RuntimeError):
        raise HTTPException(status_code=400, detail="Invalid file path") from None


def _read_range(path: Path, start: int, length: int):
    # A generator keeps large audio files out of memory and closes on disconnect.
    with path.open("rb") as audio:
        audio.seek(start)
        remaining = length
        while remaining:
            chunk = audio.read(min(64 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def audio_file_response(path: Path, request: Request):
    """Serve full audio or one byte range without relying on Starlette's version.

    Audio clients use byte ranges for seeking. Older Starlette FileResponse
    implementations ignore Range even when Accept-Ranges is set by the caller.
    Multiple ranges are deliberately ignored and receive the full representation.
    """
    path = Path(path)
    stat = path.stat()
    full_response = FileResponse(
        path,
        media_type="audio/mpeg" if path.suffix.lower() == ".mp3" else "audio/mp4",
        filename=path.name,
        stat_result=stat,
        headers={"Accept-Ranges": "bytes"},
    )
    headers = dict(full_response.headers)
    if request.method == "HEAD":
        return Response(headers=headers)

    range_header = request.headers.get("range")
    if_range = request.headers.get("if-range")
    if if_range and if_range not in (headers.get("etag"), headers.get("last-modified")):
        range_header = None
    if not range_header or "," in range_header or not range_header.startswith("bytes="):
        # Use our iterator even for full responses so a newer FileResponse does
        # not independently re-interpret a deliberately ignored Range header.
        return StreamingResponse(_read_range(path, 0, stat.st_size), headers=headers)

    match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header)
    start = end = None
    if match and any(match.groups()) and stat.st_size:
        first, last = match.groups()
        if first:
            start = int(first)
            end = min(int(last), stat.st_size - 1) if last else stat.st_size - 1
        elif int(last) > 0:
            start = max(0, stat.st_size - int(last))
            end = stat.st_size - 1

    if start is None or end is None or start > end or start >= stat.st_size:
        return Response(status_code=416, headers={
            "Content-Range": f"bytes */{stat.st_size}", "Accept-Ranges": "bytes",
        })

    length = end - start + 1
    headers["content-length"] = str(length)
    headers["content-range"] = f"bytes {start}-{end}/{stat.st_size}"
    return StreamingResponse(_read_range(path, start, length), status_code=206, headers=headers)
