"""Hermes devbox lifecycle contracts, without a custom SSH server.

Shell fixtures redirect fixed data paths into disposable directories. They
exercise entrypoint policy without Docker, real user data, or credentials.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = (ROOT / "src/ai-hermes-devbox/.devcontainer", ROOT / ".devcontainer")
REMOVED_ARTIFACTS = (
    "SSH-BACKEND.md", "sshd-hermes-gateway.conf", "hermes-ssh-info.sh",
    "docker-compose.ssh.yml", "scripts/connect-hermes-desktop.ps1",
    "scripts/find-devcontainer.sh",
)

ENTRYPOINT_HARNESS = r"""
record() { local sep="" arg; for arg in "$@"; do printf '%s%s' "$sep" "$arg" >> "$CALLS"; sep=$'\t'; done; printf '\n' >> "$CALLS"; }
# Use the real install/file operations, ignoring only image-specific ownership.
install() {
  local args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
}
timeout() { record timeout "$@"; return "${RUNTIME_STATUS:-0}"; }
su() { record su "$@"; return "${SERVICE_STATUS:-0}"; }
exec() { record exec "$@"; exit 0; }
# These boundaries must never be invoked by the new entrypoint.
ssh-keygen() { record ssh-keygen "$@"; }
sshd() { record sshd "$@"; }
source "$1" "${@:2}"
"""


class NoSshEntrypointTests(unittest.TestCase):
    def run_entrypoint(self, directory, *, command=("sleep", "infinity"),
                       master=None, runtime_status=0, service_status=0, existing=False):
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
            script = (directory / "entrypoint.sh").read_text()
            # Keep shell policy unchanged; redirect every fixed writable path.
            for source, target in (
                ("/home/hermes", home), ("/opt/hermes", upstream),
                ("/tmp/hermes-runtime", fixture / "runtime"),
                ("/run/sshd", fixture / "sshd"),
                ("/run/hermes-ssh", fixture / "ssh-input"),
                ("/var/lib/hermes-ssh", fixture / "ssh-state"),
            ):
                script = script.replace(source, str(target))
            path = fixture / "entrypoint.sh"
            path.write_text(script)
            calls = fixture / "calls"
            env = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(home), "CALLS": str(calls),
                "RUNTIME_STATUS": str(runtime_status),
                "SERVICE_STATUS": str(service_status),
                # Dashboard opt-in must not bypass a disabled master switch.
                "HERMES_AUTOSTART_DASHBOARD": "1",
            }
            if master is not None:
                env["HERMES_AUTOSTART_SERVICES"] = master
            result = subprocess.run(
                ["bash", "-c", ENTRYPOINT_HARNESS, "entrypoint-test", str(path), *command],
                cwd=fixture, env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(marker.read_text(), "existing session\n")
            for legacy in ("hermes-agent", "node"):
                self.assertEqual((data / legacy / "keep.txt").read_text(), "legacy data\n")
            self.assertEqual((data / ".env").read_text(),
                             "PRESERVE=existing\n" if existing else "BOOTSTRAP=fixture\n")
            if not existing:
                self.assertEqual((data / ".env").stat().st_mode & 0o777, 0o600)
            else:
                self.assertEqual((data / "config.yaml").read_text(), "model: preserve\n")
            for name in ("cron", "sessions", "logs", "pairing", "hooks", "image_cache",
                         "audio_cache", "memories", "skills"):
                self.assertTrue((data / name).is_dir(), name)
            self.assertEqual((fixture / "runtime").stat().st_mode & 0o777, 0o700)
            recorded = [line.split("\t") for line in calls.read_text().splitlines()]
            for forbidden in ("sshd", "ssh-state", "ssh-input", "home/.ssh"):
                self.assertFalse((fixture / forbidden).exists(), forbidden)
            self.assertFalse(any(call[0] in ("sshd", "ssh-keygen") for call in recorded))
            return recorded, result.stdout

    def test_entrypoint_has_no_server_key_or_connection_setup(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                script = (directory / "entrypoint.sh").read_text()
                for forbidden in ("sshd", "ssh-keygen", "authorized_keys", "hermes-ssh",
                                  "HERMES_SSH", "/home/hermes/.ssh"):
                    self.assertNotIn(forbidden, script)

    def test_plain_docker_default_preserves_bootstrap_and_runs_sleep_as_hermes(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                calls, output = self.run_entrypoint(directory)
                self.assertEqual(calls[-1], ["exec", "runuser", "-u", "hermes", "--", "sleep", "infinity"])
                self.assertEqual(len(calls), 2)  # Runtime preflight, then exec.
                self.assertEqual(calls[0][:6], ["timeout", "30", "runuser", "-u", "hermes", "--"])
                self.assertEqual(calls[0][-1], "--version")
                self.assertIn("legacy Hermes data notice", output)

    def test_existing_data_is_not_replaced_during_restart(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                self.run_entrypoint(directory, existing=True)

    def test_compose_autostart_runs_starter_before_nonroot_keepalive(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                calls, _ = self.run_entrypoint(directory, master="1")
                self.assertEqual([call[0] for call in calls], ["timeout", "su", "exec"])
                self.assertEqual(calls[1][1:5], ["hermes", "-s", "/bin/bash", "-c"])
                self.assertIn("/usr/local/bin/hermes-start-services", calls[1][-1])
                self.assertEqual(calls[-1][1:5], ["runuser", "-u", "hermes", "--"])

    def test_only_exact_one_enables_master_autostart(self):
        for directory in CONFIGS:
            for master in (None, "", "0", "true", "2"):
                with self.subTest(directory=directory, master=master):
                    calls, _ = self.run_entrypoint(directory, master=master)
                    self.assertFalse(any(call[0] == "su" for call in calls))

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

    def test_root_hermes_wrapper_drops_privileges_before_using_data(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                wrapper = (directory / "hermes.sh").read_text()
                drop = 'exec /usr/sbin/runuser -u hermes -- /usr/local/bin/hermes "$@"'
                self.assertIn(drop, wrapper)
                self.assertLess(wrapper.index(drop), wrapper.index("export HERMES_HOME="))
                self.assertIn('HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"', wrapper)
                self.assertIn('exec /opt/hermes/.venv/bin/hermes "$@"', wrapper)


class NoSshConfigurationTests(unittest.TestCase):
    def test_ssh_server_and_desktop_integration_artifacts_are_absent(self):
        for directory in CONFIGS:
            for name in REMOVED_ARTIFACTS:
                with self.subTest(directory=directory, name=name):
                    self.assertFalse((directory / name).exists(), name)

    def test_compose_has_only_existing_user_data_volumes_and_no_ssh_settings(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                text = (directory / "docker-compose.yml").read_text()
                self.assertNotRegex(text.lower(), r"ssh|2222|authorized_keys")
                volumes = text.split("\nvolumes:\n", 1)[1]
                self.assertEqual(set(re.findall(r"(?m)^  ([\w-]+):\s*$", volumes)),
                                 {"claude-data", "codex-data", "hermes-data"})
                for retained in (
                    "init: true",
                    "claude-data:/home/hermes/.claude", "codex-data:/home/hermes/.codex",
                    "hermes-data:/home/hermes/.hermes",
                    "source: ${DEVBOX_HOST_HOME:-${HOME:-/home/vscode}}/.codex/auth.json",
                    "target: /home/hermes/.codex/auth.json", "create_host_path: false",
                    'HERMES_AUTOSTART_SERVICES: "${HERMES_AUTOSTART_SERVICES:-1}"',
                    'HERMES_AUTOSTART_DASHBOARD: "${HERMES_AUTOSTART_DASHBOARD:-0}"',
                    "image: ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest",
                ):
                    self.assertIn(retained, text)
                self.assertNotRegex(text, r"(?m)^\s+(command|ports|privileged):")
                self.assertNotIn("/var/run/docker.sock", text)

    def test_devcontainer_stops_compose_on_close_preserving_forwarding_and_features(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                text = (directory / "devcontainer.json").read_text()
                config = json.loads(re.sub(r"(?m)^\s*//.*$", "", text))
                self.assertEqual(config["shutdownAction"], "stopCompose")
                self.assertNotRegex(text.lower(), r"ssh|2222")
                self.assertEqual(config["forwardPorts"], [9119, 9120])
                self.assertEqual(config["remoteUser"], "hermes")
                self.assertEqual(config["workspaceFolder"], "/workspaces/${localWorkspaceFolderBasename}")
                self.assertEqual(config["mounts"], [
                    "source=${localWorkspaceFolder},target=/workspaces/${localWorkspaceFolderBasename},type=bind,consistency=cached",
                ])
                self.assertEqual(set(config["features"]), {
                    "ghcr.io/devcontainers/features/common-utils:2",
                    "ghcr.io/rchaganti/vsc-devcontainer-features/azurebicep:1",
                })
                self.assertEqual(config["portsAttributes"]["9120"]["onAutoForward"], "silent")
                settings = config["customizations"]["vscode"]["settings"]
                self.assertEqual(settings["terminal.integrated.defaultProfile.linux"], "pwsh")

    def test_env_example_only_exposes_host_home_and_service_startup(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                text = (directory / ".env.example").read_text()
                self.assertNotRegex(text.lower(), r"ssh|2222|authorized_keys")
                assignments = dict(re.findall(r"(?m)^([A-Z_]+)=(.*)$", text))
                self.assertEqual(assignments, {
                    "HERMES_AUTOSTART_SERVICES": "1", "HERMES_AUTOSTART_DASHBOARD": "0",
                })
                self.assertIn("DEVBOX_HOST_HOME", text)
                self.assertIn("recreate to apply", text)

    def test_tracked_root_mirror_matches_template_including_removed_files(self):
        paths = subprocess.check_output(
            ["git", "ls-files", "-z", "--", ".devcontainer/",
             "src/ai-hermes-devbox/.devcontainer/"], cwd=ROOT,
        ).decode().split("\0")
        relative_paths = set()
        for path in filter(None, paths):
            prefix = "src/ai-hermes-devbox/" if path.startswith("src/") else ""
            relative_paths.add(path.removeprefix(prefix).removeprefix(".devcontainer/"))
        self.assertTrue(relative_paths)
        for name in sorted(relative_paths):
            with self.subTest(name=name):
                source, mirror = (directory / name for directory in CONFIGS)
                if name in REMOVED_ARTIFACTS:
                    self.assertFalse(source.exists())
                    self.assertFalse(mirror.exists())
                else:
                    self.assertTrue(source.is_file(), str(source))
                    self.assertTrue(mirror.is_file(), str(mirror))
                    self.assertEqual(source.read_bytes(), mirror.read_bytes())


class NoSshImageTests(unittest.TestCase):
    def test_image_defaults_to_development_shell_without_custom_ssh_server(self):
        for directory in CONFIGS:
            with self.subTest(directory=directory):
                text = (directory / "Dockerfile").read_text()
                self.assertNotIn("openssh-server", text)
                self.assertNotIn("/run/sshd", text)
                self.assertNotIn("sshd-hermes-gateway.conf", text)
                self.assertNotIn("hermes-ssh-info", text)
                self.assertNotIn("/usr/sbin/sshd", text)
                self.assertRegex(text, r'(?m)^CMD \["sleep", "infinity"\]$')
                self.assertIn('ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]', text)
                # Retain development tooling, pinned runtime and bridge setup.
                for retained in (
                    "nousresearch/hermes-agent:main-desktop@sha256:",
                    "groupmod -g 1000 hermes", "usermod -u 1000 -g 1000",
                    "powershell", "ARG OH_MY_POSH_VERSION=", "ARG TERMINAL_ICONS_VERSION=",
                    "ARG GITHUB_CLI_VERSION=", "ARG CODEX_VERSION=", "ARG CLAUDE_VERSION=",
                    "COPY --chmod=755 hermes.sh /usr/local/bin/hermes",
                    "hermes webapp --build-only", "hermes-start-services",
                    "hermes-webapp-open", "/opt/hermes/.venv/bin/hermes-acp",
                    "/opt/hermes/.venv/bin/hermes-agent",
                ):
                    self.assertIn(retained, text)


if __name__ == "__main__":
    unittest.main()
