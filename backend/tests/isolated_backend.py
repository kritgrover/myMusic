"""Run the API against temporary test data without loading project credentials."""

import importlib
import sys
import tempfile
import types
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch


@contextmanager
def isolated_backend():
    backend_dir = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(backend_dir))
    module_names = ("app", "database", "auth_utils", "spotify_service", "download_service", "metadata_service", "lyrics_service")
    saved_modules = {name: sys.modules.pop(name) for name in module_names if name in sys.modules}
    with tempfile.TemporaryDirectory(prefix="mymusic-test-") as temp:
        root = Path(temp)
        downloads = root / "downloads"
        downloads.mkdir()
        config = types.ModuleType("config")
        config.settings = types.SimpleNamespace(
            DATABASE_URL=f"sqlite:///{root / 'test.db'}",
            SPOTIFY_CLIENT_ID=None,
            SPOTIFY_CLIENT_SECRET=None,
            JWT_SECRET_KEY="isolated-tests-only-never-for-production",
            JWT_ALGORITHM="HS256",
            JWT_EXPIRE_MINUTES=60,
        )
        # All configuration is replaced before any app imports: no .env files,
        # real database, Spotify credentials, downloads, or subprocesses are used.
        previous_config = sys.modules.get("config")
        sys.modules["config"] = config
        try:
            from download_service import DownloadService

            def init_downloads(service, output_dir="downloads"):
                service.output_dir = str(downloads)
                service.yt_dlp_exe = None
                service.ffmpeg_exe = None

            with patch.object(DownloadService, "__init__", init_downloads):
                api = importlib.import_module("app")
            with patch.object(api, "BASE_DIR", str(root)), patch.object(api, "DOWNLOADS_DIR", str(downloads)):
                try:
                    yield api, root
                finally:
                    for name in module_names:
                        sys.modules.pop(name, None)
                    sys.modules.update(saved_modules)
                    sys.path.remove(str(backend_dir))
        finally:
            if previous_config is None:
                sys.modules.pop("config", None)
            else:
                sys.modules["config"] = previous_config

