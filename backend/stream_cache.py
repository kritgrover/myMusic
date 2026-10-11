"""Bounded disk cache with serialized fills and leases for active responses."""

import hashlib
import os
import threading
import time
from pathlib import Path


class StreamCache:
    def __init__(self, directory, ttl_seconds=86400, max_bytes=512 * 1024 * 1024, max_file_bytes=64 * 1024 * 1024):
        self.directory = Path(directory)
        self.ttl_seconds = max(1, ttl_seconds)
        self.max_bytes = max(1, max_bytes)
        self.max_file_bytes = min(max(1, max_file_bytes), self.max_bytes)
        self._lock = threading.RLock()
        self._leases = {}
        self._used = {}
        self._prune()

    def _prune(self, reserve=0):
        self.directory.mkdir(parents=True, exist_ok=True)
        # A fill owns the same lock, so these can only be leftovers from a
        # failed/interrupted earlier process, never a live download.
        for partial in self.directory.glob("*.m4a.*"):
            if partial.is_file():
                partial.unlink(missing_ok=True)
        files = []
        now = time.time()
        for path in self.directory.glob("*.m4a"):
            stat = path.stat()
            if not self._leases.get(path) and (now - stat.st_mtime > self.ttl_seconds or stat.st_size > self.max_file_bytes):
                path.unlink(missing_ok=True)
                self._used.pop(path, None)
            else:
                files.append((self._used.get(path, stat.st_mtime), path, stat.st_size))
        total = sum(item[2] for item in files)
        for _, path, size in sorted(files):
            if total + reserve <= self.max_bytes:
                break
            if not self._leases.get(path):
                path.unlink(missing_ok=True)
                self._used.pop(path, None)
                total -= size
        if total + reserve > self.max_bytes:
            raise RuntimeError("Streaming cache is busy; retry after another track finishes")

    def acquire(self, source, downloader):
        path = self.directory / (hashlib.sha256(source.encode()).hexdigest() + ".m4a")
        # Fill under one lock: same-source callers reuse a complete atomic file,
        # and concurrent different fills cannot exceed the global reservation.
        with self._lock:
            self._prune()
            if not path.exists():
                self._prune(reserve=self.max_file_bytes)
                try:
                    downloader(source, str(path), max_bytes=self.max_file_bytes)
                    if not path.is_file() or not 0 < path.stat().st_size <= self.max_file_bytes:
                        raise RuntimeError("Stream exceeds the configured cache file limit")
                except Exception:
                    path.unlink(missing_ok=True)
                    for partial in self.directory.glob(path.name + ".*"):
                        if partial.is_file():
                            partial.unlink(missing_ok=True)
                    raise
            self._leases[path] = self._leases.get(path, 0) + 1
            self._used[path] = time.time()
            return path

    def release(self, path):
        with self._lock:
            count = self._leases.get(path, 0) - 1
            if count > 0:
                self._leases[path] = count
            else:
                self._leases.pop(path, None)
            self._prune()
