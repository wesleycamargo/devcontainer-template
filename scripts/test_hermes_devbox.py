"""Runtime policy exercised against disposable data and explicit OS boundaries."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ai-hermes-devbox/.devcontainer"
CONFIGS = (SOURCE,)
spec = importlib.util.spec_from_file_location("hermes_devbox", SOURCE / "hermes_devbox.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

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
            exec(compile(runtime.CODEX_SEED, "hermes_devbox:codex-seed", "exec"), {})

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
    def run_starter(self, dashboard=None, *, running_gateway=False,
                    running_dashboard=False, master=None, config=None,
                    workspace_names=("project",), expected_code=0, extra_env=None):
        with tempfile.TemporaryDirectory(prefix="hermes-startup-") as directory:
            home = Path(directory)
            data = home / ".hermes"
            data.mkdir()
            path = data / "config.json"
            if config is not None:
                path.write_text(config if isinstance(config, str) else json.dumps(config))
            marker = data / ".codex-default-seeded"
            marker.write_text("fixture marker\n")
            package = home / "hermes_cli"
            package.mkdir()
            (package / "__init__.py").touch()
            (package / "config.py").write_text(CONFIG_ADAPTER)
            workspaces = home / "workspaces"
            workspaces.mkdir()
            for name in workspace_names:
                (workspaces / name).mkdir()
            # Preflight runs without Hermes installed. Supply only our command
            # discovery fixture; launch_service below intercepts actual startup.
            commands = home / "bin"
            commands.mkdir()
            hermes = commands / "hermes"
            hermes.write_text("#!/bin/sh\nexit 99\n")
            hermes.chmod(0o755)
            env = {"PATH": str(commands),
                   "HOME": directory, "PYTHONPATH": directory}
            env.update(extra_env or {})
            if dashboard is not None:
                env["HERMES_AUTOSTART_DASHBOARD"] = dashboard
            if master is not None:
                env["HERMES_AUTOSTART_SERVICES"] = master
            calls, workdirs = [], []
            output = io.StringIO()
            def launch(args, **kwargs):
                calls.append(" ".join(args))
                workdirs.append(str(kwargs["cwd"]))
            def running(pattern):
                return running_dashboard if "dashboard" in pattern else running_gateway
            with (patch.dict(os.environ, env, clear=True),
                  patch.object(runtime, "RUNTIME", home),
                  patch.object(runtime, "PYTHON", sys.executable),
                  patch.object(runtime, "WORKSPACES", workspaces),
                  patch.object(runtime, "process_running", side_effect=running),
                  patch.object(runtime, "launch_service", side_effect=launch),
                  contextlib.redirect_stdout(output)):
                result = runtime.start_services()
            self.assertEqual(result, expected_code, output.getvalue())
            self.assertEqual(marker.read_text(), "fixture marker\n")
            self.assertFalse((home / ".codex/auth.json").exists())
            writes = path.with_suffix(".writes")
            return SimpleNamespace(calls=calls, output=output.getvalue(), error="",
                raw_config=path.read_text() if path.exists() else None,
                writes=writes.read_text().splitlines() if writes.exists() else [],
                workdirs=workdirs, workspace_root=workspaces)

    def test_environment_defaults_precede_fallbacks(self):
        result = self.run_starter(extra_env={
            "HERMES_MODEL_PROVIDER": "custom", "HERMES_DEFAULT_MODEL": "fixture-model",
            "HERMES_WEBAPP_ENABLED": "false", "HERMES_WEBAPP_PORT": "9130",
        })
        self.assertEqual(json.loads(result.raw_config), {
            "model": {"provider": "custom", "default": "fixture-model"},
            "webapp": {"enabled": False, "host": "127.0.0.1", "port": 9130},
        })

    def test_invalid_env_prevents_seed_and_service_start(self):
        with patch.object(runtime, "seed_codex_default_model") as seed:
            result = self.run_starter(extra_env={"HERMES_WEBAPP_PORT": "invalid"}, expected_code=1)
        seed.assert_not_called()
        self.assertEqual(result.calls, [])
        self.assertIsNone(result.raw_config)

    def test_bootstrap_precedes_codex_import(self):
        events = []
        def seed(home):
            saved = json.loads((Path(home) / ".hermes/config.json").read_text())
            events.append(saved["model"]["provider"])
        with patch.object(runtime, "seed_codex_default_model", side_effect=seed):
            self.run_starter(extra_env={"HERMES_MODEL_PROVIDER": "custom"})
        self.assertEqual(events, ["custom"])

    def test_starter_does_not_require_hermes_on_the_host_path(self):
        with patch.dict(os.environ, {"PATH": "/nonexistent-hermes-test-path"}):
            result = self.run_starter()
        self.assertEqual(result.calls, ["hermes gateway"])
        self.assertIn("filled missing local Webapp defaults", result.output)

    def test_default_only_starts_gateway(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter()
                self.assertEqual(result.calls, ["hermes gateway"])
                self.assertIn("dashboard autostart disabled", result.output)

    def test_gateway_starts_in_the_unique_devcontainer_workspace(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(workspace_names=("example",))
                self.assertEqual(result.workdirs, [str(result.workspace_root / "example")])

    def test_only_exact_one_opts_into_dashboard(self):
        for config in CONFIGS:
            for flag in ("0", "", "true", "2"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(flag)
                    self.assertEqual(result.calls, ["hermes gateway"])

    def test_opt_in_starts_dashboard_on_loopback(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter("1")
                self.assertCountEqual(result.calls, [
                    "hermes gateway",
                    "hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build",
                ])

    def test_opt_in_reuses_running_processes(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter("1",
                                          running_gateway=True, running_dashboard=True)
                self.assertEqual(result.calls, [])
                self.assertIn("gateway already running", result.output)
                self.assertIn("dashboard already running", result.output)

    def test_opt_in_starts_only_missing_dashboard(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter("1", running_gateway=True)
                self.assertEqual(result.calls, [
                    "hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build",
                ])

    def test_existing_dashboard_does_not_prevent_gateway_start(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter("1", running_dashboard=True)
                self.assertEqual(result.calls, ["hermes gateway"])
                self.assertIn("dashboard already running", result.output)

    def test_opt_out_never_stops_existing_dashboard(self):
        for config in CONFIGS:
            for flag in (None, "0"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(flag,
                                              running_gateway=True, running_dashboard=True)
                    # kill/pkill are recorded too: disabling is not a stop action.
                    self.assertEqual(result.calls, [])
                    self.assertIn("dashboard autostart disabled", result.output)

    def test_manual_starter_ignores_entrypoint_master_autostart_policy(self):
        for config in CONFIGS:
            for flag in (None, "1"):
                with self.subTest(config=config, flag=flag):
                    result = self.run_starter(flag, master="0")
                    self.assertIn("hermes gateway", result.calls)
                    self.assertEqual(len(result.calls), 2 if flag == "1" else 1)

    def test_first_start_sets_local_webapp_defaults(self):
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter()
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
                    result = self.run_starter(flag, config=existing)
                    self.assertEqual(result.raw_config, json.dumps(existing))
                    self.assertEqual(result.writes, [])

    def test_only_missing_webapp_keys_are_added(self):
        existing = {"webapp": {"enabled": False, "custom": "keep"}, "model": {"default": "chosen"}}
        for config in CONFIGS:
            with self.subTest(config=config):
                result = self.run_starter(config=existing)
                self.assertEqual(json.loads(result.raw_config), {
                    **existing,
                    "webapp": {**existing["webapp"], "host": "127.0.0.1", "port": 9120},
                })
                self.assertEqual(result.writes, ["write"])

    def test_invalid_config_fails_without_rewriting_or_launching_services(self):
        for config in CONFIGS:
            for raw in ("not valid json", '{"webapp": false}', '{"webapp": "invalid"}'):
                with self.subTest(config=config, raw=raw):
                    result = self.run_starter("1",
                                              config=raw, expected_code=1)
                    self.assertEqual(result.raw_config, raw)
                    self.assertEqual(result.writes, [])
                    self.assertEqual(result.calls, [])
                    self.assertIn("could not configure Webapp", result.output)


class NoSshEntrypointTests(unittest.TestCase):
    def run_entrypoint(self, directory, *, command=("sleep", "infinity"),
                       master=None, runtime_status=0, service_status=0, existing=False,
                       env_symlink=None):
        spec = importlib.util.spec_from_file_location("entrypoint_fixture", directory / "hermes_devbox.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        with tempfile.TemporaryDirectory(prefix="hermes-no-ssh-") as temporary:
            fixture = Path(temporary)
            home = fixture / "home"
            data = home / ".hermes"
            data.mkdir(parents=True)
            upstream = fixture / "upstream"
            upstream.mkdir()
            (upstream / ".env.example").write_text("BOOTSTRAP=fixture\n")
            marker = data / "sessions/keep.txt"
            marker.parent.mkdir()
            marker.write_text("existing session\n")
            for legacy in ("hermes-agent", "node"):
                (data / legacy).mkdir()
                (data / legacy / "keep.txt").write_text("legacy data\n")
            if existing:
                (data / ".env").write_text("PRESERVE=existing\n")
                (data / "config.yaml").write_text("model: preserve\n")
            outside = fixture / "outside.env"
            if env_symlink is not None:
                if env_symlink == "valid":
                    outside.write_text("PRESERVE=existing\n")
                    outside.chmod(0o640)
                    outside_before = outside.stat()
                (data / ".env").symlink_to(outside)
            env = {"HOME": str(home), "HERMES_AUTOSTART_DASHBOARD": "1"}
            if master is not None:
                env["HERMES_AUTOSTART_SERVICES"] = master
            recorded = []
            def run(args, **kwargs):
                recorded.append(["run", *args])
                status = service_status if "hermes-start-services" in args[-1] else runtime_status
                return subprocess.CompletedProcess(args, status)
            def execute(program, args):
                recorded.append(["exec", *args])
            output = io.StringIO()
            with (patch.dict(os.environ, env, clear=True),
                  patch.object(runtime, "HOME", home),
                  patch.object(runtime, "RUNTIME", upstream),
                  patch.object(runtime, "RUNTIME_TMP", fixture / "runtime"),
                  patch.object(runtime.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())),
                  patch.object(runtime.subprocess, "run", side_effect=run),
                  patch.object(runtime.os, "execvp", side_effect=execute),
                  contextlib.redirect_stdout(output)):
                runtime.entrypoint(list(command))
            self.assertEqual(marker.read_text(), "existing session\n")
            for legacy in ("hermes-agent", "node"):
                self.assertEqual((data / legacy / "keep.txt").read_text(), "legacy data\n")
            if env_symlink == "dangling":
                self.assertFalse(outside.exists(), "seeding followed the dangling .env symlink")
                self.assertFalse((data / ".env").is_symlink())
                self.assertEqual((data / ".env").stat().st_uid, os.getuid())
                self.assertEqual((data / ".env").stat().st_gid, os.getgid())
            elif env_symlink == "valid":
                self.assertTrue((data / ".env").is_symlink())
                self.assertEqual(outside.read_text(), "PRESERVE=existing\n")
                outside_after = outside.stat()
                for attribute in ("st_ino", "st_mode", "st_uid", "st_gid", "st_mtime_ns"):
                    self.assertEqual(getattr(outside_after, attribute), getattr(outside_before, attribute))
            self.assertEqual((data / ".env").read_text(),
                             "PRESERVE=existing\n" if existing or env_symlink == "valid" else "BOOTSTRAP=fixture\n")
            if not existing and env_symlink != "valid":
                self.assertEqual((data / ".env").stat().st_mode & 0o777, 0o600)
            elif existing:
                self.assertEqual((data / "config.yaml").read_text(), "model: preserve\n")
            for name in ("cron", "sessions", "logs", "pairing", "hooks", "image_cache",
                         "audio_cache", "memories", "skills"):
                self.assertTrue((data / name).is_dir(), name)
            self.assertEqual((fixture / "runtime").stat().st_mode & 0o777, 0o700)
            for forbidden in ("sshd", "ssh-state", "ssh-input", "home/.ssh"):
                self.assertFalse((fixture / forbidden).exists(), forbidden)
            self.assertFalse(any(call[0] in ("sshd", "ssh-keygen") for call in recorded))
            return recorded, output.getvalue()

    def test_entrypoint_has_no_server_key_or_connection_setup(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                script = (directory / "hermes_devbox.py").read_text()
                for forbidden in ("sshd", "ssh-keygen", "authorized_keys", "hermes-ssh",
                                  "HERMES_SSH", "/home/hermes/.ssh"):
                    self.assertNotIn(forbidden, script)

    def test_plain_docker_default_preserves_bootstrap_and_runs_sleep_as_hermes(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                calls, output = self.run_entrypoint(directory)
                self.assertEqual(calls[-1], ["exec", "runuser", "-u", "hermes", "--", "sleep", "infinity"])
                self.assertEqual(len(calls), 2)  # Runtime preflight, then exec.
                self.assertEqual(calls[0][:6], ["run", "runuser", "-u", "hermes", "--", "env"])
                self.assertEqual(calls[0][-1], "--version")
                self.assertIn("legacy Hermes data notice", output)

    def test_existing_data_is_not_replaced_during_restart(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                self.run_entrypoint(directory, existing=True)

    def test_dangling_env_symlink_is_replaced_without_creating_outside_target(self):
        for directory in (SOURCE, ROOT / ".devcontainer"):
            with self.subTest(directory=directory):
                self.run_entrypoint(directory, env_symlink="dangling")

    def test_valid_env_symlink_and_target_are_preserved(self):
        for directory in (SOURCE, ROOT / ".devcontainer"):
            with self.subTest(directory=directory):
                self.run_entrypoint(directory, env_symlink="valid")

    def test_compose_autostart_runs_starter_before_nonroot_keepalive(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                calls, _ = self.run_entrypoint(directory, master="1")
                self.assertEqual([call[0] for call in calls], ["run", "run", "exec"])
                self.assertEqual(calls[1][1:5], ["runuser", "-u", "hermes", "--"])
                self.assertIn("/usr/local/bin/hermes-start-services", calls[1][-1])
                self.assertEqual(calls[-1][1:5], ["runuser", "-u", "hermes", "--"])

    def test_only_exact_one_enables_master_autostart(self):
        for directory in CONFIGS:
            for master in (None, "", "0", "true", "2"):
                with self.subTest(directory=directory, master=master):
                    calls, _ = self.run_entrypoint(directory, master=master)
                    self.assertFalse(any("/usr/local/bin/hermes-start-services" in call for call in calls))

    def test_failed_preflight_or_services_keeps_development_shell_available(self):
        for directory in CONFIGS:
            for runtime_status, service_status in ((1, 0), (0, 1), (1, 1)):
                with self.subTest(directory=directory, runtime=runtime_status, service=service_status):
                    calls, output = self.run_entrypoint(
                        directory, master="1", runtime_status=runtime_status,
                        service_status=service_status,
                    )
                    self.assertEqual(calls[-1], ["exec", "runuser", "-u", "hermes", "--", "sleep", "infinity"])
                    if runtime_status:
                        self.assertIn("runtime check failed", output)
                    if service_status:
                        self.assertIn("reported a problem", output)

    def test_custom_command_is_execed_without_rewriting_arguments(self):
        command = ("bash", "-lc", "printf '%s' 'custom command'")
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                calls, _ = self.run_entrypoint(directory, command=command)
                self.assertEqual(calls[-1], ["exec", *command])

class DispatchAndWrapperTests(unittest.TestCase):
    def test_dispatch_aliases_and_unknown_name(self):
        for name, function in (("hermes", runtime.run_hermes),
                               ("hermes-entrypoint", runtime.entrypoint),
                               ("hermes-start-services", runtime.start_services),
                               ("hermes-webapp-open", runtime.open_webapp)):
            self.assertIs(runtime.dispatch_for(name), function)
        with self.assertRaises(ValueError):
            runtime.dispatch_for("unknown")

    def test_root_wrapper_drops_privileges_before_runtime_environment(self):
        args = ["chat", "--query", "spaces ; $(literal)"]
        with (patch.object(runtime.os, "geteuid", return_value=0),
              patch.object(runtime.os, "execvp") as execute,
              patch.object(runtime, "runtime_environment") as environment):
            runtime.run_hermes(args)
        execute.assert_called_once_with("/usr/sbin/runuser", [
            "/usr/sbin/runuser", "-u", "hermes", "--", "/usr/local/bin/hermes", *args])
        environment.assert_not_called()

    def test_nonroot_execs_official_runtime_with_unchanged_arguments(self):
        args = ["chat", "--query", "spaces ; $(literal)"]
        with (patch.object(runtime.os, "geteuid", return_value=1000),
              patch.object(runtime.os, "execvpe") as execute,
              patch.dict(os.environ, {}, clear=True)):
            runtime.run_hermes(args)
        program, actual, env = execute.call_args.args
        self.assertEqual(program, "/opt/hermes/.venv/bin/hermes")
        self.assertEqual(actual, [program, *args])
        self.assertEqual(env["HOME"], "/home/hermes")
        self.assertEqual(env["HERMES_HOME"], "/home/hermes/.hermes")
        self.assertEqual(env["HERMES_WRITE_SAFE_ROOT"], env["HERMES_HOME"])
        for key, value in {"HERMES_PYTHON": "/opt/hermes/.venv/bin/python",
                           "HERMES_RUNTIME_DIR": "/opt/hermes/tools",
                           "PLAYWRIGHT_BROWSERS_PATH": "/opt/hermes/tools",
                           "HERMES_WEB_DIST": "/opt/hermes/hermes_cli/web_dist",
                           "HERMES_TUI_DIR": "/opt/hermes/ui-tui",
                           "XDG_RUNTIME_DIR": "/tmp/hermes-runtime"}.items():
            self.assertEqual(env[key], value)
        self.assertTrue(env["PATH"].startswith("/usr/local/bin:/home/hermes/.local/bin:"))

    def test_explicit_home_safe_root_and_runtime_directory_are_preserved(self):
        env = runtime.runtime_environment({"HOME": "/custom", "HERMES_HOME": "/data",
            "HERMES_WRITE_SAFE_ROOT": "/safe", "XDG_RUNTIME_DIR": "/runtime"})
        self.assertEqual(env["HOME"], "/custom")
        self.assertEqual(env["HERMES_HOME"], "/data")
        self.assertEqual(env["HERMES_WRITE_SAFE_ROOT"], "/safe")
        self.assertEqual(env["XDG_RUNTIME_DIR"], "/runtime")


class RuntimeBoundaryTests(unittest.TestCase):
    def test_seed_marker_only_created_after_success_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".codex").mkdir()
            (home / ".codex/auth.json").write_text('{"synthetic":true}')
            (home / ".hermes/logs").mkdir(parents=True)
            marker = home / ".hermes/.codex-default-seeded"
            with (patch.object(runtime.os, "access", return_value=True),
                  patch.object(runtime, "run_integration", return_value=subprocess.CompletedProcess([], 2, "", "")) as integration):
                runtime.seed_codex_default_model(home)
                self.assertFalse(marker.exists())
                integration.return_value = subprocess.CompletedProcess([], 0, "fixture", "")
                runtime.seed_codex_default_model(home)
                self.assertTrue(marker.is_file())
                runtime.seed_codex_default_model(home)
                self.assertEqual(integration.call_count, 2)

    def test_seed_timeout_is_retryable(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".codex").mkdir()
            (home / ".codex/auth.json").write_text("synthetic")
            with (patch.object(runtime.os, "access", return_value=True),
                  patch.object(runtime, "run_integration", side_effect=subprocess.TimeoutExpired("python", 30))):
                runtime.seed_codex_default_model(home)
            self.assertFalse((home / ".hermes/.codex-default-seeded").exists())

    def test_missing_codex_auth_never_invokes_integration(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runtime, "run_integration") as integration:
            runtime.seed_codex_default_model(Path(directory))
        integration.assert_not_called()

    def test_workspace_ambiguity_keeps_current_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            workspaces = Path(directory)
            with patch.object(runtime, "WORKSPACES", workspaces):
                self.assertEqual(runtime.select_workspace(), Path.cwd())
                (workspaces / "first").mkdir()
                (workspaces / "second").mkdir()
                self.assertEqual(runtime.select_workspace(), Path.cwd())

    def test_launch_detaches_service_without_shell_or_inherited_input(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "gateway.out"
            with patch.object(runtime.subprocess, "Popen") as launch:
                runtime.launch_service(["hermes", "gateway"], cwd=Path(directory), log=log)
            self.assertEqual(launch.call_args.args, (["hermes", "gateway"],))
            self.assertEqual(launch.call_args.kwargs["cwd"], Path(directory))
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            self.assertEqual(launch.call_args.kwargs["stdin"], subprocess.DEVNULL)
            self.assertNotIn("shell", launch.call_args.kwargs)
            self.assertTrue(log.is_file())

    def test_main_invokes_selected_command(self):
        with patch.object(runtime, "entrypoint", return_value=0) as entrypoint:
            self.assertEqual(runtime.main(["sleep", "infinity"], "/usr/local/bin/hermes-entrypoint"), 0)
        entrypoint.assert_called_once_with(["sleep", "infinity"])

    def test_main_sanitizes_external_exception_text(self):
        output = io.StringIO()
        with (patch.object(runtime, "open_webapp", side_effect=OSError("private-ticket")),
              contextlib.redirect_stderr(output)):
            self.assertEqual(runtime.main([], "hermes-webapp-open"), 1)
        self.assertNotIn("private-ticket", output.getvalue())
        self.assertIn("OSError", output.getvalue())

    def test_main_rejects_unknown_program(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(runtime.main([], "unknown"), 1)
