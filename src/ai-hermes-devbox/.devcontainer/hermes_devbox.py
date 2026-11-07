#!/opt/hermes/.venv/bin/python
"""Image-owned devbox lifecycle and private VS Code Webapp opener.

Only the integration snippets execute with Hermes dependencies; this module and
all lifecycle/privilege/process boundaries use the Python standard library.
"""

import http.client
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


from pathlib import Path
import pwd
import shutil

HOME = Path("/home/hermes")
RUNTIME = Path("/opt/hermes")
PYTHON = "/opt/hermes/.venv/bin/python"
RUNTIME_TMP = Path("/tmp/hermes-runtime")
WORKSPACES = Path("/workspaces")
GATEWAY = r"[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)"
DASHBOARD = r"[h]ermes dashboard([[:space:]]|$)|[h]ermes_cli[.]main.* dashboard([[:space:]]|$)"
GITHUB_REPOSITORY = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*")
SKILL_IDENTIFIER = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*(?:/[A-Za-z0-9][A-Za-z0-9_.-]*)+"
)

# Maintainer defaults: edit here, then mirror this helper to root .devcontainer/.
DEFAULT_CODEX_MODEL = "gpt-6.1-sol"
DEFAULT_REASONING_EFFORT = "medium"

CODEX_SEED = (
    f"DEFAULT_MODEL = {DEFAULT_CODEX_MODEL!r}\n"
    f"DEFAULT_EFFORT = {DEFAULT_REASONING_EFFORT!r}\n"
    + """import sys
try:
    from hermes_cli.auth import (
        _auth_store_lock, _load_auth_store, _load_provider_state,
        _import_codex_cli_tokens, _save_codex_tokens, _update_config_for_provider)
    from hermes_cli.auth_codex import _codex_base_url
    from hermes_cli.config import get_config_path, require_readable_config_before_write, set_config_value
except Exception as exc:
    print("import error:", exc); sys.exit(3)
config = require_readable_config_before_write(get_config_path())
model = config.get("model", {})
if not isinstance(model, dict) or model.get("provider") not in (None, "", "openai-codex"):
    print("existing model provider preserved")
    sys.exit(0)
with _auth_store_lock():
    state = _load_provider_state(_load_auth_store(), "openai-codex") or {}
    tokens = state.get("tokens") or {}
    if not (tokens.get("access_token") and tokens.get("refresh_token")):
        tokens = _import_codex_cli_tokens()
        if not tokens:
            print("no usable Codex CLI login; authenticate with Codex CLI on the host")
            sys.exit(2)
        _save_codex_tokens(tokens)
_update_config_for_provider("openai-codex", _codex_base_url())
if not model.get("default"):
    set_config_value("model.default", DEFAULT_MODEL)
    agent = config.get("agent", {})
    if isinstance(agent, dict) and "reasoning_effort" not in agent:
        set_config_value("agent.reasoning_effort", DEFAULT_EFFORT)
print("configured openai-codex; existing login and model choice preserved")
""")

