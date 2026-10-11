"""Deterministic isolated browser API; no project credentials or personal data.

Run ``py backend/tests/demo_server.py --port 8002 --ffmpeg PATH``.
Sign in with demo / demo-only or other / other-only. Audio is generated locally.
Catalogue/search providers are fixtures; auth, media, and data routes are real.
Ctrl+C removes temporary data. Authenticated demo-only test controls are
GET /__test/state, POST /__test/reset, and POST /__test/shutdown.
"""

import argparse
from pathlib import Path

import uvicorn

from demo_fixture import browser_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8002)
    local_ffmpeg = Path(__file__).resolve().parents[1] / "ffmpeg" / "bin" / "ffmpeg.exe"
    parser.add_argument("--ffmpeg", default=str(local_ffmpeg) if local_ffmpeg.is_file() else None)
    args = parser.parse_args()
    with browser_fixture(ffmpeg=args.ffmpeg) as (api, fixture):
        server = uvicorn.Server(uvicorn.Config(api.app, host="127.0.0.1", port=args.port))
        fixture.shutdown = lambda: setattr(server, "should_exit", True)
        print("ISOLATED DEMO: generated audio; demo/demo-only, other/other-only", flush=True)
        print(f"Fixture API http://127.0.0.1:{args.port}; Ctrl+C cleans up temporary data.", flush=True)
        server.run()


if __name__ == "__main__":
    main()
