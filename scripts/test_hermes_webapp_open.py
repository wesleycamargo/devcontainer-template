"""Exercise the opener with local HTTP and per-window VS Code IPC servers."""

import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "webapp_open", Path(__file__).resolve().parents[1]
    / "src/ai-hermes-devbox/.devcontainer/webapp-open.py")
opener = importlib.util.module_from_spec(spec)
spec.loader.exec_module(opener)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        status, body = self.server.responses[0]
        if len(self.server.responses) > 1:
            self.server.responses.pop(0)
        self.send_response(status)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.messages.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(self.server.ipc_status)
        self.end_headers()
        self.wfile.write(b"null")


class WebappOpenTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.temp = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.http = self.serve(http.server.HTTPServer(("127.0.0.1", 0), Handler))
        self.http.paths = []
        self.http.responses = [(401, b'{}')]
        self.ticket = "a" * 43
        self.link = f"http://127.0.0.1:{self.http.server_port}/webapp/launch#ticket={self.ticket}"

    def serve(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.stack.callback(server.server_close)
        self.stack.callback(thread.join, 2)
        self.stack.callback(server.shutdown)
        return server

    def window(self, name):
        server = self.serve(socketserver.UnixStreamServer(str(self.temp / name), Handler))
        server.messages = []
        server.ipc_status = 200
        return server

    def run_opener(self, window, *, link=None, returncode=0):
        result = subprocess.CompletedProcess(
            ["hermes", "webapp", "--no-open"], returncode,
            stdout=f"Open this one-use link:\n  {link or self.link}\n", stderr="")
        output = io.StringIO()
        with (patch.dict(os.environ, {"VSCODE_IPC_HOOK_CLI": window.server_address}),
              patch.object(opener.subprocess, "run", return_value=result) as cli,
              patch.object(opener.time, "sleep"), contextlib.redirect_stdout(output)):
            opener.open_webapp()
        self.assertNotIn(self.ticket, output.getvalue())
        self.assertEqual(cli.call_args.args[0], ["hermes", "webapp", "--no-open"])

    def test_sends_complete_link_to_current_window_without_logging_ticket(self):
        window = self.window("vscode.sock")
        self.run_opener(window)
        self.assertEqual(window.messages, [{"type": "openExternal", "uris": [self.link]}])
        self.assertEqual(self.http.paths, ["/api/sessions"])

    def test_two_windows_use_separate_ipc_connections(self):
        first, second = self.window("first.sock"), self.window("second.sock")
        second_link = self.link.replace(self.ticket, "b" * 43)
        self.run_opener(first)
        self.run_opener(second, link=second_link)
        self.assertEqual(first.messages[0]["uris"], [self.link])
        self.assertEqual(second.messages[0]["uris"], [second_link])

    def test_waits_for_explicit_gateway_startup(self):
        self.http.responses.insert(0, (503, b'{"error":"gateway_not_ready","state":"starting"}'))
        window = self.window("vscode.sock")
        self.run_opener(window)
        self.assertEqual(len(self.http.paths), 2)
        self.assertEqual(len(window.messages), 1)

    def test_other_http_failure_does_not_open_browser(self):
        self.http.responses = [(503, b'{"error":"database unavailable"}')]
        window = self.window("vscode.sock")
        with self.assertRaisesRegex(RuntimeError, "HTTP 503"):
            self.run_opener(window)
        self.assertEqual(window.messages, [])

    def test_startup_timeout_does_not_open_browser(self):
        window = self.window("vscode.sock")
        with (patch.object(opener.time, "monotonic", side_effect=[0, 31]),
              self.assertRaisesRegex(RuntimeError, "still starting")):
            self.run_opener(window)
        self.assertEqual(window.messages, [])

    def test_failed_cli_does_not_disclose_its_output(self):
        with self.assertRaises(RuntimeError) as error:
            self.run_opener(self.window("vscode.sock"), returncode=1)
        self.assertNotIn(self.ticket, str(error.exception))

    def test_missing_link_does_not_open_browser(self):
        window = self.window("vscode.sock")
        with self.assertRaisesRegex(RuntimeError, "No local sign-in link"):
            self.run_opener(window, link="http://127.0.0.1:9120/")
        self.assertEqual(window.messages, [])

    def test_unprotected_api_does_not_open_browser(self):
        self.http.responses = [(200, b'{}')]
        window = self.window("vscode.sock")
        with self.assertRaisesRegex(RuntimeError, "HTTP 200"):
            self.run_opener(window)
        self.assertEqual(window.messages, [])

    def test_missing_vscode_session_does_not_launch_hermes(self):
        with (patch.dict(os.environ, {}, clear=True), patch.object(opener.subprocess, "run") as cli,
              self.assertRaisesRegex(RuntimeError, "VS Code terminal")):
            opener.open_webapp()
        cli.assert_not_called()

    def test_rejects_non_loopback_link(self):
        window = self.window("vscode.sock")
        with self.assertRaisesRegex(RuntimeError, "loopback"):
            self.run_opener(window, link=self.link.replace("127.0.0.1", "example.com"))
        self.assertEqual(window.messages, [])

    def test_ipc_error_does_not_report_success(self):
        window = self.window("vscode.sock")
        window.ipc_status = 500
        with self.assertRaisesRegex(RuntimeError, "could not open"):
            self.run_opener(window)


if __name__ == "__main__":
    unittest.main()
