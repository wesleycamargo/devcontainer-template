"""Check service detection against real processes with upstream launcher argv."""

import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    ROOT / "src/ai-hermes-devbox/.devcontainer/start-services.sh",
    ROOT / ".devcontainer/start-services.sh",
    ROOT / "scripts/validate-hermes-gateway.sh",
)
OFFICIAL = (
    "/opt/hermes/.venv/bin/python -P -c import os, site, sys; "
    "sys.argv[0]='hermes'; site.addsitedir(os.environ['HERMES_SITE']); "
    "from hermes_cli.main import main; sys.exit(main()) "
)


class ServiceProcessTests(unittest.TestCase):
    def test_detects_official_and_legacy_service_processes(self):
        # A real sleep process with the launcher's argv[0] exercises pgrep -f,
        # without starting a gateway or touching the operator's Hermes data.
        for source in SOURCES:
            patterns = re.findall(r'pgrep -f(?:c)? "([^"]+)"', source.read_text())
            self.assertTrue(patterns, source)
            for pattern in patterns:
                service = "dashboard" if "dashboard" in pattern else "gateway"
                for prefix in (OFFICIAL, "/usr/local/bin/hermes "):
                    with self.subTest(source=source, pattern=pattern, prefix=prefix):
                        process = subprocess.Popen(
                            [prefix + service, "30"], executable="/bin/sleep")
                        try:
                            result = subprocess.run(
                                ["pgrep", "-f", pattern], capture_output=True, text=True)
                            self.assertIn(str(process.pid), result.stdout.splitlines())
                            other = "gateway" if service == "dashboard" else "dashboard"
                            unrelated = subprocess.Popen(
                                [prefix + other, "30"], executable="/bin/sleep")
                            try:
                                result = subprocess.run(
                                    ["pgrep", "-f", pattern], capture_output=True, text=True)
                                self.assertNotIn(str(unrelated.pid), result.stdout.splitlines())
                                self.assertNotIn(str(os.getpid()), result.stdout.splitlines())
                            finally:
                                unrelated.terminate()
                                unrelated.wait()
                        finally:
                            process.terminate()
                            process.wait()


if __name__ == "__main__":
    unittest.main()
