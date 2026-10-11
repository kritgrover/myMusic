"""Decode a protected stream with the Windows player's actual libmpv library.

Build the Windows app and start the backend first, then run::

    py backend/scripts/check_native_playback.py --username USER --youtube-url URL

The password is prompted, or read from MYMUSIC_TEST_PASSWORD. Audio is decoded
to the null output, so this does not play sound or touch the running app. Login
and media tokens stay in memory and are never included in diagnostic output.
"""

import argparse
import ctypes
import getpass
import json
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urljoin, urlsplit
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from source_security import youtube_url  # noqa: E402


def post_json(base_url, path, payload, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = Request(
        base_url + path,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urlopen(request, timeout=20) as response:
            data = json.loads(response.read(1024 * 1024))
    except HTTPError as error:
        raise RuntimeError(f"{path} returned HTTP {error.code}") from None
    except (URLError, TimeoutError):
        raise RuntimeError(f"{path} could not reach the backend") from None
    except (ValueError, UnicodeError):
        raise RuntimeError(f"{path} returned an invalid JSON response") from None
    if not isinstance(data, dict):
        raise RuntimeError(f"{path} returned an invalid JSON response")
    return data


def authorized_stream(base_url, username, password, source):
    source = youtube_url(source)
    base_url = base_url.rstrip("/")
    base = urlsplit(base_url)
    if base.scheme not in ("http", "https") or not base.netloc or base.username or base.password:
        raise ValueError("A valid backend URL without embedded credentials is required")
    login = post_json(base_url, "/auth/login", {"username": username, "password": password})
    token = login.get("access_token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("Login did not return an access token")
    path = "/stream/" + quote(source, safe="")
    media = post_json(base_url, "/media/authorize", {"path": path}, token)
    value = media.get("url")
    if not isinstance(value, str):
        raise RuntimeError("Media authorization did not return a URL")
    playable = urljoin(base_url + "/", value)
    target = urlsplit(playable)
    if ((target.scheme, target.hostname, target.port) != (base.scheme, base.hostname, base.port)
            or target.username or target.password or target.path != path or target.fragment
            or not parse_qs(target.query).get("media_token", [""])[0]):
        raise RuntimeError("Media authorization returned an unexpected URL")
    return playable


class MpvEvent(ctypes.Structure):
    _fields_ = [("event_id", ctypes.c_int), ("error", ctypes.c_int),
                ("reply_userdata", ctypes.c_uint64), ("data", ctypes.c_void_p)]


class MpvEndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int)]


def decode_stream(library_path, playable, seconds=2.0, timeout=120.0):
    if not library_path.is_file():
        raise RuntimeError("libmpv-2.dll is missing; build the Windows app first")
    mpv = ctypes.CDLL(str(library_path))
    mpv.mpv_create.restype = ctypes.c_void_p
    mpv.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    mpv.mpv_initialize.argtypes = [ctypes.c_void_p]
    mpv.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    mpv.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
    mpv.mpv_wait_event.restype = ctypes.POINTER(MpvEvent)
    mpv.mpv_get_property.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError("Could not create the Windows decoder")
    try:
        for name, value in {
            "config": "no", "terminal": "no", "msg-level": "all=no",
            "video": "no", "ao": "null", "audio-display": "no",
            "network-timeout": "30",
        }.items():
            if mpv.mpv_set_option_string(handle, name.encode(), value.encode()) < 0:
                raise RuntimeError(f"Could not configure decoder option {name}")
        if mpv.mpv_initialize(handle) < 0:
            raise RuntimeError("Could not initialize the Windows decoder")
        args = (ctypes.c_char_p * 4)(b"loadfile", playable.encode(), b"replace", None)
        if mpv.mpv_command(handle, args) < 0:
            raise RuntimeError("Windows decoder rejected the playback command")
        started = time.monotonic()
        while time.monotonic() - started < timeout:
            event = mpv.mpv_wait_event(handle, 0.1).contents
            if event.event_id == 7 and event.data:  # MPV_EVENT_END_FILE
                ended = ctypes.cast(event.data, ctypes.POINTER(MpvEndFile)).contents
                raise RuntimeError(f"Playback ended before verification (decoder error {ended.error})")
            position = ctypes.c_double()
            sample_rate = ctypes.c_int64()
            duration = ctypes.c_double()
            has_position = mpv.mpv_get_property(handle, b"time-pos", 5, ctypes.byref(position)) >= 0
            has_audio = mpv.mpv_get_property(handle, b"audio-params/samplerate", 4, ctypes.byref(sample_rate)) >= 0
            if has_position and has_audio and position.value >= seconds and sample_rate.value > 0:
                mpv.mpv_get_property(handle, b"duration", 5, ctypes.byref(duration))
                return {"decoded_seconds": round(position.value, 3),
                        "sample_rate": sample_rate.value,
                        "duration_seconds": round(duration.value, 3)}
        raise RuntimeError("Timed out waiting for the Windows decoder to play audio")
    finally:
        mpv.mpv_terminate_destroy(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-base", default="http://localhost:8000")
    parser.add_argument("--username", required=True)
    parser.add_argument("--youtube-url", required=True)
    parser.add_argument("--library", type=Path, default=ROOT / "frontend/build/windows/x64/runner/Release/libmpv-2.dll")
    parser.add_argument("--seconds", type=float, default=2.0)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    if args.seconds <= 0 or args.timeout <= args.seconds:
        parser.error("seconds must be positive and timeout must exceed seconds")
    password = os.environ.get("MYMUSIC_TEST_PASSWORD") or getpass.getpass("Password: ")
    try:
        playable = authorized_stream(args.api_base, args.username, password, args.youtube_url)
        print("Authenticated media capability acquired; verifying native audio decode.", flush=True)
        result = decode_stream(args.library, playable, args.seconds, args.timeout)
        print(json.dumps({"status": "passed", **result}), flush=True)
        return 0
    except (RuntimeError, ValueError) as error:
        print(f"Native playback check failed: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        # Native/network exception text can contain signed URLs; never print it.
        print(f"Native playback check failed ({type(error).__name__}).", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
