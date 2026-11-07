"""Environment bootstrap policy without live Hermes config or credentials."""
import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "env_runtime", ROOT / "src/ai-hermes-devbox/.devcontainer/hermes_devbox.py",
)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class EnvDefaultsTests(unittest.TestCase):
    def apply(self, env, config=None):
        original = copy.deepcopy(config if config is not None else {})
        self.writer = Mock()
        adapter = types.SimpleNamespace(
            get_config_path=lambda: Path("unused"),
            require_readable_config_before_write=lambda _: copy.deepcopy(original),
            atomic_config_write=self.writer,
        )
        with (patch.dict(os.environ, env, clear=True),
              patch.dict(sys.modules, {"hermes_cli": types.ModuleType("hermes_cli"),
                                       "hermes_cli.config": adapter}),
              contextlib.redirect_stdout(io.StringIO())):
            exec(compile(runtime.ENV_DEFAULTS, "env-defaults", "exec"), {})
        return self.writer.call_args.args[1] if self.writer.called else original

    def test_all_inputs_are_mapped_with_types(self):
        actual = self.apply({
            "HERMES_MODEL_PROVIDER": "custom", "HERMES_DEFAULT_MODEL": "fixture-model",
            "HERMES_MODEL_BASE_URL": "http://model.internal:8000/v1",
            "HERMES_TERMINAL_CWD": "/workspaces/project with spaces",
            "HERMES_TERMINAL_BACKEND": "local", "HERMES_TERMINAL_TIMEOUT": "240",
            "HERMES_WEBAPP_ENABLED": "false", "HERMES_WEBAPP_HOST": "127.0.0.1",
            "HERMES_WEBAPP_PORT": "9130",
        })
        self.assertEqual(actual, {
            "model": {"provider": "custom", "default": "fixture-model",
                      "base_url": "http://model.internal:8000/v1"},
            "terminal": {"cwd": "/workspaces/project with spaces", "backend": "local", "timeout": 240},
            "webapp": {"enabled": False, "host": "127.0.0.1", "port": 9130},
        })
        self.writer.assert_called_once()

    def test_blank_unknown_and_secret_inputs_do_not_write(self):
        self.apply({"HERMES_DEFAULT_MODEL": "  ", "OPENAI_API_KEY": "fixture-only",
                    "HERMES_UNKNOWN_SETTING": "ignored"})
        self.writer.assert_not_called()

    def test_saved_values_and_unrelated_settings_win(self):
        existing = {"model": {"provider": "anthropic", "default": "chosen"},
                    "webapp": {"enabled": False}, "custom": {"keep": True}}
        actual = self.apply({"HERMES_MODEL_PROVIDER": "custom", "HERMES_DEFAULT_MODEL": "ignored",
                             "HERMES_WEBAPP_ENABLED": "true", "HERMES_TERMINAL_TIMEOUT": "240"}, existing)
        self.assertEqual(actual, {**existing, "terminal": {"timeout": 240}})

    def test_present_empty_null_and_false_are_not_missing(self):
        for value in (None, "", 0, False):
            with self.subTest(value=value):
                existing = {"model": {"default": value}}
                self.assertEqual(self.apply({"HERMES_DEFAULT_MODEL": "ignored"}, existing), existing)
                self.writer.assert_not_called()

    def test_second_run_is_a_noop(self):
        env = {"HERMES_MODEL_PROVIDER": "custom", "HERMES_DEFAULT_MODEL": "fixture"}
        stored = self.apply(env)
        self.assertEqual(self.apply(env, stored), stored)
        self.writer.assert_not_called()

    def test_invalid_input_is_atomic(self):
        for name, value in (
            ("HERMES_TERMINAL_TIMEOUT", "0"), ("HERMES_TERMINAL_TIMEOUT", "oops"),
            ("HERMES_WEBAPP_PORT", "65536"), ("HERMES_WEBAPP_PORT", "0"),
            ("HERMES_WEBAPP_ENABLED", "maybe"), ("HERMES_WEBAPP_HOST", "0.0.0.0"),
            ("HERMES_TERMINAL_CWD", "relative/path"),
            ("HERMES_MODEL_BASE_URL", "https://user:password@model.internal/v1"),
            ("HERMES_MODEL_BASE_URL", "https://model.internal/v1?key=fixture"),
            ("HERMES_MODEL_BASE_URL", "not-a-url"),
        ):
            with self.subTest(name=name, value=value):
                with self.assertRaises(ValueError):
                    self.apply({"HERMES_MODEL_PROVIDER": "custom", "HERMES_DEFAULT_MODEL": "fixture", name: value})
                self.writer.assert_not_called()

    def test_affected_sections_must_be_mappings(self):
        for section, name in (("model", "HERMES_DEFAULT_MODEL"),
                              ("terminal", "HERMES_TERMINAL_BACKEND"),
                              ("webapp", "HERMES_WEBAPP_HOST")):
            with self.subTest(section=section):
                with self.assertRaises(ValueError):
                    self.apply({name: "local"}, {section: False})
                self.writer.assert_not_called()

    def test_url_requires_effective_custom_provider(self):
        for config in ({}, {"model": {"provider": "openai-codex"}}):
            with self.subTest(config=config):
                with self.assertRaises(ValueError):
                    self.apply({"HERMES_MODEL_BASE_URL": "http://model.internal/v1"}, config)
                self.writer.assert_not_called()



    def test_saved_url_does_not_bypass_provider_validation(self):
        with self.assertRaises(ValueError):
            self.apply({"HERMES_MODEL_BASE_URL": "https://model.internal/v1"},
                       {"model": {"provider": "openai-codex", "base_url": "saved"}})
        self.writer.assert_not_called()

    def test_invalid_supplied_values_are_validated_when_saved(self):
        with self.assertRaises(ValueError):
            self.apply({"HERMES_WEBAPP_PORT": "bad"}, {"webapp": {"port": 9120}})
        self.writer.assert_not_called()

    def test_url_rejects_whitespace_and_empty_delimiters(self):
        for url in ("http://model server/v1", "http://model.internal/v1?", "http://model.internal/v1#"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.apply({"HERMES_MODEL_PROVIDER": "custom", "HERMES_MODEL_BASE_URL": url})
            self.writer.assert_not_called()

    def test_blank_inputs_do_not_read_config(self):
        self.apply({}, False)
        self.writer.assert_not_called()

if __name__ == "__main__":
    unittest.main()
