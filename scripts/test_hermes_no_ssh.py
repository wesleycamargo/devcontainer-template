"""Hermes devbox image/configuration contracts without a custom SSH server."""

import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = (ROOT / "src/ai-hermes-devbox/.devcontainer", ROOT / ".devcontainer")
REMOVED_ARTIFACTS = (
    "SSH-BACKEND.md", "sshd-hermes-gateway.conf", "hermes-ssh-info.sh",
    "docker-compose.ssh.yml", "scripts/connect-hermes-desktop.ps1",
    "scripts/find-devcontainer.sh",
)

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
        relative_paths.add("hermes_devbox.py")
        self.assertTrue(relative_paths)
        for name in sorted(relative_paths):
            with self.subTest(name=name):
                source, mirror = (directory / name for directory in CONFIGS)
                if name in (*REMOVED_ARTIFACTS, "entrypoint.sh", "hermes.sh",
                            "start-services.sh", "webapp-open.py", "scripts/configure-project-skills.sh"):
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
                for alias in ("hermes", "hermes-entrypoint", "hermes-start-services", "hermes-webapp-open"):
                    self.assertIn(f"ln -sf /usr/local/lib/hermes_devbox.py /usr/local/bin/{alias}", text)
                self.assertIn("/opt/hermes/.venv/bin/python -m py_compile /usr/local/lib/hermes_devbox.py", text)
                # Retain development tooling, pinned runtime and bridge setup.
                for retained in (
                    "nousresearch/hermes-agent:main-desktop@sha256:",
                    "groupmod -g 1000 hermes", "usermod -u 1000 -g 1000",
                    "powershell", "ARG OH_MY_POSH_VERSION=", "ARG TERMINAL_ICONS_VERSION=",
                    "ARG GITHUB_CLI_VERSION=", "ARG CODEX_VERSION=", "ARG CLAUDE_VERSION=",
                    "COPY --chmod=755 hermes_devbox.py /usr/local/lib/hermes_devbox.py",
                    "hermes webapp --build-only", "hermes-start-services",
                    "hermes-webapp-open", "/opt/hermes/.venv/bin/hermes-acp",
                    "/opt/hermes/.venv/bin/hermes-agent",
                ):
                    self.assertIn(retained, text)


if __name__ == "__main__":
    unittest.main()
