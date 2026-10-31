#!/opt/hermes/.venv/bin/python
"""Open a private Webapp tab through this VS Code window's local forwarding."""

import http.client
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def open_webapp():
    ipc = os.environ.get("VSCODE_IPC_HOOK_CLI")
    if not ipc:
        raise RuntimeError("Run hermes-webapp-open in this devcontainer's VS Code terminal.")

    # Capture the one-use credential; never put it in output or process arguments.
    result = subprocess.run(
        ["hermes", "webapp", "--no-open"], capture_output=True, text=True, timeout=120,
    )
    if result.returncode:
        raise RuntimeError("Hermes could not open the Webapp. Check hermes webapp --status.")
    match = re.search(r"^\s*(http://\S+/webapp/launch#\S+)\s*$", result.stdout, re.MULTILINE)
    if not match:
        raise RuntimeError("No local sign-in link returned. Check hermes webapp --status.")
    link = match.group(1)
    url = urllib.parse.urlsplit(link)
    if url.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise RuntimeError("The VS Code opener requires a loopback Webapp address.")

    # A listening gateway may still answer gateway_not_ready during first boot.
    probe = urllib.parse.urlunsplit((url.scheme, url.netloc, "/api/sessions", "", ""))
    browser = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            with browser.open(probe, timeout=5) as response:
                status, body = response.status, response.read()
        except urllib.error.HTTPError as exc:
            status, body = exc.code, exc.read()
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            time.sleep(1)
            continue
        if status in (401, 403):
            break
        try:
            starting = status == 503 and json.loads(body) == {
                "error": "gateway_not_ready", "state": "starting",
            }
        except (ValueError, UnicodeError):
            starting = False
        if not starting:
            raise RuntimeError(f"Unexpected Webapp response (HTTP {status}). Check gateway.out.")
        time.sleep(1)
    else:
        raise RuntimeError("Webapp is still starting. Run hermes-webapp-open again in a moment.")

    # Same private IPC protocol as VS Code's remote `code --openExternal` CLI.
    # _remoteCLI.openExternal uses allowTunneling:true, selecting this window's
    # forwarded port while retaining the launch path and fragment. Sending over
    # the socket keeps the ticket out of argv even on hosts without peer checks.
    # https://github.com/microsoft/vscode/blob/main/src/vs/workbench/api/node/extHostCLIServer.ts
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(30)
        stream.connect(ipc)
        connection = http.client.HTTPConnection("localhost", timeout=30)
        connection.sock = stream
        try:
            connection.request("POST", "/", json.dumps({"type": "openExternal", "uris": [link]}),
                               {"Content-Type": "application/json"})
            response = connection.getresponse()
            response.read()
            if response.status != 200:
                raise RuntimeError("VS Code could not open the Webapp browser tab.")
        finally:
            connection.close()
    print("Sent Hermes Webapp to this VS Code window's browser opener.")


if __name__ == "__main__":
    try:
        open_webapp()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, http.client.HTTPException) as exc:
        # Subprocess output and IPC response bodies may contain the launch ticket.
        message = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print(f"hermes-webapp-open: {message}", file=sys.stderr)
        sys.exit(1)
