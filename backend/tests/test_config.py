"""Configuration regressions with dotenv and the entire environment replaced."""

import importlib.util
import os
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


CONFIG_PATH = Path(__file__).resolve().parents[1] / "config.py"


def load_test_settings(environment):
    dotenv = types.ModuleType("dotenv")
    dotenv.load_dotenv = Mock()
    spec = importlib.util.spec_from_file_location("isolated_config_test", CONFIG_PATH)
    module = importlib.util.module_from_spec(spec)
    # Never load a project .env or inherit real process credentials.
    with patch.dict("sys.modules", {"dotenv": dotenv}), patch.dict(os.environ, environment, clear=True):
        spec.loader.exec_module(module)
    return module.settings, dotenv.load_dotenv


class ConfigRegressionTests(unittest.TestCase):
    def test_default_database_is_anchored_to_backend(self):
        settings, load_dotenv = load_test_settings({"JWT_SECRET_KEY": "fixture-secret"})
        self.assertEqual(settings.DATABASE_URL, f"sqlite:///{CONFIG_PATH.parent / 'music_app.db'}")
        self.assertTrue(Path(settings.DATABASE_URL.removeprefix("sqlite:///")).is_absolute())
        self.assertEqual(load_dotenv.call_count, 2)

    def test_explicit_database_override_is_preserved(self):
        settings, _ = load_test_settings({"JWT_SECRET_KEY": "fixture-secret", "DATABASE_URL": "sqlite:///custom-fixture.db"})
        self.assertEqual(settings.DATABASE_URL, "sqlite:///custom-fixture.db")

    def test_missing_empty_or_known_default_secret_fails_with_setup_guidance(self):
        for value in (None, "", "   ", "change-me-in-production", " change-me-in-production "):
            with self.subTest(value=value):
                environment = {} if value is None else {"JWT_SECRET_KEY": value}
                with self.assertRaisesRegex(RuntimeError, "JWT_SECRET_KEY.*backend/.env"):
                    load_test_settings(environment)

    def test_existing_private_secret_is_preserved_without_length_requirement(self):
        settings, _ = load_test_settings({"JWT_SECRET_KEY": "fixture"})
        self.assertEqual(settings.JWT_SECRET_KEY, "fixture")


if __name__ == "__main__":
    unittest.main()
