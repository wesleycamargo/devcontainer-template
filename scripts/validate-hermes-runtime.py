#!/usr/bin/env python3
"""Validate the Hermes image/Compose lifecycle using only owned test resources."""

import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = ROOT / "src/ai-hermes-devbox/.devcontainer"
GATEWAY = r"[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)"
DASHBOARD = r"[h]ermes dashboard([[:space:]]|$)|[h]ermes_cli[.]main.* dashboard([[:space:]]|$)"


class Runtime:
    """Own fixture credentials, workspace, containers and volumes for one check."""

    def __init__(self, image):
        self.image = image
        self.prefix = "hermes-runtime-" + secrets.token_hex(6)
        self.temp = tempfile.TemporaryDirectory(prefix=self.prefix + "-")
        self.work = Path(self.temp.name)
        self.containers = []
        self.projects = []
        self.volumes = []
        self.auth = self.work / "host-home/.codex/auth.json"
        self.auth.parent.mkdir(parents=True)
        self.auth.write_text('{"tokens": null}\n')
        self.auth.chmod(0o666)  # Synthetic fixture only; CI UID may differ.
        workspace = self.work / "workspaces/project"
        workspace.mkdir(parents=True)
        (workspace / "marker.txt").write_text("fixture workspace\n")
        self.empty_env = self.work / "empty.env"
        self.empty_env.write_text("")
        self.override = self.work / "compose.test.json"
        self.override.write_text(json.dumps({
            "services": {"devcontainer": {
                "image": image,
                "volumes": [{"type": "bind", "source": str(workspace.parent),
                             "target": "/workspaces"}],
            }},
        }))
        self.env = {
            **os.environ,
            "DEVBOX_HOST_HOME": str(self.work / "host-home"),
            "HERMES_AUTOSTART_SERVICES": "1",
            "HERMES_AUTOSTART_DASHBOARD": "0",
        }

        for key in (
            "HERMES_MODEL_PROVIDER", "HERMES_DEFAULT_MODEL", "HERMES_MODEL_BASE_URL",
            "HERMES_TERMINAL_CWD", "HERMES_TERMINAL_BACKEND", "HERMES_TERMINAL_TIMEOUT",
            "HERMES_WEBAPP_ENABLED", "HERMES_WEBAPP_HOST", "HERMES_WEBAPP_PORT",
        ):
            self.env.pop(key, None)

    def __enter__(self):
        def terminate(number, frame):
            raise SystemExit(128 + number)

        self.previous_handlers = {
            number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)
        }
        for number in self.previous_handlers:
            signal.signal(number, terminate)
        return self

    def __exit__(self, exc_type, exc, traceback):
        # Once cleanup starts, repeated cancellation must not skip owned resources.
        for number in self.previous_handlers:
            signal.signal(number, signal.SIG_IGN)
        failures = []

        def cleanup(resource, operation, expect_empty=False):
            try:
                result = operation()
                if result.returncode or (expect_empty and result.stdout.strip()):
                    failures.append(resource)
            except (subprocess.SubprocessError, OSError) as error:
                failures.append(f"{resource} ({type(error).__name__}: {error})")

        try:
            for project in self.projects:
                cleanup(project, lambda: self.compose_command(
                    project, "down", "-v", "--remove-orphans", check=False))
                for command in (("ps", "-aq"), ("volume", "ls", "-q")):
                    cleanup(project, lambda: self.docker(
                        *command, "--filter", f"label=com.docker.compose.project={project}",
                        check=False), expect_empty=True)
            for name in self.containers:
                cleanup(name, lambda: self.docker("rm", "-f", "-v", name, check=False))
            for volume in self.volumes:
                cleanup(volume, lambda: self.docker("volume", "rm", volume, check=False))
            cleanup(self.prefix, lambda: self.docker(
                "ps", "-aq", "--filter", f"label=hermes.validation={self.prefix}",
                check=False), expect_empty=True)
        finally:
            try:
                self.temp.cleanup()
            finally:
                for number, handler in self.previous_handlers.items():
                    signal.signal(number, handler)
        if failures:
            raise RuntimeError("Test resource cleanup failed: " + ", ".join(failures)) from exc

    def docker(self, *args, input=None, check=True):
        return subprocess.run(
            ["docker", *args], input=input, text=True, capture_output=True,
            check=check, timeout=300, env=self.env,
        )

    def container(self, suffix, *flags):
        name = self.prefix + "-" + suffix
        self.containers.append(name)  # Also clean up a partially successful run.
        self.docker("run", "-d", "--init", "--name", name,
                    "--label", f"hermes.validation={self.prefix}", *flags, self.image)
        return name

    def compose_command(self, project, *args, check=True):
        return self.docker(
            "compose", "--env-file", str(self.empty_env), "-p", project,
            "-f", str(CONTEXT / "docker-compose.yml"), "-f", str(self.override),
            *args, check=check,
        )

    def compose(self, suffix, *args):
        project = self.prefix + "-" + suffix
        if project not in self.projects:
            self.projects.append(project)
        return self.compose_command(project, *args)

    def compose_id(self, suffix):
        name = self.compose(suffix, "ps", "-q", "devcontainer").stdout.strip()
        if not name:
            raise AssertionError("Compose did not return a container")
        return name

    def user(self, name, *args, input=None, check=True):
        return self.docker("exec", "-i", "-u", "hermes", name, *args,
                           input=input, check=check)

    def wait(self, predicate, label, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(2)
        raise AssertionError("Timed out waiting for " + label)

    def idle(self, name):
        self.wait(lambda: self.docker("exec", name, "pgrep", "-x", "sleep",
                                      check=False).returncode == 0, "development shell")

    def webapp(self, name):
        self.wait(lambda: "Serving at http://127.0.0.1:9120" in self.user(
            name, "hermes", "webapp", "--status", check=False).stdout, "local Webapp")

    def count(self, name, pattern):
        result = self.user(name, "pgrep", "-fc", pattern, check=False)
        if result.returncode not in (0, 1):
            raise AssertionError("Could not inspect service processes")
        return int(result.stdout.strip())

    def isolated(self, name):
        assert self.docker("exec", name, "pgrep", "-x", "sshd", check=False).returncode == 1
        assert not self.docker("port", name).stdout.strip(), "Unexpected published port"
        mounts = json.loads(self.docker("inspect", "-f", "{{json .Mounts}}", name).stdout)
        assert not any("hermes-ssh" in mount["Destination"] for mount in mounts)

    def tools(self, name):
        self.user(name, "bash", "-euc", '''
            test "$(id -u)" = 1000
            test "$HOME" = /home/hermes
            test -f /opt/hermes/pyproject.toml
            test ! -w /opt/hermes
            test -x /opt/hermes/.venv/bin/python
            test -f /opt/hermes/apps/desktop/dist-webapp/index.html
            test ! -e ~/.hermes/hermes-agent
            env -i /usr/local/bin/hermes --version
            claude --version
            codex --version
            gh --version
            node --version
            sudo -n true
            pwsh -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = "Stop"; Import-Module Terminal-Icons; $mutex = [System.Threading.Mutex]::new($false, "HermesSmoke"); $mutex.Dispose()'
        ''')


def check_a(runtime):
    for suffix, flags in (("bare", ()), ("disabled", (
            "-e", "HERMES_AUTOSTART_SERVICES=0", "-e", "HERMES_AUTOSTART_DASHBOARD=1"))):
        name = runtime.container(suffix, *flags)
        runtime.idle(name)
        runtime.isolated(name)
        assert runtime.count(name, GATEWAY) == runtime.count(name, DASHBOARD) == 0
        runtime.tools(name)
    print("PASS A: shell-only image, tools, UID/home and no SSH listener", flush=True)


def check_b(runtime):
    runtime.env.update(HERMES_MODEL_PROVIDER="custom", HERMES_DEFAULT_MODEL="fixture-model",
                       HERMES_MODEL_BASE_URL="http://127.0.0.1:8000/v1",
                       HERMES_TERMINAL_TIMEOUT="240")

    runtime.compose("default", "up", "-d")
    name = runtime.compose_id("default")
    runtime.idle(name)
    runtime.webapp(name)
    for key, expected in (("model.provider", "custom"), ("model.default", "fixture-model"),
                          ("model.base_url", "http://127.0.0.1:8000/v1"), ("terminal.timeout", "240")):
        actual = runtime.user(name, "hermes", "config", "get", key).stdout.strip()
        assert actual == expected, (key, actual)
    runtime.user(name, "hermes", "config", "set", "model.default", "operator-choice")
    runtime.user(name, "hermes-start-services")
    assert runtime.user(name, "hermes", "config", "get", "model.default").stdout.strip() == "operator-choice"
    runtime.isolated(name)
    assert runtime.count(name, DASHBOARD) == 0
    count = runtime.count(name, GATEWAY)
    assert count > 0
    runtime.user(name, "hermes-start-services")
    assert 0 < runtime.count(name, GATEWAY) <= count
    runtime.user(name, "env", "HERMES_AUTOSTART_DASHBOARD=1", "hermes-start-services")
    runtime.wait(lambda: runtime.user(name, "python3", "-c",
        'import socket; socket.create_connection(("127.0.0.1", 9119), 2).close()',
        check=False).returncode == 0, "optional dashboard")
    count = runtime.count(name, DASHBOARD)
    assert count > 0
    runtime.user(name, "env", "HERMES_AUTOSTART_DASHBOARD=1", "hermes-start-services")
    assert 0 < runtime.count(name, DASHBOARD) <= count
    runtime.user(name, "hermes-start-services")
    assert runtime.count(name, DASHBOARD) > 0, "Opt-out must not kill a running dashboard"
    print("PASS B: default Webapp, optional dashboard and singleton startup", flush=True)


def check_c(runtime):
    names = []
    for suffix in ("one", "two"):
        runtime.compose(suffix, "up", "-d")
        name = runtime.compose_id(suffix)
        runtime.idle(name)
        runtime.webapp(name)
        runtime.isolated(name)
        names.append(name)
    volumes = []
    for name in names:
        mounts = json.loads(runtime.docker("inspect", "-f", "{{json .Mounts}}", name).stdout)
        volumes.append(next(m["Name"] for m in mounts if m["Destination"] == "/home/hermes/.hermes"))
    assert volumes[0] != volumes[1], "Projects must not share Hermes state"
    runtime.user(names[0], "python3", "-c", r'''
import json
from pathlib import Path
path = Path.home() / ".codex/auth.json"
assert json.loads(path.read_text()) == {"tokens": None}
path.write_text(json.dumps({"tokens": None, "fixture": "shared"}) + "\n")
''')
    assert json.loads(runtime.auth.read_text())["fixture"] == "shared"
    runtime.user(names[1], "python3", "-c", '''
import json
from pathlib import Path
assert json.loads((Path.home() / ".codex/auth.json").read_text())["fixture"] == "shared"
''')
    print("PASS C: parallel projects, separate state and synthetic host credential sharing", flush=True)


def check_e(runtime):
    volume = runtime.prefix + "-legacy"
    runtime.volumes.append(volume)
    runtime.docker("volume", "create", volume)
    seed = runtime.prefix + "-legacy-seed"
    runtime.containers.append(seed)  # A timed-out client may leave the seed running.
    runtime.docker("run", "--name", seed, "--label", f"hermes.validation={runtime.prefix}",
                   "--entrypoint", "/bin/bash", "-v", volume + ":/d",
                   runtime.image, "-euc", '''
mkdir -p /d/hermes-agent /d/node /d/sessions /d/memories /d/skills
printf old > /d/hermes-agent/MARKER
printf 'model: old\\n' > /d/config.yaml
printf 'TOKEN=fixture\\n' > /d/.env
for path in sessions/s1 memories/m1 skills/s1; do printf preserved > "/d/$path"; done
chown -R 1000:1000 /d
''')
    name = runtime.container("legacy", "-v", volume + ":/home/hermes/.hermes")
    runtime.idle(name)
    runtime.user(name, "bash", "-euc", '''
test "$(command -v hermes)" = /usr/local/bin/hermes
hermes --version
test "$(cat ~/.hermes/.env)" = TOKEN=fixture
for path in config.yaml sessions/s1 memories/m1 skills/s1 hermes-agent/MARKER; do
  test -s "$HOME/.hermes/$path"
done
''')
    assert "leftover from an older image" in runtime.docker("logs", name).stdout
    print("PASS E: existing state and unused legacy runtime preserved", flush=True)


def validate(image, checkpoint):
    checks = {"A": check_a, "B": check_b, "C": check_c, "E": check_e}
    with Runtime(image) as runtime:
        checks[checkpoint](runtime)


if __name__ == "__main__":
    validate(sys.argv[1], sys.argv[2])
