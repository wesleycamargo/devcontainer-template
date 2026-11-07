"""Guard publication decisions and the single Hermes validation workflow."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/publish-ai-hermes-devbox.yml"


class HermesPublishDecisionTests(unittest.TestCase):
    def module(self):
        path = ROOT / "scripts/hermes-ci-publish.py"
        self.assertTrue(path.is_file(), "publication decision helper is missing")
        spec = importlib.util.spec_from_file_location("hermes_ci_publish", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_pull_request_never_publishes(self):
        module = self.module()
        with patch.object(module.subprocess, "check_output") as git:
            self.assertFalse(module.should_publish("pull_request", {}))
        git.assert_not_called()

    def test_dispatch_explicitly_publishes(self):
        self.assertTrue(self.module().should_publish("workflow_dispatch", {}))

    def test_source_change_in_whole_push_publishes(self):
        module = self.module()
        event = {"before": "a" * 40, "after": "b" * 40}
        paths = b"src/ai-hermes-devbox/README.md\0"
        with patch.object(module.subprocess, "check_output", return_value=paths) as git:
            self.assertTrue(module.should_publish("push", event))
        git.assert_called_once_with([
            "git", "diff", "--name-only", "-z", "a" * 40, "b" * 40,
            "--", "src/ai-hermes-devbox/",
        ])

    def test_non_template_change_does_not_publish(self):
        module = self.module()
        with patch.object(module.subprocess, "check_output", return_value=b""):
            self.assertFalse(module.should_publish("push", {
                "before": "a" * 40, "after": "b" * 40,
            }))

    def test_first_push_uses_tree_instead_of_zero_commit(self):
        module = self.module()
        with patch.object(module.subprocess, "check_output", return_value=b"src/ai-hermes-devbox/README.md\0") as git:
            self.assertTrue(module.should_publish("push", {
                "before": "0" * 40, "after": "b" * 40,
            }))
        git.assert_called_once_with([
            "git", "ls-tree", "-r", "--name-only", "-z", "b" * 40,
            "--", "src/ai-hermes-devbox/",
        ])

    def test_bad_commit_identifier_fails_closed(self):
        module = self.module()
        with self.assertRaises(ValueError):
            module.should_publish("push", {"before": "not-a-sha", "after": "b" * 40})

    def test_unavailable_commit_is_not_reported_as_a_safe_diff(self):
        module = self.module()
        with patch.object(module.subprocess, "check_output", side_effect=subprocess.CalledProcessError(128, "git")):
            with self.assertRaises(subprocess.CalledProcessError):
                module.should_publish("push", {"before": "a" * 40, "after": "b" * 40})

    def test_deleted_branch_does_not_publish(self):
        self.assertFalse(self.module().should_publish("push", {"deleted": True}))


class HermesRealGitDecisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "--quiet")
        self.module = HermesPublishDecisionTests.module(self)

    def git(self, *args):
        return subprocess.check_output([
            "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args,
        ], cwd=self.repo, text=True).strip()

    def commit_file(self, relative, contents):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        self.git("add", "--", relative)
        self.git("commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def decision(self, before, after):
        real_check_output = subprocess.check_output
        with patch.object(self.module.subprocess, "check_output", side_effect=lambda args:
                          real_check_output(args, cwd=self.repo)):
            return self.module.should_publish("push", {"before": before, "after": after})

    def test_template_change_before_last_commit_in_push_is_detected(self):
        before = self.commit_file("README.md", "base")
        self.commit_file("src/ai-hermes-devbox/README.md", "template")
        after = self.commit_file("scripts/example.py", "print('fixture')")
        self.assertTrue(self.decision(before, after))

    def test_scripts_only_push_does_not_publish(self):
        before = self.commit_file("src/ai-hermes-devbox/README.md", "template")
        after = self.commit_file("scripts/example.py", "print('fixture')")
        self.assertFalse(self.decision(before, after))

    def test_initial_push_reads_real_tree(self):
        after = self.commit_file("src/ai-hermes-devbox/README.md", "template")
        self.assertTrue(self.decision("0" * 40, after))


class HermesWorkflowTests(unittest.TestCase):
    def test_preflight_compiles_the_consolidated_runtime(self):
        text = WORKFLOW.read_text()
        preflight = text.split("  validate:\n", 1)[0]
        self.assertIn(
            "python3 -m py_compile src/ai-hermes-devbox/.devcontainer/hermes_devbox.py",
            preflight,
        )
        for obsolete in ("entrypoint.sh", "start-services.sh", "hermes.sh", "webapp-open.py"):
            self.assertNotIn(obsolete, preflight)

    def test_only_publish_workflow_owns_hermes_triggers(self):
        self.assertFalse((ROOT / ".github/workflows/validate-hermes-gateway.yml").exists())
        text = WORKFLOW.read_text()
        self.assertIn("pull_request:", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertEqual(text.count("run: bash scripts/validate-hermes-runtime.sh all"), 1)
        self.assertNotIn("name: Validate Hermes SSH gateway", text)

    def test_preflight_blocks_validation_and_publication(self):
        text = WORKFLOW.read_text()
        self.assertIn("  preflight:\n", text)
        self.assertIn("    needs: preflight\n", text)
        self.assertIn("    needs: [preflight, validate]\n", text)
        self.assertIn("needs.preflight.outputs.publish == 'true'", text)
        self.assertIn("github.event_name != 'pull_request'", text)
        self.assertIn("fetch-depth: 0", text)
        self.assertIn("npm install --global @devcontainers/cli@0.90.0", text)

    def test_runtime_features_can_extend_the_daemon_local_validation_image(self):
        text = WORKFLOW.read_text()
        step = text.split(
            "      - name: Run runtime checkpoints A through E and Webapp checkpoint G\n", 1
        )[1].split("\n\n", 1)[0]
        self.assertIn("        env:\n          BUILDX_BUILDER: default\n", step)
        self.assertIn("run: bash scripts/validate-hermes-runtime.sh all", step)
        self.assertIn("cache-to: type=gha,mode=max,scope=ai-hermes-devbox", text)

    def test_published_image_supports_apple_silicon_and_x86_64(self):
        text = WORKFLOW.read_text()
        deploy = text.split("  deploy:\n", 1)[1]
        self.assertIn("uses: docker/setup-qemu-action@v3", deploy)
        step = text.split("      - name: Build and push image\n", 1)[1]
        self.assertIn("platforms: linux/amd64,linux/arm64", step)

    def test_publication_checks_the_actual_pushed_index(self):
        text = WORKFLOW.read_text()
        step = text.split("      - name: Build and push image\n", 1)[1]
        self.assertIn("id: image", step)
        self.assertIn("${{ steps.image.outputs.digest }}", step)
        self.assertIn('docker buildx imagetools inspect --raw "$IMAGE@$DIGEST"', step)
        self.assertIn("python3 scripts/validate-hermes-image-platforms.py", step)

    def test_unit_tests_are_not_deferred_to_checkpoint_g(self):
        path = ROOT / "scripts/validate-hermes-runtime.sh"
        self.assertTrue(path.is_file(), "runtime validator is missing")
        text = path.read_text()
        block = text.split("do_G() {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("unittest discover", block)
        self.assertIn("validate-hermes-webapp.py", block)

    def test_checkpoint_d_calls_real_disposable_smoke(self):
        path = ROOT / "scripts/validate-hermes-runtime.sh"
        self.assertTrue(path.is_file(), "runtime validator is missing")
        text = path.read_text()
        block = text.split("do_D() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('bash "$REPO_ROOT/scripts/validate-hermes-devcontainer.sh" "$IMAGE"', block)
        self.assertNotIn('skip "full', block)


if __name__ == "__main__":
    unittest.main()
