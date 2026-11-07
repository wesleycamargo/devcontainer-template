"""Run the real smoke shell against disposable Git and fake Docker/CLI boundaries.

These are orchestration unit tests, not evidence of a working Docker runtime.
No operator .env or credential path is read, copied, or mounted.
"""

from contextlib import contextmanager, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/validate-hermes-devcontainer.sh"
FEATURES = {
    "ghcr.io/devcontainers/features/common-utils:2": {"username": "hermes"},
    "ghcr.io/rchaganti/vsc-devcontainer-features/azurebicep:1": {"version": "latest"},
}
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, stat, subprocess, sys, time
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
case = os.environ.get("SMOKE_CASE", "")
state_path = pathlib.Path(os.environ["SMOKE_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {}
project = os.environ.get("COMPOSE_PROJECT_NAME")
record = {"tool": tool, "args": args, "cwd": os.getcwd(), "env": {
    key: os.environ.get(key) for key in (
        "COMPOSE_PROJECT_NAME", "DEVBOX_HOST_HOME", "HERMES_AUTOSTART_SERVICES",
        "HERMES_AUTOSTART_DASHBOARD", "COMPOSE_FILE", "COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE",
    )
}}
if tool == "docker" and args[0] == "compose" and "down" in args and os.environ.get("SMOKE_PIDS"):
    pids_path = pathlib.Path(os.environ["SMOKE_PIDS"])
    if pids_path.exists():
        record["live_hanging_pids"] = []
        for pid in json.loads(pids_path.read_text()):
            status = pathlib.Path(f"/proc/{pid}/stat")
            if status.exists() and not status.read_text().split(") ")[1].startswith("Z"):
                record["live_hanging_pids"].append(pid)
if tool == "devcontainer" and args[0] == "up":
    fixture = pathlib.Path(args[args.index("--workspace-folder") + 1])
    config = fixture / ".devcontainer"
    auth = pathlib.Path(os.environ["DEVBOX_HOST_HOME"]) / ".codex/auth.json"
    record["snapshot"] = {
        "files": sorted(str(p.relative_to(fixture)) for p in fixture.rglob("*") if p.is_file()),
        "config": json.loads((config / "devcontainer.json").read_text()),
        "lock": (config / "devcontainer-lock.json").read_text(),
        "override": json.loads((config / "docker-compose.test.yml").read_text()),
        "auth": json.loads(auth.read_text()), "auth_mode": stat.S_IMODE(auth.stat().st_mode),
        "auth_path": str(auth), "marker": (fixture / "smoke-marker.txt").read_text(),
        "tracked": (config / "nested/tracked file.txt").read_text(),
        "modes": {name: stat.S_IMODE(path.stat().st_mode) for name, path in {
            "parent": fixture.parent, "workspace": fixture, "config": config,
            "host_home": auth.parent.parent, "codex": auth.parent,
            "marker": fixture / "smoke-marker.txt",
        }.items()},
    }
    state["project"] = project
    state["resources"] = True
    state_path.write_text(json.dumps(state))
with open(os.environ["SMOKE_LOG"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
hang = tool == "devcontainer" and case == args[0] + "-hang"
hang |= tool == "docker" and (
    (case == "down-hang" and args[0] == "compose" and "down" in args) or
    (case == "ps-hang" and args[:2] == ["ps", "-aq"]) or
    (case == "volume-hang" and args[:3] == ["volume", "ls", "-q"]) or
    (case == "info-hang" and args == ["info"]))
hang |= tool == "rm" and case == "rm-hang"
if hang:
    # Neither the boundary nor its child exits on its own or cooperates with TERM.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    pathlib.Path(os.environ["SMOKE_PIDS"]).write_text(json.dumps([os.getppid(), os.getpid(), child.pid]))
    time.sleep(60)
if tool == "devcontainer":
    if args[0] == "up":
        if case == "interrupted":
            os.kill(os.getppid(), signal.SIGTERM)
        sys.exit(42 if case == "up-fail" else 0)
    if args[0] == "exec":
        sys.exit(43 if case == "exec-fail" else 0)
    sys.exit("unexpected CLI call")
if args == ["info"]:
    sys.exit(44 if case == "info-fail" else 0)
if args[0] == "compose" and "down" in args:
    if case == "down-fail":
        sys.exit(45)
    state["resources"] = case in ("leftover-container", "leftover-volume")
    state_path.write_text(json.dumps(state))
    sys.exit(0)
if args[:2] == ["ps", "-aq"]:
    if case == "ps-fail":
        sys.exit(46)
    if case == "leftover-container" and state.get("resources"):
        print("owned-container")
    sys.exit(0)
if args[:3] == ["volume", "ls", "-q"]:
    if case == "volume-fail":
        sys.exit(47)
    if case == "leftover-volume" and state.get("resources"):
        print("owned-volume")
    sys.exit(0)
sys.exit("unexpected Docker call: " + repr(args))
'''


class DevcontainerSmokeTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(os.environ.get("TMPDIR", Path.home() / ".cache"))
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="test-hermes-smoke-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / "repo"
        self.config = self.repo / "src/ai-hermes-devbox/.devcontainer"
        self.config.mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        self.bin = self.work / "bin"
        self.bin.mkdir()
        for tool in ("docker", "devcontainer"):
            path = self.bin / tool
            path.write_text(FAKE)
            path.chmod(0o755)
        self.manifest = {
            "dockerComposeFile": "docker-compose.yml", "service": "devcontainer",
            "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
            "remoteUser": "hermes", "features": FEATURES,
            "postCreateCommand": "true",
        }
        self.lock = json.dumps({"features": {key: {"version": "1.2.3", "integrity": "sha256-synthetic"} for key in FEATURES}})
        (self.config / "devcontainer.json").write_text("// JSONC whole-line comment\n" + json.dumps(self.manifest))
        (self.config / "devcontainer-lock.json").write_text(self.lock)
        (self.config / "Dockerfile").write_text("FROM synthetic:fixture\nARG GITHUB_CLI_VERSION=2.103.3\n")
        (self.config / "docker-compose.yml").write_text("services:\n  devcontainer:\n    image: synthetic:fixture\n")
        (self.config / ".gitignore").write_text(".env\n")
        (self.config / ".env.example").write_text("HERMES_AUTOSTART_DASHBOARD=0\n")
        (self.config / "nested").mkdir()
        (self.config / "nested/tracked file.txt").write_text("tracked working-tree contents\n")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "src"], check=True)
        # Poison ignored inputs with FIFOs: reading/copying either would hang.
        # They are synthetic paths inside this test, never the operator's home.
        os.mkfifo(self.config / ".env")
        (self.repo / ".env").write_text("COMPOSE_PROJECT_NAME=must-not-use\n")
        self.operator_home = self.work / "operator-home"
        (self.operator_home / ".codex").mkdir(parents=True)
        os.mkfifo(self.operator_home / ".codex/auth.json")
        self.scratch = self.work / "scratch"
        self.scratch.mkdir()
        self.log = self.work / "calls.jsonl"
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.operator_home), "TMPDIR": str(self.scratch),
            "DEVBOX_HOST_HOME": str(self.operator_home),
            "COMPOSE_PROJECT_NAME": "must-not-use", "HERMES_AUTOSTART_SERVICES": "0",
            "HERMES_AUTOSTART_DASHBOARD": "1", "SMOKE_LOG": str(self.log),
            "SMOKE_STATE": str(self.work / "state.json"),
        }

    def run_smoke(self, case="", image="fixture:image", restrictive_umask=False):
        self.assertTrue(SCRIPT.is_file(), "real disposable devcontainer smoke script is missing")
        script = self.repo / "scripts" / SCRIPT.name
        shutil.copyfile(SCRIPT, script)
        command = ["bash", str(script), image]
        if restrictive_umask:
            command = ["bash", "-c", 'umask 077; exec "$@"', "smoke-umask", *command]
        result = subprocess.run(
            command, cwd=self.repo, env={**self.env, "SMOKE_CASE": case},
            text=True, capture_output=True, timeout=15,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def assert_exact_cleanup(self, calls):
        up = next(call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "up")
        project = up["env"]["COMPOSE_PROJECT_NAME"]
        fixture = Path(up["cwd"])
        docker = [call["args"] for call in calls if call["tool"] == "docker"]
        self.assertEqual(docker, [["info"], [
            "compose", "-p", project, "-f", str(fixture / ".devcontainer/docker-compose.yml"),
            "-f", str(fixture / ".devcontainer/docker-compose.test.yml"),
            "down", "-v", "--remove-orphans",
        ], ["ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"],
            ["volume", "ls", "-q", "--filter", f"label=com.docker.compose.project={project}"],
        ], "cleanup may touch only this exact project; no global or foreign cleanup")
        self.assertFalse(fixture.parent.exists())

    def test_partial_up_failure_propagates_after_exact_project_cleanup(self):
        result, calls = self.run_smoke("up-fail")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assert_exact_cleanup(calls)
        state = json.loads((self.work / "state.json").read_text())
        self.assertFalse(state["resources"], "partial startup resources must be removed")
        self.assertNotIn("PASS", result.stdout)

    def test_interrupted_up_cleans_the_exact_project(self):
        result, calls = self.run_smoke("interrupted")
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assert_exact_cleanup(calls)
        self.assertNotIn("PASS disposable Dev Container", result.stdout)

    def test_shell_cancellation_stops_and_reaps_hanging_cli_before_cleanup(self):
        for phase in ("up", "exec"):
            for number in (signal.SIGTERM, signal.SIGINT):
                with self.subTest(phase=phase, signal=number), self.hanging_smoke(
                    phase + "-hang", HERMES_SMOKE_UP_TIMEOUT="90", HERMES_SMOKE_EXEC_TIMEOUT="90",
                ) as (child, pids):
                    child.send_signal(number)
                    try:
                        stdout, stderr = child.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.fail("shell deferred cancellation while waiting for a stuck foreground CLI")
                    self.assertEqual(child.returncode, 128 + number, stdout + stderr)
                    calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                    self.assert_exact_cleanup(calls)
                    down = next(call for call in calls if call["tool"] == "docker" and "down" in call["args"])
                    self.assertEqual(down["live_hanging_pids"], [], "cleanup ran before the active group stopped/reaped")
                    self.assertNotIn("PASS disposable Dev Container", stdout)
                    self.assert_stopped(pids)

    def assert_stopped(self, pids):
        self.assertFalse(Path(f"/proc/{pids[0]}").exists(), "timeout leader must be reaped")
        for pid in pids[1:]:
            status = Path(f"/proc/{pid}/stat")
            self.assertTrue(not status.exists() or status.read_text().split(") ")[1].startswith("Z"),
                            f"hanging child {pid} is still alive")

    @contextmanager
    def hanging_smoke(self, case, **knobs):
        self.log.unlink(missing_ok=True)
        pids_file = self.work / "pids.json"
        pids_file.unlink(missing_ok=True)
        script = self.repo / "scripts" / SCRIPT.name
        shutil.copyfile(SCRIPT, script)
        child = subprocess.Popen(
            ["bash", str(script), "fixture:image"], cwd=self.repo,
            env={**self.env, "SMOKE_CASE": case, "SMOKE_PIDS": str(pids_file),
                 "HERMES_SMOKE_KILL_AFTER": "1", **knobs},
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        pids = []
        try:
            deadline = time.monotonic() + 5
            while not pids_file.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pids_file.exists(), "fake boundary did not start hanging")
            pids = json.loads(pids_file.read_text())
            for pid in pids:
                os.kill(pid, 0)
            yield child, pids
        finally:
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=5)

    def test_hanging_cleanup_operations_are_bounded_and_later_checks_still_run(self):
        for case in ("down-hang", "ps-hang", "volume-hang"):
            with self.subTest(case=case), self.hanging_smoke(case, HERMES_SMOKE_CLEANUP_TIMEOUT="1") as (child, pids):
                # Repeated cancellation during cleanup must not skip inspection or rm.
                child.send_signal(signal.SIGTERM)
                child.send_signal(signal.SIGINT)
                try:
                    stdout, stderr = child.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    self.fail("an unbounded cleanup operation prevented later checks/fixture cleanup")
                self.assertNotEqual(child.returncode, 0, stdout + stderr)
                self.assertIn("FAIL cleanup", stderr)
                self.assertNotIn("PASS disposable Dev Container", stdout)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assert_exact_cleanup(calls)
                self.assert_stopped(pids)

    def test_hanging_docker_info_is_bounded_before_allocating_a_fixture(self):
        with self.hanging_smoke("info-hang", HERMES_SMOKE_INFO_TIMEOUT="1") as (child, pids):
            try:
                stdout, stderr = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.fail("Docker daemon preflight is unbounded")
            self.assertNotEqual(child.returncode, 0, stdout + stderr)
            self.assertNotIn("PASS", stdout)
            calls = [json.loads(line) for line in self.log.read_text().splitlines()]
            self.assertEqual([(call["tool"], call["args"]) for call in calls], [("docker", ["info"])])
            self.assertEqual(list(self.scratch.iterdir()), [])
            self.assert_stopped(pids)

    def test_hanging_fixture_removal_is_bounded_and_fails_closed(self):
        remove = self.bin / "rm"
        remove.write_text(FAKE)
        remove.chmod(0o755)
        with self.hanging_smoke("rm-hang", HERMES_SMOKE_CLEANUP_TIMEOUT="1") as (child, pids):
            stdout, stderr = child.communicate(timeout=5)
            self.assertNotEqual(child.returncode, 0, stdout + stderr)
            self.assertIn("FAIL cleanup of temporary fixture", stderr)
            self.assertNotIn("PASS disposable Dev Container", stdout)
            calls = [json.loads(line) for line in self.log.read_text().splitlines()]
            up = next(call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "up")
            fixture = Path(up["cwd"])
            self.assertEqual(calls[-1]["tool"], "rm")
            self.assertEqual(calls[-1]["args"], ["-rf", "--", str(fixture.parent)])
            docker = [call["args"] for call in calls if call["tool"] == "docker"]
            self.assertEqual([args[0] for args in docker], ["info", "compose", "ps", "volume"])
            self.assertFalse(json.loads((self.work / "state.json").read_text())["resources"])
            self.assertTrue(fixture.parent.exists(), "fake rm must not pretend to remove the fixture")
            self.assert_stopped(pids)

    def test_cli_timeouts_kill_stuck_groups_and_propagate_failure_after_cleanup(self):
        for phase in ("up", "exec"):
            with self.subTest(phase=phase), self.hanging_smoke(
                phase + "-hang", HERMES_SMOKE_UP_TIMEOUT="1", HERMES_SMOKE_EXEC_TIMEOUT="1",
            ) as (child, pids):
                stdout, stderr = child.communicate(timeout=5)
                self.assertNotEqual(child.returncode, 0, stdout + stderr)
                self.assertNotIn("PASS disposable Dev Container", stdout)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assert_exact_cleanup(calls)
                down = next(call for call in calls if call["tool"] == "docker" and "down" in call["args"])
                self.assertEqual(down["live_hanging_pids"], [])
                self.assert_stopped(pids)

    def test_timeout_overrides_reject_nonpositive_or_noninteger_values(self):
        for knob in ("HERMES_SMOKE_INFO_TIMEOUT", "HERMES_SMOKE_UP_TIMEOUT", "HERMES_SMOKE_EXEC_TIMEOUT",
                     "HERMES_SMOKE_CLEANUP_TIMEOUT", "HERMES_SMOKE_KILL_AFTER"):
            for value in ("", "0", "-1", "0.5", "1s", "invalid"):
                with self.subTest(knob=knob, value=value):
                    self.env[knob] = value
                    try:
                        result, calls = self.run_smoke()
                    finally:
                        self.env.pop(knob)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"FAIL {knob} must be a positive integer", result.stderr)
                    self.assertEqual(calls, [])
                    self.assertEqual(list(self.scratch.iterdir()), [])

    def test_non_gnu_timeout_is_rejected_before_any_resource_is_allocated(self):
        timeout = self.bin / "timeout"
        timeout.write_text("#!/bin/sh\nprintf 'BusyBox timeout\\n'\n")
        timeout.chmod(0o755)
        result, calls = self.run_smoke()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GNU coreutils timeout is required", result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_cleanup_failures_or_unverifiable_resource_absence_fail_the_gate(self):
        for case in ("down-fail", "leftover-container", "leftover-volume", "ps-fail", "volume-fail"):
            with self.subTest(case=case):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_smoke(case)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("FAIL cleanup", result.stderr)
                self.assert_exact_cleanup(calls)
                self.assertNotIn("PASS disposable Dev Container", result.stdout)

    def payloads(self, calls):
        commands = [call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "exec"]
        self.assertEqual(len(commands), 4, "must execute tools, protected Webapp readiness, gateway cwd, and absent-service checks")
        up = next(call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "up")
        for command in commands:
            for option in ("--workspace-folder", "--id-label", "--user-data-folder"):
                self.assertEqual(command["args"][command["args"].index(option) + 1], up["args"][up["args"].index(option) + 1])
            self.assertEqual(command["cwd"], up["cwd"])
        return [call["args"] for call in commands]

    def test_exec_failure_is_propagated_and_the_project_is_still_cleaned(self):
        result, calls = self.run_smoke("exec-fail")
        self.assertEqual(result.returncode, 43, result.stdout + result.stderr)
        self.assert_exact_cleanup(calls)
        self.assertNotIn("PASS disposable Dev Container", result.stdout)

    def test_exec_payload_checks_identity_workspace_exact_gh_and_every_tool(self):
        result, calls = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS disposable Dev Container", result.stdout)
        tools = self.payloads(calls)[0]
        self.assertIn("bash", tools)
        code = tools[tools.index("bash") + 2]
        up = next(call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "up")
        project = up["env"]["COMPOSE_PROJECT_NAME"]
        self.assertEqual(tools[-2:], [project, "2.103.3"])
        runtime = self.work / "simulated-container-workspace"
        runtime.mkdir()
        (runtime / "smoke-marker.txt").write_text("synthetic marker\n")
        log = self.work / "tools.log"
        prelude = r'''
PWD="${SIMULATED_CWD:-/workspaces/$1}"
id() {
  case "$1" in
    -un) printf "%s\n" "${SIMULATED_USER:-hermes}" ;;
    -u) printf "%s\n" "${SIMULATED_UID:-1000}" ;;
    -g) printf "%s\n" "${SIMULATED_GID:-1000}" ;;
    *) return 98 ;;
  esac
}
record_tool() { printf "%s\n" "$*" >> "$TOOL_LOG"; test "${SIMULATED_FAIL:-}" != "$1"; }
gh() { record_tool gh "$@" || return; printf "%s\n" "${SIMULATED_GH:-gh version 2.103.3 (synthetic)}"; }
bicep() { record_tool bicep "$@"; }
zsh() { record_tool zsh "$@"; }
pwsh() { record_tool pwsh "$@"; }
hermes() { record_tool hermes "$@"; }
claude() { record_tool claude "$@"; }
codex() { record_tool codex "$@"; }
'''
        def run(**overrides):
            return subprocess.run(
                ["bash", "-euc", prelude + code, "smoke", project, "2.103.3"],
                cwd=runtime, env={**self.env, "TOOL_LOG": str(log), **overrides},
                capture_output=True, text=True, timeout=10,
            )
        healthy = run()
        self.assertEqual(healthy.returncode, 0, healthy.stdout + healthy.stderr)
        checked = log.read_text().splitlines()
        for command in ("gh --version", "bicep --version", "hermes --version", "claude --version", "codex --version"):
            self.assertIn(command, checked)
        self.assertTrue(any(line.startswith("pwsh ") and "Import-Module Terminal-Icons" in line for line in checked))
        bad_contracts = [
            {"SIMULATED_USER": "root"}, {"SIMULATED_UID": "1001"},
            {"SIMULATED_GID": "1001"}, {"SIMULATED_CWD": "/wrong"},
            {"SIMULATED_GH": "gh version 2.103.30 (wrong prefix match)"},
            *({"SIMULATED_FAIL": name} for name in ("gh", "bicep", "pwsh", "hermes", "claude", "codex")),
        ]
        for contract in bad_contracts:
            with self.subTest(contract=contract):
                self.assertNotEqual(run(**contract).returncode, 0)
        (runtime / "smoke-marker.txt").unlink()
        self.assertNotEqual(run().returncode, 0)

    def test_gateway_payload_requires_the_exact_workspace_cwd(self):
        result, calls = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = self.payloads(calls)[2]
        code = args[args.index("bash") + 2]
        prelude = r'''pgrep() {
  case "${SIMULATED_GATEWAY:-one}" in
    one) printf '%s\n' 4242 ;;
    none) return 1 ;;
    many) printf '%s\n%s\n' 4242 4243 ;;
  esac
}
readlink() { printf '%s\n' "${SIMULATED_CWD:-/workspaces/$WORKSPACE_NAME}"; }
'''
        project = args[-1]
        for gateway, cwd, expected in (
            ("one", f"/workspaces/{project}", 0),
            ("one", "/wrong", 1), ("none", f"/workspaces/{project}", 1),
            ("many", f"/workspaces/{project}", 1),
        ):
            with self.subTest(gateway=gateway, cwd=cwd):
                checked = subprocess.run(
                    ["bash", "-euc", prelude + code, "gateway-cwd", project],
                    env={**self.env, "SIMULATED_GATEWAY": gateway, "SIMULATED_CWD": cwd,
                         "WORKSPACE_NAME": project},
                    text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(bool(checked.returncode), bool(expected), checked.stdout + checked.stderr)

    def test_absent_service_payload_rejects_dashboard_sshd_and_pgrep_errors(self):
        result, calls = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = self.payloads(calls)[3]
        code = args[args.index("bash") + 2]
        prelude = r'''
