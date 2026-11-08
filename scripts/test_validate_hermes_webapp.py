"""Replay Docker port changes and HTTP startup delay through the real validator."""

import contextlib
import importlib.util
import io
import itertools
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
import urllib.error


spec = importlib.util.spec_from_file_location(
    "webapp_validation", Path(__file__).with_name("validate-hermes-webapp.py"))
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class ReachedLogin(Exception):
    """The validator reached login after checking the protected HTTP endpoint."""


class RestartReplay:
    def __init__(self, *, change_port=False, refused_attempts=0, anonymous_status=401,
                 response_body=b"{}", starting_attempts=0):
        self.port = 32000
        self.change_port = change_port
        self.refused_attempts = refused_attempts
        self.anonymous_status = anonymous_status
        self.response_body = response_body
        self.starting_attempts = starting_attempts
        self.credentials = False
        self.config = ""
        self.webapp = {"enabled": True, "host": "127.0.0.1", "port": 9120}

    def docker(self, args, **kwargs):
        output = ""
        action = args[1]
        if action == "run":
            self.run_args = args
            self.name = args[args.index("--name") + 1]
        elif action == "port":
            output = f"127.0.0.1:{self.port}\n"
        elif action == "restart":
            self.port += int(self.change_port)
        elif action == "exec":
            command = args[args.index(self.name) + 1:]
            if command[0] == "sh":
                if command[-1].endswith("config.yaml"):
                    self.config = kwargs["input"]
                else:
                    self.credentials = "BASIC_AUTH_PASSWORD=" in kwargs["input"]
            elif command[0] == "cat":
                output = self.config
            elif command[:3] == ["hermes", "config", "get"]:
                output = json.dumps(self.webapp)
            elif command[:3] == ["hermes", "config", "set"]:
                self.webapp[command[3].split(".")[1]] = command[4]
            elif command == ["hermes", "webapp", "--build-only"]:
                output = "up to date"
            elif command == ["hermes", "webapp", "--status"]:
                output = ("Unavailable:" if self.webapp["host"] == "0.0.0.0"
                          and not self.credentials else "Serving at")
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    def open(self, request, **kwargs):
        if (not self.credentials
                or not request.full_url.startswith(f"http://127.0.0.1:{self.port}/")):
            raise urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))
        if self.refused_attempts:
            self.refused_attempts -= 1
            raise urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))
        if self.starting_attempts:
            self.starting_attempts -= 1
            raise urllib.error.HTTPError(
                request.full_url, 503, "Service Unavailable", {},
                io.BytesIO(b'{"error":"gateway_not_ready","state":"starting"}'))
        if request.full_url.endswith("/auth/password-login"):
            raise ReachedLogin()
        raise urllib.error.HTTPError(request.full_url, self.anonymous_status,
                                     "test response", {}, io.BytesIO(self.response_body))


class WebappRestartTests(unittest.TestCase):
    def replay(self, scenario):
        with (patch.object(validation.subprocess, "run", side_effect=scenario.docker),
              patch.object(validation.urllib.request, "build_opener", return_value=scenario),
              patch.object(validation.time, "sleep"),
              patch.object(validation.time, "monotonic", side_effect=itertools.count(step=5)),
              contextlib.redirect_stdout(io.StringIO()),
              contextlib.redirect_stderr(io.StringIO())):
            validation.validate("unused:test")

    def test_skills_bootstrap_is_disabled(self):
        scenario = RestartReplay()
        with self.assertRaises(ReachedLogin):
            self.replay(scenario)
        self.assertIn("HERMES_SKILLS_INSTALL=", scenario.run_args)
        self.assertIn("HERMES_SKILLS_TAPS=", scenario.run_args)

    def test_refreshes_port_after_restart(self):
        with self.assertRaises(ReachedLogin):
            self.replay(RestartReplay(change_port=True))

    def test_waits_for_http_after_internal_status_is_serving(self):
        with self.assertRaises(ReachedLogin):
            self.replay(RestartReplay(refused_attempts=2))

    def test_unprotected_endpoint_still_fails(self):
        with self.assertRaises(AssertionError):
            self.replay(RestartReplay(anonymous_status=200))

    def test_waits_for_gateway_starting_before_checking_auth(self):
        with self.assertRaises(ReachedLogin):
            self.replay(RestartReplay(starting_attempts=2))

    def test_gateway_stuck_starting_fails_after_timeout(self):
        with self.assertRaisesRegex(AssertionError, "after restart:.*gateway_not_ready.*starting"):
            self.replay(RestartReplay(starting_attempts=1000))

    def test_unreachable_endpoint_still_fails_after_timeout(self):
        with self.assertRaisesRegex(AssertionError, "HTTP did not become reachable"):
            self.replay(RestartReplay(refused_attempts=1000))

    def test_service_unavailable_reports_response_body(self):
        with self.assertRaisesRegex(AssertionError, 'got 503; response body:.*backend unavailable'):
            self.replay(RestartReplay(
                anonymous_status=503, response_body=b'{"detail":"backend unavailable"}'))

    def test_response_diagnostic_redacts_test_credentials(self):
        with patch.object(validation.secrets, "token_urlsafe", return_value="test-password"):
            with self.assertRaises(AssertionError) as failure:
                self.replay(RestartReplay(
                    anonymous_status=503, response_body=b'{"detail":"test-password"}'))
        self.assertNotIn("test-password", str(failure.exception))
        self.assertIn("<REDACTED>", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
