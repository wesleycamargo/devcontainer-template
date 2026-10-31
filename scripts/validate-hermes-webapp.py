#!/usr/bin/env python3
"""Exercise the baked Webapp and optional remote login in a disposable container."""

import http.cookiejar
import json
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request


def validate(image):
    name = "hermes-webapp-test-" + secrets.token_hex(4)

    def docker(*args, input=None, check=True):
        return subprocess.run(
            ["docker", *args], input=input, text=True, capture_output=True,
            check=check, timeout=240,
        )

    def user(*args, input=None):
        return docker("exec", "-i", "-u", "hermes", name, *args, input=input).stdout.strip()

    def write_file(path, content):
        user("sh", "-c", 'umask 077; cat > "$1"', "sh", path, input=content)

    def settings():
        return json.loads(user("hermes", "config", "get", "webapp", "--json"))

    def wait_status(expected):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = docker("exec", "-u", "hermes", name,
                            "hermes", "webapp", "--status", check=False)
            if expected in result.stdout:
                return result.stdout
            time.sleep(2)
        raise AssertionError(f"Expected {expected!r}; got {result.stdout} {result.stderr}")

    # Ignore HTTP proxy variables for requests to this disposable localhost port.
    cookies = http.cookiejar.CookieJar()
    browser = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(cookies),
    )

    def request(path, data=None):
        # Docker may allocate a different host port when this container restarts.
        # Resolve it for every request, including the fail-closed checks.
        port = docker("port", name, "9120/tcp").stdout.strip().rsplit(":", 1)[1]
        url = "http://127.0.0.1:" + port
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url + path, data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            with browser.open(req, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    def wait_http(expected):
        # Internal status can become ready before the published socket is usable.
        # Retry transport failures only; unexpected auth responses fail immediately.
        deadline = time.monotonic() + 30
        last_error = None
        while time.monotonic() < deadline:
            try:
                status, _ = request("/api/sessions")
            except (urllib.error.URLError, ConnectionError, TimeoutError) as exc:
                last_error = exc
            else:
                assert status in expected, f"Expected HTTP {expected}, got {status}"
                return
            time.sleep(1)
        raise AssertionError(f"Webapp HTTP did not become reachable after restart: {last_error}")

    def login(password):
        return request("/auth/password-login", {
            "provider": "basic", "username": "webapp-test", "password": password,
        })[0]

    try:
        docker("run", "-d", "--init", "--name", name,
               "-e", "HERMES_AUTOSTART_SERVICES=1",
               "-p", "127.0.0.1::9120", image)
        # Wait until the image entrypoint has completed dependency preparation.
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if docker("exec", name, "pgrep", "-x", "sshd", check=False).returncode == 0:
                break
            time.sleep(2)
        else:
            raise AssertionError("entrypoint did not finish")

        # The unprivileged user cannot rebuild /opt. This must reuse the bundle.
        assert "up to date" in user("hermes", "webapp", "--build-only")
        print("PASS baked bundle is current and reusable by hermes", flush=True)

        write_file("/home/hermes/.hermes/config.yaml",
                   '# keep this comment\nterminal:\n  cwd: /home/hermes\n')
        user("hermes-start-services")
        wait_status("Serving at")
        initial = settings()
        assert initial["enabled"] is True and initial["host"] == "127.0.0.1" and initial["port"] == 9120
        before = user("cat", "/home/hermes/.hermes/config.yaml")
        assert "# keep this comment" in before and "cwd: /home/hermes" in before
        user("hermes-start-services")
        assert user("cat", "/home/hermes/.hermes/config.yaml") == before

        try:
            request("/")
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            pass
        else:
            raise AssertionError("default loopback Webapp reachable via Docker publication")
        print("PASS local defaults, config preservation, rerun and network isolation", flush=True)

        user("hermes", "config", "set", "webapp.host", "0.0.0.0")
        # No password or other provider: the remote Webapp must fail closed.
        write_file("/home/hermes/.hermes/.env", "")
        docker("restart", name)
        wait_status("Unavailable:")
        try:
            status, _ = request("/api/sessions")
            assert status in (401, 403, 503), status
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            pass
        print("PASS remote Webapp refuses access without credentials", flush=True)

        password = secrets.token_urlsafe(24)
        write_file("/home/hermes/.hermes/.env",
                   "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=webapp-test\n"
                   f"HERMES_DASHBOARD_BASIC_AUTH_PASSWORD={password}\n"
                   f"HERMES_DASHBOARD_BASIC_AUTH_SECRET={secrets.token_hex(32)}\n")
        docker("restart", name)
        wait_status("Serving at")
        assert settings()["host"] == "0.0.0.0"
        wait_http((401, 403))
        assert login("wrong-password") == 401
        assert login(password) == 200
        assert request("/api/sessions")[0] == 200
        assert request("/")[0] == 200
        docker("restart", name)
        wait_status("Serving at")
        wait_http((200,))
        print("PASS remote password login and browser session survive restart", flush=True)

        user("hermes", "config", "set", "webapp.enabled", "false")
        user("hermes", "config", "set", "webapp.port", "9130")
        docker("restart", name)
        wait_status("off")
        final = settings()
        assert final["enabled"] is False and final["host"] == "0.0.0.0" and final["port"] == 9130
        print("PASS explicit disable, host and custom port survive startup", flush=True)

        for invalid in ("webapp: broken\n", "webapp: [\n"):
            write_file("/home/hermes/.hermes/config.yaml", invalid)
            result = docker("exec", "-u", "hermes", name,
                            "hermes-start-services", check=False)
            assert result.returncode != 0
            assert user("cat", "/home/hermes/.hermes/config.yaml") == invalid.strip()
        print("PASS invalid configuration is not overwritten", flush=True)
    except Exception:
        # Gateway output is useful without printing the test credentials or config.
        logs = docker("exec", name, "tail", "-n", "60",
                      "/home/hermes/.hermes/logs/gateway.out", check=False)
        print(logs.stdout, file=sys.stderr)
        raise
    finally:
        docker("rm", "-f", "-v", name, check=False)


if __name__ == "__main__":
    validate(sys.argv[1] if len(sys.argv) > 1 else "hermes-devbox:test")