ENV_DEFAULTS = """import os
from urllib.parse import urlsplit
from hermes_cli.config import (
    atomic_config_write, get_config_path, require_readable_config_before_write,
)

mapping = {
    "HERMES_MODEL_PROVIDER": ("model", "provider"),
    "HERMES_DEFAULT_MODEL": ("model", "default"),
    "HERMES_MODEL_BASE_URL": ("model", "base_url"),
    "HERMES_TERMINAL_CWD": ("terminal", "cwd"),
    "HERMES_TERMINAL_BACKEND": ("terminal", "backend"),
    "HERMES_TERMINAL_TIMEOUT": ("terminal", "timeout"),
    "HERMES_WEBAPP_ENABLED": ("webapp", "enabled"),
    "HERMES_WEBAPP_HOST": ("webapp", "host"),
    "HERMES_WEBAPP_PORT": ("webapp", "port"),
}
path = get_config_path()
config = require_readable_config_before_write(path) if any(
    os.environ.get(name, "").strip() for name in mapping) else {}
updates = {}
for name, (section, key) in mapping.items():
    raw = os.environ.get(name, "").strip()
    if not raw:
        continue
    current = config.get(section, {})
    if not isinstance(current, dict):
        raise ValueError("bootstrap section must be a mapping")
    value = raw
    if name in {"HERMES_TERMINAL_TIMEOUT", "HERMES_WEBAPP_PORT"}:
        if not raw.isascii() or not raw.isdecimal():
            raise ValueError("bootstrap value must be a positive integer")
        value = int(raw)
        if value < 1 or (name == "HERMES_WEBAPP_PORT" and value > 65535):
            raise ValueError("bootstrap integer is out of range")
    elif name == "HERMES_WEBAPP_ENABLED":
        booleans = {"true": True, "1": True, "false": False, "0": False}
        if raw.lower() not in booleans:
            raise ValueError("bootstrap boolean is invalid")
        value = booleans[raw.lower()]
    elif name == "HERMES_WEBAPP_HOST":
        if raw not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("bootstrap Webapp host must be loopback")
    elif name == "HERMES_TERMINAL_CWD":
        if not raw.startswith("/") or raw.startswith("//"):
            raise ValueError("bootstrap cwd must be an absolute target path")
    elif name == "HERMES_MODEL_BASE_URL":
        url = urlsplit(raw)
        if (url.scheme not in {"http", "https"} or not url.hostname or
                url.username is not None or url.password is not None or "?" in raw or "#" in raw or
                any(char.isspace() or ord(char) < 32 for char in raw)):
            raise ValueError("bootstrap model URL is invalid")
        url.port
    if key not in current:
        updates.setdefault(section, {})[key] = value

model_updates = updates.get("model", {})
if os.environ.get("HERMES_MODEL_BASE_URL", "").strip():
    provider = config.get("model", {}).get("provider", model_updates.get("provider"))
    if provider != "custom":
        raise ValueError("bootstrap model URL requires the custom provider")
if updates:
    for section, leaves in updates.items():
        config[section] = {**config.get(section, {}), **leaves}
    atomic_config_write(path, config)
    print("hermes-start-services: filled missing environment defaults")
"""

WEBAPP_DEFAULTS = """from hermes_cli.config import (
    atomic_config_write, get_config_path, require_readable_config_before_write,
)

path = get_config_path()
config = require_readable_config_before_write(path)
webapp = config.get("webapp", {})
if not isinstance(webapp, dict):
    raise ValueError("webapp must be a mapping; configuration left unchanged")
missing = {key: value for key, value in
           {"enabled": True, "host": "127.0.0.1", "port": 9120}.items()
           if key not in webapp}
if missing:
    config["webapp"] = {**webapp, **missing}
    atomic_config_write(path, config)
    print("hermes-start-services: filled missing local Webapp defaults")
"""

def runtime_environment(environ=None):
    env = dict(os.environ if environ is None else environ)
    env["HOME"] = env.get("HOME") or str(HOME)
    env["HERMES_HOME"] = env.get("HERMES_HOME") or str(Path(env["HOME"]) / ".hermes")
    env["HERMES_WRITE_SAFE_ROOT"] = env.get("HERMES_WRITE_SAFE_ROOT") or env["HERMES_HOME"]
    env.update(HERMES_PYTHON=PYTHON, HERMES_RUNTIME_DIR=str(RUNTIME / "tools"),
               PLAYWRIGHT_BROWSERS_PATH=str(RUNTIME / "tools"),
               HERMES_WEB_DIST=str(RUNTIME / "hermes_cli/web_dist"),
               HERMES_TUI_DIR=str(RUNTIME / "ui-tui"))
    env["XDG_RUNTIME_DIR"] = env.get("XDG_RUNTIME_DIR") or str(RUNTIME_TMP)
    env["PATH"] = "/usr/local/bin:/home/hermes/.local/bin:" + (
        env.get("PATH") or "/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin")
    return env


def parse_skills_list(raw, *, pattern, label):
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError(f"duplicate {label} value")
    if any(not pattern.fullmatch(value) for value in values):
        raise ValueError(f"invalid {label} value")
    return values


def bootstrap_skills(home, environ=None):
    env = dict(os.environ if environ is None else environ)
    taps = parse_skills_list(env.get("HERMES_SKILLS_TAPS", ""),
                             pattern=GITHUB_REPOSITORY, label="skills tap")
    skills = parse_skills_list(env.get("HERMES_SKILLS_INSTALL", ""),
                               pattern=SKILL_IDENTIFIER, label="skills install")
    if not skills:
        return True
    sources = {"/".join(skill.split("/", 2)[:2]) for skill in skills}
    if not sources.issubset(taps):
        raise ValueError("skills install source is not configured as a tap")
    data = Path(home) / ".hermes"
    marker = data / ".skills-bootstrap.json"
    state = {"taps": taps, "skills": skills}
    try:
        if json.loads(marker.read_text()) == state:
            return True
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    command_prefix = ["/usr/sbin/runuser", "-u", "hermes", "--", "env",
                      f"HOME={home}", f"HERMES_HOME={data}", "/usr/local/bin/hermes", "skills"]
    commands = ([*command_prefix, "tap", "add", tap] for tap in taps)
    installs = ([*command_prefix, "install", skill, "--yes"] for skill in skills)
    for command in (*commands, *installs):
        try:
            result = subprocess.run(command, check=False, timeout=120,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired):
            print("hermes-entrypoint: skills bootstrap failed; will retry next start")
            return False
        if result.returncode:
            print("hermes-entrypoint: skills bootstrap failed; will retry next start")
            return False
    seeded = tempfile.NamedTemporaryFile(dir=data, prefix=".skills-bootstrap-", mode="w", delete=False)
    try:
        with seeded:
            json.dump(state, seeded, sort_keys=True)
            seeded.write("\n")
            os.fchmod(seeded.fileno(), 0o600)
        os.replace(seeded.name, marker)
    finally:
        Path(seeded.name).unlink(missing_ok=True)
    return True


