"""Exercise the actual startup import block without real credentials or network."""

import contextlib
import copy
import io
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(__file__).resolve().parents[1] / "src/ai-hermes-devbox/.devcontainer"
SEED = (SOURCE / "start-services.sh").read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]


class CodexSeedTests(unittest.TestCase):
    def seed(self, *, config=None, existing=None, imported=None):
        self.auth = types.SimpleNamespace(
            _auth_store_lock=contextlib.nullcontext,
            _load_auth_store=lambda: {}, _load_provider_state=lambda *_: existing,
            _import_codex_cli_tokens=Mock(return_value=imported),
            _save_codex_tokens=Mock(), _update_config_for_provider=Mock())
        self.config = types.SimpleNamespace(
            get_config_path=lambda: Path("unused"),
            require_readable_config_before_write=lambda _: copy.deepcopy(config or {}),
            set_config_value=Mock())
        modules = {
            "hermes_cli": types.ModuleType("hermes_cli"),
            "hermes_cli.auth": self.auth, "hermes_cli.config": self.config,
            "hermes_cli.auth_codex": types.SimpleNamespace(_codex_base_url=lambda: "fixture-url"),
        }
        with patch.dict(sys.modules, modules), contextlib.redirect_stdout(io.StringIO()):
            exec(compile(SEED, "start-services.sh:codex-seed", "exec"), {})

    def test_imports_cli_login_for_first_project(self):
        grant = {"access_token": "fixture-access", "refresh_token": "fixture-refresh"}
        self.seed(imported=grant)
        self.auth._save_codex_tokens.assert_called_once_with(grant)
        self.auth._update_config_for_provider.assert_called_once_with("openai-codex", "fixture-url")

    def test_existing_hermes_login_is_not_overwritten(self):
        self.seed(existing={"tokens": {"access_token": "rotated-access", "refresh_token": "rotated-refresh"}})
        self.auth._import_codex_cli_tokens.assert_not_called()
        self.auth._save_codex_tokens.assert_not_called()
        self.auth._update_config_for_provider.assert_called_once()

    def test_explicit_provider_choice_is_not_overwritten(self):
        with self.assertRaises(SystemExit) as result:
            self.seed(config={"model": {"provider": "anthropic"}})
        self.assertEqual(result.exception.code, 0)
        self.auth._import_codex_cli_tokens.assert_not_called()
        self.auth._update_config_for_provider.assert_not_called()

    def test_existing_openai_model_is_not_overwritten(self):
        self.seed(config={"model": {"provider": "openai-codex", "default": "chosen-model"}},
                  existing={"tokens": {"access_token": "access", "refresh_token": "refresh"}})
        self.config.set_config_value.assert_not_called()

    def test_missing_cli_grant_is_not_reported_as_success(self):
        with self.assertRaises(SystemExit) as result:
            self.seed()
        self.assertEqual(result.exception.code, 2)
        self.auth._save_codex_tokens.assert_not_called()


if __name__ == "__main__":
    unittest.main()
