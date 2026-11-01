"""Check the published-image platform gate, including attestation descriptors."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-hermes-image-platforms.py"


class HermesImagePlatformTests(unittest.TestCase):
    def validate(self, manifest):
        self.assertTrue(VALIDATOR.is_file(), "published manifest validator is missing")
        return subprocess.run(
            [sys.executable, str(VALIDATOR)],
            input=json.dumps(manifest), text=True, capture_output=True, timeout=10,
        )

    def test_requires_both_runtime_platforms_not_attestations(self):
        manifests = [
            {"platform": {"os": "linux", "architecture": "amd64"}},
            {"platform": {"os": "unknown", "architecture": "unknown"}},
        ]
        result = self.validate({"manifests": manifests})
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing platforms: linux/arm64", result.stderr)

        manifests.append({"platform": {"os": "linux", "architecture": "arm64"}})
        result = self.validate({"manifests": manifests})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linux/amd64, linux/arm64", result.stdout)


if __name__ == "__main__":
    unittest.main()