def run_hermes(args):
    if os.geteuid() == 0:
        return os.execvp("/usr/sbin/runuser", ["/usr/sbin/runuser", "-u", "hermes", "--",
                                             "/usr/local/bin/hermes", *args])
    official = str(RUNTIME / ".venv/bin/hermes")
    return os.execvpe(official, [official, *args], runtime_environment())


def entrypoint(args):
    user = pwd.getpwnam("hermes")

    def prepare(path, mode=0o755):
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, mode)
        os.chown(path, user.pw_uid, user.pw_gid)

    prepare(RUNTIME_TMP, 0o700)
    data = HOME / ".hermes"
    prepare(data)
    for name in ("cron", "sessions", "logs", "pairing", "hooks", "image_cache",
                 "audio_cache", "memories", "skills"):
        prepare(data / name)
    try:
        bootstrap_skills(HOME)
    except ValueError:
        print("hermes-entrypoint: invalid skills bootstrap configuration; will retry next start")
    template = RUNTIME / ".env.example"
    if not (data / ".env").is_file() and template.is_file():
        # Publish a prepared inode: never follow a destination symlink as root.
        seeded = tempfile.NamedTemporaryFile(dir=data, prefix=".env-", delete=False)
        try:
            with seeded, template.open("rb") as source:
                shutil.copyfileobj(source, seeded)
                os.fchmod(seeded.fileno(), 0o600)
                os.fchown(seeded.fileno(), user.pw_uid, user.pw_gid)
            os.replace(seeded.name, data / ".env")
        finally:
            Path(seeded.name).unlink(missing_ok=True)
        print("hermes-entrypoint: seeded ~/.hermes/.env from the installed template")
    for legacy in ("hermes-agent", "node"):
        if (data / legacy).exists():
            print(f"hermes-entrypoint: legacy Hermes data notice: ~/.hermes/{legacy} is leftover from an older image and is unused; "
                  "active source is /opt/hermes. Remove old files manually only after review.")
    user_command = ["runuser", "-u", "hermes", "--", "env", f"HOME={HOME}"]
    try:
        result = subprocess.run([*user_command, "/usr/local/bin/hermes", "--version"],
                                timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        healthy = result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        healthy = False
    if not healthy:
        print("hermes-entrypoint: WARNING: Hermes runtime check failed; pull/recreate the image. "
              "Development shell remains available")
    if os.environ.get("HERMES_AUTOSTART_SERVICES", "0") == "1":
        try:
            result = subprocess.run([*user_command, "/usr/local/bin/hermes-start-services"], cwd="/")
            started = result.returncode == 0
        except OSError:
            started = False
        if not started:
            print("hermes-entrypoint: hermes-start-services reported a problem; development shell is unaffected")
    else:
        print("hermes-entrypoint: HERMES_AUTOSTART_SERVICES is not 1; development shell only")
    # exec replaces Python without flushing its buffered container diagnostics.
    sys.stdout.flush()
    sys.stderr.flush()
    command = args or ["sleep", "infinity"]
    if command == ["sleep", "infinity"]:
        return os.execvp("runuser", ["runuser", "-u", "hermes", "--", *command])
    return os.execvp(command[0], command)


def run_integration(code):
    return subprocess.run([PYTHON, "-"], input=code, text=True, capture_output=True,
                          cwd=RUNTIME, timeout=30)


def seed_codex_default_model(home):
    home = Path(home)
    marker = home / ".hermes/.codex-default-seeded"
    auth = home / ".codex/auth.json"
    if marker.is_file() or not auth.is_file() or not auth.stat().st_size or not os.access(PYTHON, os.X_OK):
        return
    print("hermes-start-services: seeding default model from ~/.codex/auth.json "
          f"(openai-codex / {DEFAULT_CODEX_MODEL}, {DEFAULT_REASONING_EFFORT} reasoning)")
    try:
        result = run_integration(CODEX_SEED)
        # Integration diagnostics stay in a private project log, never the terminal.
        log = home / ".hermes/logs/codex-seed.out"
        with log.open("w") as stream:
            stream.write(result.stdout)
            stream.write(result.stderr)
        if result.returncode == 0:
            marker.touch()
            print("hermes-start-services: Codex login setup complete (existing model choices preserved)")
            return
    except (OSError, subprocess.TimeoutExpired):
        pass
    print("hermes-start-services: codex seed skipped/failed; will retry next start "
          "(see ~/.hermes/logs/codex-seed.out)")


def ensure_env_defaults():
    result = run_integration(ENV_DEFAULTS)
    if result.returncode:
        raise RuntimeError("could not apply environment defaults; check bootstrap settings")
    if result.stdout:
        print(result.stdout, end="")


def ensure_webapp_defaults(home):
    # HOME is inherited unchanged by the official config API, just as for hermes.
    result = run_integration(WEBAPP_DEFAULTS)
    if result.returncode:
        raise RuntimeError("could not configure Webapp")
    if result.stdout:
        print(result.stdout, end="")


def select_workspace():
    candidates = [path for path in WORKSPACES.glob("*") if path.is_dir() and not path.name.startswith(".")]
    if len(candidates) == 1:
        print(f"hermes-start-services: using Dev Container workspace {candidates[0]}")
        return candidates[0]
    print("hermes-start-services: expected one Dev Container workspace under /workspaces; keeping current directory")
    return Path.cwd()


def process_running(pattern):
    return subprocess.run(["pgrep", "-f", pattern], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def launch_service(args, *, cwd, log):
    with log.open("w") as stream:
        subprocess.Popen(args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=stream,
                         stderr=subprocess.STDOUT, start_new_session=True)


def start_services():
    if shutil.which("hermes") is None:
        return 0
    home = Path(os.environ.get("HOME") or HOME)
    logs = home / ".hermes/logs"
    logs.mkdir(parents=True, exist_ok=True)
    try:
        ensure_env_defaults()
    except (RuntimeError, OSError, subprocess.TimeoutExpired):
        print("hermes-start-services: could not apply environment defaults; check bootstrap settings and config.yaml")
        return 1
    seed_codex_default_model(home)
    try:
        ensure_webapp_defaults(home)
    except (RuntimeError, OSError, subprocess.TimeoutExpired):
        print("hermes-start-services: could not configure Webapp; check config.yaml and Hermes dependencies")
        return 1
    cwd = select_workspace()
    if process_running(GATEWAY):
        print("hermes-start-services: gateway already running")
    else:
        print("hermes-start-services: starting gateway (Webapp address comes from config.yaml)")
        launch_service(["hermes", "gateway"], cwd=cwd, log=logs / "gateway.out")
    if os.environ.get("HERMES_AUTOSTART_DASHBOARD", "0") != "1":
        print("hermes-start-services: dashboard autostart disabled (set HERMES_AUTOSTART_DASHBOARD=1 to enable)")
    elif process_running(DASHBOARD):
        print("hermes-start-services: dashboard already running")
    else:
        print("hermes-start-services: starting dashboard on 127.0.0.1:9119")
        launch_service(["hermes", "dashboard", "--host", "127.0.0.1", "--port", "9119",
                        "--no-open", "--skip-build"], cwd=cwd, log=logs / "dashboard.out")
    return 0


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
            with exc:
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


def dispatch_for(program_name):
    commands = {"hermes": run_hermes, "hermes-entrypoint": entrypoint,
                "hermes-start-services": start_services, "hermes-webapp-open": open_webapp}
    try:
        return commands[Path(program_name).name]
    except KeyError:
        raise ValueError("Unknown Hermes devbox command") from None


def main(argv=None, program_name=None):
    args = list(sys.argv[1:] if argv is None else argv)
    name = sys.argv[0] if program_name is None else program_name
    try:
        function = dispatch_for(name)
        if function in (run_hermes, entrypoint):
            return function(args)
        return function()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired, http.client.HTTPException) as exc:
        # Output and IPC response bodies can contain credentials. Only our fixed
        # policy messages are safe to disclose, never external exception text.
        message = str(exc) if isinstance(exc, (RuntimeError, ValueError)) else type(exc).__name__
        print(f"{Path(name).name}: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
