"""Static contracts for the Hermes template and its tracked root mirror."""

import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ai-hermes-devbox/.devcontainer"
CONFIG_DIRS = (ROOT / ".devcontainer", SOURCE)
EXPECTED_DEVCONTAINER_FILES = {
    ".env.example",
    ".gitignore",
    "Dockerfile",
    "devcontainer-lock.json",
    "devcontainer.json",
    "docker-compose.yml",
    "hermes_devbox.py",
}


def read_jsonc(path):
    # The checked-in manifests use whole-line // comments only.
    return json.loads(re.sub(r"(?m)^\s*//.*$", "", path.read_text()))


class HermesTemplateConfigTests(unittest.TestCase):
    def test_devcontainer_payloads_contain_exactly_seven_files(self):
        for directory in CONFIG_DIRS:
            with self.subTest(directory=str(directory.relative_to(ROOT))):
                actual = {
                    path.relative_to(directory).as_posix()
                    for path in directory.rglob("*") if path.is_file()
                }
                self.assertEqual(actual, EXPECTED_DEVCONTAINER_FILES)

    def test_published_template_contains_only_consumer_payload(self):
        directory = SOURCE.parent
        actual = {
            path.relative_to(directory).as_posix()
            for path in directory.rglob("*") if path.is_file()
        }
        expected = {"README.md", "devcontainer-template.json"} | {
            f".devcontainer/{name}" for name in EXPECTED_DEVCONTAINER_FILES
        }
        self.assertEqual(actual, expected)

    def test_bundled_skills_and_unused_hooks_are_absent(self):
        self.assertFalse((SOURCE.parent / ".agents").exists())
        for directory in CONFIG_DIRS:
            with self.subTest(directory=str(directory.relative_to(ROOT))):
                self.assertFalse(
                    (directory / "scripts/configure-project-skills.sh").exists(),
                )

    def test_skill_sync_targets_only_remaining_bundled_templates(self):
        script = (ROOT / "scripts/sync-template-agents.sh").read_text()
        self.assertIn("templates=(ai-devbox ai-esp32-devbox)", script)
        self.assertNotIn("ai-hermes-devbox", script)
        self.assertNotIn("configure-project-skills", script)

    def test_github_cli_is_only_installed_by_image(self):
        for directory in CONFIG_DIRS:
            with self.subTest(directory=str(directory.relative_to(ROOT))):
                config = read_jsonc(directory / "devcontainer.json")
                self.assertNotIn(
                    "ghcr.io/devcontainers/features/github-cli:1", config["features"],
                )
        dockerfile = (SOURCE / "Dockerfile").read_text()
        self.assertRegex(dockerfile, r"(?m)^ARG GITHUB_CLI_VERSION=\S+$")
        self.assertIn("gh_${GITHUB_CLI_VERSION}_linux_", dockerfile)

    def test_azure_and_pester_modules_are_pinned_and_imported_by_the_image(self):
        dockerfile = (SOURCE / "Dockerfile").read_text()
        self.assertIn("ARG AZ_ACCOUNTS_VERSION=4.0.2", dockerfile)
        self.assertIn("ARG PESTER_VERSION=5.2.2", dockerfile)
        self.assertIn(
            "Install-Module -Name Az.Accounts -RequiredVersion $env:AZ_ACCOUNTS_VERSION -Force -Scope AllUsers",
            dockerfile,
        )
        self.assertIn(
            "Install-Module -Name Pester -RequiredVersion $env:PESTER_VERSION -Force -Scope AllUsers",
            dockerfile,
        )
        self.assertIn("Import-Module Az.Accounts", dockerfile)
        self.assertIn("Import-Module Pester", dockerfile)

    def test_feature_lock_matches_manifest(self):
        expected_pins = {
            "ghcr.io/devcontainers/features/common-utils:2": (
                "2.5.7",
                "sha256:dbf431d6b42d55cde50fa1df75c7f7c3999a90cde6d73f7a7071174b3c3d0cc4",
            ),
            "ghcr.io/rchaganti/vsc-devcontainer-features/azurebicep:1": (
                "1.0.5",
                "sha256:2032cc9b359b599c177392144e1d0f10b9513f8d2859f88c2a95da6e69e02683",
            ),
        }
        for directory in CONFIG_DIRS:
            with self.subTest(directory=str(directory.relative_to(ROOT))):
                config = read_jsonc(directory / "devcontainer.json")
                lock = json.loads((directory / "devcontainer-lock.json").read_text())
                self.assertEqual(set(config["features"]), set(lock["features"]))
                self.assertEqual(set(config["features"]), set(expected_pins))
                for feature, (version, digest) in expected_pins.items():
                    with self.subTest(feature=feature):
                        self.assertEqual(lock["features"][feature], {
                            "version": version,
                            "resolved": f"{feature.rsplit(':', 1)[0]}@{digest}",
                            "integrity": digest,
                        })

    def test_root_mirror_matches_tracked_files(self):
        paths = subprocess.check_output(
            ["git", "ls-files", "-z", ".devcontainer/"], cwd=ROOT,
        ).decode().split("\0")
        self.assertTrue(any(paths))
        expected_paths = {f".devcontainer/{name}" for name in EXPECTED_DEVCONTAINER_FILES}
        for relative in sorted(set(filter(None, paths)) | expected_paths):
            with self.subTest(path=relative):
                source = ROOT / relative
                mirror = ROOT / "src/ai-hermes-devbox" / relative
                # Unstaged removals are still listed by git; both sides must agree.
                self.assertEqual(source.exists(), mirror.exists())
                if not source.exists():
                    continue
                self.assertTrue(mirror.is_file(), str(mirror))
                self.assertEqual(source.read_bytes(), mirror.read_bytes())


if __name__ == "__main__":
    unittest.main()
