"""Exercise disposable runtime resource ownership without a Docker daemon."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class RuntimeFixtureTests(unittest.TestCase):
    def module(self):
        path = ROOT / "scripts/validate-hermes-runtime.py"
        self.assertTrue(path.is_file(), "disposable runtime validator is missing")
        spec = importlib.util.spec_from_file_location("hermes_runtime_validation", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_runtime_does_not_inherit_operator_bootstrap_inputs(self):
        module = self.module()
        with patch.dict(os.environ, {"HERMES_MODEL_PROVIDER": "operator-provider",
                                    "HERMES_WEBAPP_PORT": "9999",
                                    "HERMES_SKILLS_INSTALL": "operator/repo/skill",
                                    "HERMES_SKILLS_TAPS": "operator/repo"}):
            runtime = module.Runtime("fixture:image")
            try:
                self.assertNotIn("HERMES_MODEL_PROVIDER", runtime.env)
                self.assertNotIn("HERMES_WEBAPP_PORT", runtime.env)
                self.assertEqual(runtime.env["HERMES_SKILLS_INSTALL"], "")
                self.assertEqual(runtime.env["HERMES_SKILLS_TAPS"], "")
                with patch.object(runtime, "docker") as docker:
                    runtime.container("isolated")
                    args = docker.call_args.args
                    self.assertIn("HERMES_SKILLS_INSTALL=", args)
                    self.assertIn("HERMES_SKILLS_TAPS=", args)
            finally:
                runtime.temp.cleanup()

    def test_runtime_wrapper_is_executable(self):
        wrapper = ROOT / "scripts/validate-hermes-runtime.sh"
        self.assertEqual(wrapper.stat().st_mode & 0o777, 0o755)

    def test_signals_clean_owned_resources_ignore_repeated_signals_and_restore_handlers(self):
        driver = r'''
import importlib.util, json, os, pathlib, signal, subprocess, sys, time
spec = importlib.util.spec_from_file_location("runtime", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = pathlib.Path(sys.argv[2])
owned = state / "owned-container"
previous = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}
def docker(*args, **kwargs):
    with (state / "calls.jsonl").open("a") as stream:
        stream.write(json.dumps(args) + "\n")
    if args[0] == "run":
        owned.touch()
    if args[0] == "rm":
        # A second cancellation must not interrupt cleanup of the first one.
        os.kill(os.getpid(), signal.SIGTERM)
        os.kill(os.getpid(), signal.SIGINT)
        owned.unlink()
    return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
runtime = module.Runtime("fixture:image")
runtime.docker = docker
try:
    with runtime:
        runtime.container("signal")
        (state / "ready.json").write_text(json.dumps({"work": str(runtime.work), "prefix": runtime.prefix}))
        while True:
            time.sleep(60)
finally:
    (state / "restored").write_text(str(all(signal.getsignal(n) == h for n, h in previous.items())))
'''
        scratch = Path(os.environ.get("TMPDIR", Path.home() / ".cache"))
        scratch.mkdir(parents=True, exist_ok=True)
        for number in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=number), tempfile.TemporaryDirectory(dir=scratch) as directory:
                state = Path(directory)
                child = subprocess.Popen(
                    [sys.executable, "-c", driver, str(ROOT / "scripts/validate-hermes-runtime.py"), directory],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                work = None
                try:
                    deadline = time.monotonic() + 5
                    while not (state / "ready.json").exists() and child.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue((state / "ready.json").exists(), "runtime subprocess did not start")
                    ready = json.loads((state / "ready.json").read_text())
                    work = Path(ready["work"])
                    child.send_signal(number)
                    stdout, stderr = child.communicate(timeout=5)
                    self.assertEqual(child.returncode, 128 + number, stdout + stderr)
                    self.assertFalse((state / "owned-container").exists(), "owned container leaked on cancellation")
                    self.assertFalse(work.exists(), "synthetic credentials/temp fixture leaked")
                    self.assertEqual((state / "restored").read_text(), "True")
                    calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()]
                    self.assertIn(["rm", "-f", "-v", ready["prefix"] + "-signal"], calls)
                    self.assertIn(["ps", "-aq", "--filter", "label=hermes.validation=" + ready["prefix"]], calls)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.communicate(timeout=5)
                    if work is not None and work.exists():
                        import shutil
                        shutil.rmtree(work)

    def test_partial_container_start_is_cleaned_by_exact_owned_name(self):
        module = self.module()
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if args[:2] == ["docker", "run"]:
                raise subprocess.CalledProcessError(125, args)
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(module.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                with module.Runtime("fixture:image") as runtime:
                    runtime.container("partial")
        created = next(args[args.index("--name") + 1] for args in calls if args[1] == "run")
        self.assertTrue(created.startswith("hermes-runtime-"))
        self.assertIn(["docker", "rm", "-f", "-v", created], calls)
        self.assertFalse(any("prune" in args for args in calls))

    def test_compose_uses_synthetic_auth_workspace_and_explicit_env_file(self):
        module = self.module()
        with patch.object(module.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
            with module.Runtime("fixture:image") as runtime:
                runtime.compose("one", "up", "-d")
                args = run.call_args.args[0]
                self.assertIn("--env-file", args)
                self.assertEqual(json.loads(runtime.auth.read_text()), {"tokens": None})
                override = json.loads(runtime.override.read_text())["services"]["devcontainer"]
                self.assertEqual(override["image"], "fixture:image")
                workspace = next(m for m in override["volumes"] if m["target"] == "/workspaces")
                self.assertTrue(Path(workspace["source"]).is_relative_to(runtime.work))
                self.assertEqual(runtime.env["DEVBOX_HOST_HOME"], str(runtime.work / "host-home"))
                self.assertEqual(runtime.env["HERMES_AUTOSTART_DASHBOARD"], "0")
                self.assertEqual(runtime.env["HERMES_AUTOSTART_SERVICES"], "1")
                work = runtime.work
            self.assertFalse(work.exists())

    def test_cleanup_failure_is_not_reported_as_success(self):
        module = self.module()

        def run(args, **kwargs):
            if args[:2] == ["docker", "rm"]:
                return subprocess.CompletedProcess(args, 1, stdout="", stderr="cleanup failed")
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(module.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "cleanup"):
                with module.Runtime("fixture:image") as runtime:
                    runtime.container("one")

    def test_cleanup_timeout_continues_all_resources_and_aggregates_failures(self):
        module = self.module()
        for failure_at in ("compose", "compose-containers", "compose-volumes",
                           "container", "volume", "ownership-check"):
            with self.subTest(failure_at=failure_at):
                calls = []
                runtime = module.Runtime("fixture:image")
                first_project = runtime.prefix + "-first-project"
                later_project = runtime.prefix + "-later-project"
                first_container = runtime.prefix + "-first-container"
                later_container = runtime.prefix + "-later-container"
                first_volume = runtime.prefix + "-first-volume"
                later_volume = runtime.prefix + "-later-volume"
                runtime.projects.extend((first_project, later_project))
                runtime.containers.extend((first_container, later_container))
                runtime.volumes.extend((first_volume, later_volume))
                project_filter = "label=com.docker.compose.project=" + first_project
                failing_commands = {
                    "compose": ["docker", "compose", "--env-file", str(runtime.empty_env),
                                "-p", first_project, "-f", str(module.CONTEXT / "docker-compose.yml"),
                                "-f", str(runtime.override), "down", "-v", "--remove-orphans"],
                    "compose-containers": ["docker", "ps", "-aq", "--filter", project_filter],
                    "compose-volumes": ["docker", "volume", "ls", "-q", "--filter", project_filter],
                    "container": ["docker", "rm", "-f", "-v", first_container],
                    "volume": ["docker", "volume", "rm", first_volume],
                    "ownership-check": ["docker", "ps", "-aq", "--filter",
                                        "label=hermes.validation=" + runtime.prefix],
                }

                def run(args, **kwargs):
                    calls.append(args)
                    if args == failing_commands[failure_at]:
                        raise subprocess.TimeoutExpired(args, 300)
                    return subprocess.CompletedProcess(
                        args, int(args == ["docker", "volume", "rm", later_volume]),
                        stdout="", stderr="")

                with patch.object(module.subprocess, "run", side_effect=run):
                    with self.assertRaises(Exception) as raised:
                        with runtime:
                            raise ValueError("checkpoint failed")
                self.assertIsInstance(raised.exception, RuntimeError)
                self.assertIn("cleanup", str(raised.exception))
                self.assertIn("TimeoutExpired", str(raised.exception))
                self.assertIn(runtime.prefix, str(raised.exception))
                self.assertIn(later_volume, str(raised.exception))
                self.assertIsInstance(raised.exception.__cause__, ValueError)
                self.assertTrue(any(later_project in args and "down" in args for args in calls))
                for name in (first_container, later_container):
                    self.assertIn(["docker", "rm", "-f", "-v", name], calls)
                for volume in (first_volume, later_volume):
                    self.assertIn(["docker", "volume", "rm", volume], calls)
                self.assertFalse(runtime.work.exists(), "temporary fixture must still be removed")

    def test_timed_out_legacy_seed_is_owned_before_launch_and_removed(self):
        module = self.module()
        calls = []
        launches = []

        def run(args, **kwargs):
            calls.append(args)
            if args[:2] == ["docker", "run"]:
                launches.append((args, list(runtime.containers)))
                raise subprocess.TimeoutExpired(args, 300)
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(module.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.TimeoutExpired):
                with module.Runtime("fixture:image") as runtime:
                    module.check_e(runtime)
        self.assertEqual(len(launches), 1)
        args, registered = launches[0]
        self.assertIn("--name", args, "seed must have an exact cleanup target")
        name = args[args.index("--name") + 1]
        self.assertTrue(name.startswith(runtime.prefix + "-"))
        self.assertIn(name, registered, "register seed before a partially successful Docker run")
        self.assertIn("--label", args)
        self.assertEqual(args[args.index("--label") + 1], "hermes.validation=" + runtime.prefix)
        self.assertNotIn("--rm", args, "explicit cleanup also owns successful seed runs")
        remove_seed = ["docker", "rm", "-f", "-v", name]
        remove_volume = ["docker", "volume", "rm", runtime.prefix + "-legacy"]
        self.assertIn(remove_seed, calls)
        self.assertIn(remove_volume, calls)
        self.assertLess(calls.index(remove_seed), calls.index(remove_volume))
        self.assertFalse(runtime.work.exists())

    def test_no_ssh_daemon_is_used_as_webapp_readiness_signal(self):
        text = (ROOT / "scripts/validate-hermes-webapp.py").read_text()
        self.assertNotIn('"sshd"', text)
        self.assertIn('"sleep"', text)


if __name__ == "__main__":
    unittest.main()
