"""YouTube extraction remains bounded and returns playable audio containers."""

import os
import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import yt_dlp

from isolated_backend import isolated_backend


class YouTubeExtractionTests(unittest.TestCase):
    source = "https://www.youtube.com/watch?v=testFixture"
    direct = "https://fixture.googlevideo.com/videoplayback?mime=audio%2Fmp4"

    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        import download_service
        cls.module = download_service

    @classmethod
    def tearDownClass(cls):
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        self.service = object.__new__(self.module.DownloadService)
        self.service.yt_dlp_exe = ["fixture-python", "-m", "yt_dlp"]
        self.service.ffmpeg_exe = "ffmpeg"

    def test_node_is_explicitly_enabled_and_runtime_discovery_is_cached(self):
        node_path = str(self.root / "Program Files" / "nodejs" / "node.exe")
        with patch.object(self.module.shutil, "which", side_effect=lambda name: node_path if name == "node" else None) as which:
            first = self.service._yt_cmd(["-g"], self.source)
            second = self.service._yt_cmd(["-g"], self.source)
        self.assertEqual(first, second)
        self.assertEqual(first[first.index("--js-runtimes") + 1], "node:" + os.path.abspath(node_path))
        self.assertEqual([call.args[0] for call in which.call_args_list], ["deno", "node"])
        self.assertEqual(first[-2:], ["--", self.source])

    def test_deno_is_preferred_when_both_runtimes_are_installed(self):
        deno_path = str(self.root / "deno.exe")
        with patch.object(self.module.shutil, "which", return_value=deno_path) as which:
            command = self.service._yt_cmd(["-g"], self.source)
        self.assertEqual(command[command.index("--js-runtimes") + 1], "deno:" + os.path.abspath(deno_path))
        which.assert_called_once_with("deno")

    def test_missing_runtime_does_not_invent_an_executable(self):
        with patch.object(self.module.shutil, "which", return_value=None):
            command = self.service._yt_cmd(["-g"], self.source)
        self.assertNotIn("--js-runtimes", command)

    def resolve_result(self, stdout, stderr="", returncode=0):
        self.service._js_runtime = None
        return patch.object(self.module.subprocess, "run", return_value=SimpleNamespace(
            stdout=stdout, stderr=stderr, returncode=returncode))

    def test_provider_failure_is_preserved_without_browser_cookie_retries(self):
        with self.resolve_result("", "ERROR: Video unavailable: the uploader removed this video", 1) as run:
            with self.assertRaisesRegex(Exception, "uploader removed this video"):
                self.service.get_streaming_url(self.source)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertNotIn("--cookies-from-browser", command)
        self.assertNotIn("--extractor-args", command)
        self.assertEqual(command[command.index("--socket-timeout") + 1], "10")
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

    def test_resolution_timeout_is_reported_without_another_attempt(self):
        self.service._js_runtime = None
        with patch.object(self.module.subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 30)) as run:
            with self.assertRaisesRegex(Exception, "stream resolution timed out after 30 seconds"):
                self.service.get_streaming_url(self.source)
        run.assert_called_once()

    def test_rejects_manifest_multiple_and_non_cdn_stream_urls(self):
        for output in (
            "https://fixture.googlevideo.com/api/manifest/hls_playlist/id/fixture",
            "https://fixture.googlevideo.com/playlist.m3u8?token=fixture",
            "https://fixture.googlevideo.com/audio.mpd",
            self.direct + "\n" + self.direct,
            "http://fixture.googlevideo.com/videoplayback",
            "https://www.youtube.com/watch?v=testFixture",
        ):
            with self.subTest(output=output), self.resolve_result(output):
                with self.assertRaisesRegex(RuntimeError, "Invalid direct audio"):
                    self.service.get_streaming_url(self.source)

    def test_format_selector_excludes_manifests_and_prefers_direct_aac(self):
        with self.resolve_result(self.direct + "\n") as run:
            self.assertEqual(self.service.get_streaming_url(self.source), self.direct)
        command = run.call_args.args[0]
        selector = yt_dlp.YoutubeDL({"quiet": True}).build_format_selector(command[command.index("-f") + 1])
        aac = dict(format_id="aac", protocol="https", vcodec="none", acodec="mp4a.40.2", ext="m4a", url=self.direct)
        opus = dict(format_id="opus", protocol="https", vcodec="none", acodec="opus", ext="webm", url=self.direct)
        hls = dict(format_id="hls", protocol="m3u8_native", vcodec="none", acodec="mp4a.40.2", ext="m4a", url=self.direct)
        dash = dict(format_id="dash", protocol="http_dash_segments", vcodec="none", acodec="opus", ext="webm", url=self.direct)

        def selected(formats):
            return [item["format_id"] for item in selector(dict(
                formats=formats, has_merged_format=False, incomplete_formats=False))]

        self.assertEqual(selected([aac, opus, hls, dash]), ["aac"])
        self.assertEqual(selected([opus, hls, dash]), ["opus"])
        self.assertEqual(selected([hls, dash]), [])

    def test_cached_fallback_converts_opus_to_aac_and_moves_final_container(self):
        destination = str(self.root / "converted.m4a")

        def extract(args, source, prefix, max_bytes):
            # Exercise yt-dlp's option parsing: ExtractAudio must request m4a,
            # which transcodes Opus rather than merely putting it in MP4.
            parsed = yt_dlp.parse_options(args)
            processors = parsed.ydl_opts["postprocessors"]
            audio = next(item for item in processors if item["key"] == "FFmpegExtractAudio")
            self.assertEqual(audio["preferredcodec"], "m4a")
            self.assertFalse(any(item["key"] == "FFmpegVideoRemuxer" for item in processors))
            self.assertEqual(max_bytes, 1024)
            Path(prefix + ".m4a").write_bytes(b"converted-aac")

        with patch.object(self.service, "_bounded_stream_process", side_effect=extract):
            self.assertEqual(self.service.download_for_streaming(self.source, destination, 1024), destination)
        self.assertEqual(Path(destination).read_bytes(), b"converted-aac")
        self.assertFalse(Path(destination + ".work.m4a").exists())


if __name__ == "__main__":
    unittest.main()
