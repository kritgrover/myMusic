"""Test probe request validation without loading native libraries or a real DB."""

import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts import check_native_playback as probe  # noqa: E402


class NativePlaybackProbeTests(unittest.TestCase):
    base = "http://localhost:8000"
    source = "https://www.youtube.com/watch?v=abcdefghijk"
    path = "/stream/" + quote(source, safe="")

    def test_authorizes_exact_source_and_keeps_login_token_out_of_media_url(self):
        signed = self.path + "?media_token=short-lived"
        with patch.object(probe, "post_json", side_effect=[
            {"access_token": "login-secret"}, {"url": signed}
        ]) as post:
            playable = probe.authorized_stream(self.base, "user", "password", self.source)
        self.assertEqual(playable, self.base + signed)
        self.assertEqual(post.call_args_list[1].args,
                         (self.base, "/media/authorize", {"path": self.path}, "login-secret"))
        self.assertNotIn("login-secret", playable)

    def test_rejects_changed_origin_source_or_missing_capability(self):
        for value in [
            "https://other.example" + self.path + "?media_token=secret",
            "/stream/other?media_token=secret",
            self.path,
            self.path + "?unrelated=value",
            self.path + "?media_token=secret#fragment",
        ]:
            with self.subTest(value=value), patch.object(probe, "post_json", side_effect=[
                {"access_token": "login-secret"}, {"url": value}
            ]):
                with self.assertRaisesRegex(RuntimeError, "unexpected URL"):
                    probe.authorized_stream(self.base, "user", "password", self.source)

    def test_rejects_invalid_source_before_login(self):
        with patch.object(probe, "post_json") as post:
            with self.assertRaises(ValueError):
                probe.authorized_stream(self.base, "user", "password", "https://evil.example/")
        post.assert_not_called()

    def test_rejects_malformed_login_response(self):
        for value in [None, "", 123]:
            with self.subTest(value=value), patch.object(probe, "post_json", return_value={"access_token": value}):
                with self.assertRaisesRegex(RuntimeError, "access token"):
                    probe.authorized_stream(self.base, "user", "password", self.source)

    def test_http_failures_do_not_expose_response_or_request_secrets(self):
        error = HTTPError("http://localhost/?media_token=secret", 500, "secret error", {},
                          io.BytesIO(b"private body"))
        with patch.object(probe, "urlopen", side_effect=error):
            with self.assertRaises(RuntimeError) as raised:
                probe.post_json(self.base, "/auth/login", {"password": "password"})
        self.assertEqual(str(raised.exception), "/auth/login returned HTTP 500")

    def test_network_failures_do_not_expose_signed_url(self):
        with patch.object(probe, "urlopen", side_effect=URLError("media_token=secret")):
            with self.assertRaises(RuntimeError) as raised:
                probe.post_json(self.base, "/media/authorize", {}, "private-token")
        self.assertEqual(str(raised.exception), "/media/authorize could not reach the backend")


if __name__ == "__main__":
    unittest.main()
