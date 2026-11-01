"""Exercise the real startup shell in disposable homes, never with real auth."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = (ROOT / "src/ai-hermes-devbox/.devcontainer", ROOT / ".devcontainer")
HARNESS = r"""
cd() { builtin cd "$HOME"; }
# Run the starter's actual inline Python against the disposable config adapter.
# The fixed /opt/hermes interpreter is never invoked and no auth files exist.
timeout() { "$FIXTURE_PYTHON" -B -; }
hermes() { return 0; }
pgrep() {
  case "$*" in
    *dashboard*) [ "${RUNNING_DASHBOARD:-0}" = 1 ] ;;
    *gateway*) [ "${RUNNING_GATEWAY:-0}" = 1 ] ;;
    *) return 1 ;;
  esac
}
nohup() { printf '%s\n' "$*" >> "$CALLS"; }
kill() { printf 'kill %s\n' "$*" >> "$CALLS"; }
pkill() { printf 'pkill %s\n' "$*" >> "$CALLS"; }
trap 'wait' EXIT
source "$1"
"""
CONFIG_ADAPTER = '''"""Minimal config I/O boundary; policy stays in the real starter."""
import json
import os
from pathlib import Path

def get_config_path():
    return Path(os.environ["HOME"]) / ".hermes/config.json"

def require_readable_config_before_write(path):
    return json.loads(path.read_text()) if path.exists() else {}

def atomic_config_write(path, config):
    path.write_text(json.dumps(config))
    with path.with_suffix(".writes").open("a") as stream:
        stream.write("write\\n")
'''


class DashboardStartupTests(unittest.TestCase):
    def run_starter(self, starter, dashboard=None, *, running_gateway=False,
                    running_dashboard=False, master=None, config=None,
                    expected_code=0):
        with tempfile.TemporaryDirectory(prefix="hermes-startup-") as directory:
            home = Path(directory)
            data = home / ".hermes"
            data.mkdir()
            path = data / "config.json"
            if config is not None:
                path.write_text(config if isinstance(config, str) else json.dumps(config))
            # Existing seed markers must survive startup. No Codex auth is used.
            marker = data / ".codex-default-seeded"
            marker.write_text("fixture marker\n")
            package = home / "hermes_cli"
            package.mkdir()
            (package / "__init__.py").touch()
            (package / "config.py").write_text(CONFIG_ADAPTER)
            calls = Path(directory) / "calls.txt"
            env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": directory,
                "PYTHONPATH": directory,
                "FIXTURE_PYTHON": sys.executable,
                "CALLS": str(calls),
                "RUNNING_GATEWAY": str(int(running_gateway)),
                "RUNNING_DASHBOARD": str(int(running_dashboard)),
            }
            if dashboard is not None:
                env["HERMES_AUTOSTART_DASHBOARD"] = dashboard
            if master is not None:
                env["HERMES_AUTOSTART_SERVICES"] = master
            result = subprocess.run(
                ["bash", "-c", HARNESS, "startup-test", str(starter)],
                env=env, text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
            self.assertEqual(marker.read_text(), "fixture marker\n")
            self.assertFalse((home / ".codex/auth.json").exists())
            launched = calls.read_text().splitlines() if calls.exists() else []
            writes = path.with_suffix(".writes")
            return SimpleNamespace(
                calls=launched, output=result.stdout, error=result.stderr,
                raw_config=path.read_text() if path.exists() else None,
                writes=writes.read_text().splitlines() if writes.exists() else [],
            )

    def test_default_only_starts_gateway(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh")
                self.assertEqual(result.calls, ["hermes gateway"])
                self.assertIn("dashboard autostart disabled", result.output)

    def test_only_exact_one_opts_into_dashboard(self):
        for config in CONFIGS:
            for flag in ("0", "", "true", "2"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(config / "start-services.sh", flag)
                    self.assertEqual(result.calls, ["hermes gateway"])

    def test_opt_in_starts_dashboard_on_loopback(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh", "1")
                self.assertCountEqual(result.calls, [
                    "hermes gateway",
                    "hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build",
                ])

    def test_opt_in_reuses_running_processes(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh", "1",
                                          running_gateway=True, running_dashboard=True)
                self.assertEqual(result.calls, [])
                self.assertIn("gateway already running", result.output)
                self.assertIn("dashboard already running", result.output)

    def test_opt_in_starts_only_missing_dashboard(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh", "1", running_gateway=True)
                self.assertEqual(result.calls, [
                    "hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build",
                ])

    def test_existing_dashboard_does_not_prevent_gateway_start(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh", "1", running_dashboard=True)
                self.assertEqual(result.calls, ["hermes gateway"])
                self.assertIn("dashboard already running", result.output)

    def test_opt_out_never_stops_existing_dashboard(self):
        for config in CONFIGS:
            for flag in (None, "0"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(config / "start-services.sh", flag,
                                              running_gateway=True, running_dashboard=True)
                    # kill/pkill are recorded too: disabling is not a stop action.
                    self.assertEqual(result.calls, [])
                    self.assertIn("dashboard autostart disabled", result.output)

    def test_manual_starter_ignores_entrypoint_master_autostart_policy(self):
        for config in CONFIGS:
            for flag in (None, "1"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(config / "start-services.sh", flag, master="0")
                    self.assertIn("hermes gateway", result.calls)
                    self.assertEqual(len(result.calls), 2 if flag == "1" else 1)

    def test_first_start_sets_local_webapp_defaults(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh")
                self.assertEqual(json.loads(result.raw_config), {
                    "webapp": {"enabled": True, "host": "127.0.0.1", "port": 9120},
                })
                self.assertEqual(result.writes, ["write"])

    def test_explicit_webapp_model_and_other_settings_are_not_rewritten(self):
        existing = {
            "webapp": {"enabled": False, "host": "0.0.0.0", "port": 9876, "custom": "keep"},
            "model": {"provider": "anthropic", "default": "chosen-model"},
            "custom": {"preserve": True},
        }
        for config in CONFIGS:
            for flag in (None, "1"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(config / "start-services.sh", flag, config=existing)
                    self.assertEqual(result.raw_config, json.dumps(existing))
                    self.assertEqual(result.writes, [])

    def test_only_missing_webapp_keys_are_added(self):
        existing = {"webapp": {"enabled": False, "custom": "keep"}, "model": {"default": "chosen"}}
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config / "start-services.sh", config=existing)
                self.assertEqual(json.loads(result.raw_config), {
                    **existing,
                    "webapp": {**existing["webapp"], "host": "127.0.0.1", "port": 9120},
                })
                self.assertEqual(result.writes, ["write"])

    def test_invalid_config_fails_without_rewriting_or_launching_services(self):
        for config in CONFIGS:
            for raw in ("not valid json", '{"webapp": false}', '{"webapp": "invalid"}'):
                with self.subTest(config=config, raw=raw):
                    result = self.run_starter(config / "start-services.sh", "1",
                                              config=raw, expected_code=1)
                    self.assertEqual(result.raw_config, raw)
                    self.assertEqual(result.writes, [])
                    self.assertEqual(result.calls, [])
                    self.assertIn("could not configure Webapp", result.output)


class ComposeStartupTests(unittest.TestCase):
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
