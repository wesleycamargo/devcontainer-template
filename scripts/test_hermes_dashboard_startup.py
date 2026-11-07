"""Compose startup configuration contracts; runtime behavior is in test_hermes_devbox."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = (ROOT / "src/ai-hermes-devbox/.devcontainer", ROOT / ".devcontainer")
class ComposeStartupTests(unittest.TestCase):
    def test_bootstrap_inputs_are_explicit_and_documented(self):
        names = (
            "HERMES_MODEL_PROVIDER", "HERMES_DEFAULT_MODEL", "HERMES_MODEL_BASE_URL",
            "HERMES_TERMINAL_CWD", "HERMES_TERMINAL_BACKEND", "HERMES_TERMINAL_TIMEOUT",
            "HERMES_WEBAPP_ENABLED", "HERMES_WEBAPP_HOST", "HERMES_WEBAPP_PORT",
        )
        for directory in CONFIGS:
            compose = (directory / "docker-compose.yml").read_text()
            example = (directory / ".env.example").read_text()
            with self.subTest(directory=directory):
                for name in names:
                    self.assertIn(f'{name}: "${{{name}:-}}"', compose)
                    self.assertIn(f"# {name}=", example)
                self.assertNotIn("env_file:", compose)

    def test_env_example_exposes_both_startup_policies(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                text = (config / ".env.example").read_text()
                self.assertIn("HERMES_AUTOSTART_SERVICES=1", text.splitlines())
                self.assertIn("HERMES_AUTOSTART_DASHBOARD=0", text.splitlines())
                self.assertIn("HERMES_AUTOSTART_DASHBOARD=1", text)
                self.assertIn("recreate to apply", text)

    def test_compose_defaults_gateway_on_dashboard_off_with_overrides(self):
        # Static interpolation contract only, not rendered Compose validation.
        for config in CONFIGS:
            with self.subTest(config=config):
                text = (config / "docker-compose.yml").read_text()
                self.assertIn('HERMES_AUTOSTART_SERVICES: "${HERMES_AUTOSTART_SERVICES:-1}"', text)
                self.assertIn('HERMES_AUTOSTART_DASHBOARD: "${HERMES_AUTOSTART_DASHBOARD:-0}"', text)


if __name__ == "__main__":
    unittest.main()