pgrep() {
  case "${SIMULATED_PROCESS:-}:$*" in
    dashboard:*dashboard*|sshd:*sshd*) return 0 ;;
    error:*) return 2 ;;
    *) return 1 ;;
  esac
}
'''
        for process, expected in (("", 0), ("dashboard", 1), ("sshd", 1), ("error", 1)):
            with self.subTest(process=process):
                checked = subprocess.run(
                    ["bash", "-euc", prelude + code], env={**self.env, "SIMULATED_PROCESS": process},
                    text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(bool(checked.returncode), bool(expected), checked.stdout + checked.stderr)

    def test_webapp_payload_requires_auth_and_retries_only_bounded_startup_responses(self):
        result, calls = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = self.payloads(calls)[1]
        code = args[args.index("python3") + 2]
        starting = (503, b'{"error":"gateway_not_ready","state":"starting"}')

        def probe(events):
            clock, requests, output = [0], [], io.StringIO()
            def opened(url, timeout):
                requests.append((url, timeout))
                event = events[min(len(requests) - 1, len(events) - 1)]
                if event == "connection":
                    raise urllib.error.URLError("synthetic connection refused")
                status, body = event
                if status >= 400:
                    raise urllib.error.HTTPError(url, status, "synthetic", {}, io.BytesIO(body))
                return io.BytesIO(body)
            def sleep(seconds):
                clock[0] += seconds
            with patch("urllib.request.build_opener", return_value=SimpleNamespace(open=opened)) as build, \
                    patch("time.monotonic", side_effect=lambda: clock[0]), \
                    patch("time.sleep", side_effect=sleep), redirect_stdout(output):
                status = 0
                try:
                    exec(compile(code, "<actual Webapp exec payload>", "exec"), {})
                except SystemExit as exc:
                    status = 0 if exc.code in (None, 0) else 1
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertTrue(all(url == "http://127.0.0.1:9120/api/sessions" and 0 < timeout <= 3 for url, timeout in requests))
            return status, requests, clock[0], output.getvalue()

        for status in (401, 403):
            with self.subTest(auth_status=status):
                checked, requests, _, _ = probe([(status, b"{}")])
                self.assertEqual(checked, 0)
                self.assertEqual(len(requests), 1)
        checked, requests, _, output = probe([starting, "connection", (403, b"{}")])
        self.assertEqual(checked, 0)
        self.assertEqual(len(requests), 3)
        self.assertIn("PASS", output)
        for response in ((200, b"{}"), (500, b"{}"), (503, b"{}"), (503, b"not JSON")):
            with self.subTest(response=response):
                checked, requests, _, _ = probe([response])
                self.assertNotEqual(checked, 0)
                self.assertEqual(len(requests), 1)
        checked, requests, elapsed, _ = probe([starting])
        self.assertNotEqual(checked, 0)
        self.assertLessEqual(len(requests), 90)
        self.assertLessEqual(elapsed, 90)

    def test_fixture_is_readable_by_container_uid_even_with_restrictive_host_umask(self):
        result, calls = self.run_smoke(restrictive_umask=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        up = next(call for call in calls if "snapshot" in call)
        modes = up["snapshot"]["modes"]
        for name in ("parent", "workspace", "config", "host_home", "codex"):
            with self.subTest(path=name):
                self.assertEqual(modes[name] & 0o005, 0o005, "container UID must traverse the mounted workspace")
        self.assertEqual(modes["marker"] & 0o004, 0o004)

    def test_operator_compose_environment_cannot_redirect_to_secret_files(self):
        self.env["COMPOSE_ENV_FILES"] = str(self.config / ".env")
        self.env["COMPOSE_FILE"] = str(self.operator_home / "private-compose.yml")
        result, calls = self.run_smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for call in calls:
            if call["tool"] == "devcontainer" or call["args"][0] == "compose":
                self.assertIsNone(call["env"]["COMPOSE_ENV_FILES"])
                self.assertIsNone(call["env"]["COMPOSE_FILE"])
                self.assertEqual(call["env"]["COMPOSE_DISABLE_ENV_FILE"], "1")

    def test_tracked_symlink_cannot_read_an_ignored_secret(self):
        # A tracked symlink must not make cp dereference an untracked secret.
        secret = self.work / "synthetic-private.env"
        secret.write_text("SYNTHETIC_SECRET=must-not-copy\n")
        (self.config / "nested/secret-link").symlink_to(secret)
        subprocess.run(["git", "-C", str(self.repo), "add", "src"], check=True)
        result, calls = self.run_smoke()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL unsafe tracked file", result.stderr)
        self.assertFalse(any(call["tool"] == "devcontainer" for call in calls))
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_each_invocation_uses_a_distinct_project(self):
        first, _ = self.run_smoke()
        second, calls = self.run_smoke()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        projects = [call["env"]["COMPOSE_PROJECT_NAME"] for call in calls if "snapshot" in call]
        self.assertEqual(len(projects), 2)
        self.assertEqual(len(set(projects)), 2)
        cleanups = [call["args"][call["args"].index("-p") + 1] for call in calls if call["tool"] == "docker" and "down" in call["args"]]
        self.assertEqual(cleanups, projects)

    def test_missing_cli_is_a_failure_not_a_skipped_gate(self):
        (self.bin / "devcontainer").unlink()
        for command in ("bash", "dirname"):
            (self.bin / command).symlink_to(shutil.which(command))
        self.env["PATH"] = str(self.bin)
        result, calls = self.run_smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL devcontainer is required", result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_unavailable_daemon_does_not_allocate_a_fixture_or_skip(self):
        result, calls = self.run_smoke("info-fail")
        self.assertEqual(result.returncode, 44)
        self.assertEqual([(call["tool"], call["args"]) for call in calls], [("docker", ["info"])])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_up_uses_only_tracked_fixture_synthetic_auth_and_real_feature_contract(self):
        result, calls = self.run_smoke(image='fixture:image-with-"quote')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_exact_cleanup(calls)
        up = next(call for call in calls if call["tool"] == "devcontainer" and call["args"][0] == "up")
        args, snapshot = up["args"], up["snapshot"]
        fixture = Path(args[args.index("--workspace-folder") + 1])
        project = up["env"]["COMPOSE_PROJECT_NAME"]
        self.assertRegex(project, r"^hermes-smoke-[a-f0-9]+$")
        self.assertEqual(fixture.name, project)
        self.assertTrue(fixture.is_relative_to(self.scratch))
        self.assertEqual(up["cwd"], str(fixture))
        self.assertEqual(up["env"]["HERMES_AUTOSTART_SERVICES"], "1")
        self.assertEqual(up["env"]["HERMES_AUTOSTART_DASHBOARD"], "0")
        self.assertEqual(snapshot["auth"], {"tokens": None})
        self.assertEqual(snapshot["auth_mode"], 0o666)
        self.assertTrue(Path(snapshot["auth_path"]).is_relative_to(fixture.parent))
        self.assertNotEqual(up["env"]["DEVBOX_HOST_HOME"], str(self.operator_home))
        self.assertNotIn(".devcontainer/.env", snapshot["files"])
        self.assertNotIn(".env", snapshot["files"])
        self.assertEqual(snapshot["tracked"], "tracked working-tree contents\n")
        self.assertEqual(snapshot["lock"], self.lock)
        expected = {**self.manifest, "dockerComposeFile": ["docker-compose.yml", "docker-compose.test.yml"]}
        self.assertEqual(snapshot["config"], expected)
        self.assertEqual(snapshot["override"], {"services": {"devcontainer": {"image": 'fixture:image-with-"quote'}}})
        self.assertTrue(snapshot["marker"].strip())
        self.assertIn("--frozen-lockfile", args)
        self.assertEqual(args[args.index("--update-remote-user-uid-default") + 1], "never")
        self.assertTrue(Path(args[args.index("--user-data-folder") + 1]).is_relative_to(fixture.parent))
        self.assertEqual(args[args.index("--id-label") + 1], f"hermes.smoke={project}")
        self.assertNotIn("--skip-post-create", args)
        self.assertNotIn("--no-lockfile", args)
        self.assertFalse(fixture.parent.exists(), "temporary fixture and CLI state must be removed")
        self.assertTrue((self.config / ".env").is_fifo())
        self.assertTrue((self.operator_home / ".codex/auth.json").is_fifo())


if __name__ == "__main__":
    unittest.main()
