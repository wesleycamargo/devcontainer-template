#!/usr/bin/env bash
# Mandatory Docker-host smoke; never use the operator's workspace or credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-${HERMES_TEST_IMAGE:-hermes-devbox:test}}"
for tool in docker devcontainer git python3 timeout; do
  command -v "$tool" >/dev/null || { echo "FAIL $tool is required" >&2; exit 1; }
done

if [[ "$(timeout --version 2>/dev/null)" != *"GNU coreutils"* ]]; then
  echo "FAIL GNU coreutils timeout is required" >&2
  exit 1
fi

# Budgets are seconds; positive integer overrides make hanging-boundary tests fast.
HERMES_SMOKE_INFO_TIMEOUT="${HERMES_SMOKE_INFO_TIMEOUT-30}"
HERMES_SMOKE_UP_TIMEOUT="${HERMES_SMOKE_UP_TIMEOUT-900}"
HERMES_SMOKE_EXEC_TIMEOUT="${HERMES_SMOKE_EXEC_TIMEOUT-180}"
HERMES_SMOKE_CLEANUP_TIMEOUT="${HERMES_SMOKE_CLEANUP_TIMEOUT-60}"
HERMES_SMOKE_KILL_AFTER="${HERMES_SMOKE_KILL_AFTER-5}"
for knob in HERMES_SMOKE_INFO_TIMEOUT HERMES_SMOKE_UP_TIMEOUT HERMES_SMOKE_EXEC_TIMEOUT HERMES_SMOKE_CLEANUP_TIMEOUT HERMES_SMOKE_KILL_AFTER; do
  [[ "${!knob}" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL $knob must be a positive integer (seconds)" >&2; exit 1; }
done

ACTIVE_PID=
run_bounded() {
  local budget=$1 result=0
  shift
  # GNU timeout owns a fresh process group. Background + wait lets Bash run its
  # cancellation trap immediately instead of deferring it behind a stuck CLI.
  timeout --kill-after="$HERMES_SMOKE_KILL_AFTER" "$budget" "$@" &
  ACTIVE_PID=$!
  wait "$ACTIVE_PID" || result=$?
  ACTIVE_PID=
  return "$result"
}

stop_active() {
  if [ -n "$ACTIVE_PID" ]; then
    # Stop only our timeout-owned group, even if a child ignores TERM. If timeout
    # has not established its group yet, kill its still-owned PID instead.
    kill -KILL -- "-$ACTIVE_PID" 2>/dev/null || kill -KILL -- "$ACTIVE_PID" 2>/dev/null || :
    wait "$ACTIVE_PID" 2>/dev/null || :
    ACTIVE_PID=
  fi
}
trap 'trap "" TERM INT; stop_active' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_bounded "$HERMES_SMOKE_INFO_TIMEOUT" docker info >/dev/null

SCRATCH="${TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}}"
mkdir -p "$SCRATCH"
WORK="$(mktemp -d "$SCRATCH/hermes-smoke.XXXXXXXX")"
# Cover setup errors before the project/configuration exists, too.
trap 'trap "" TERM INT; stop_active; run_bounded "$HERMES_SMOKE_CLEANUP_TIMEOUT" rm -rf -- "$WORK"' EXIT
# The mounted parent must be traversable by image UID 1000, not just the host
# runner UID. Only this disposable tree is relaxed; it contains no real secrets.
chmod 755 "$WORK"
umask 022
PROJECT="hermes-smoke-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
FIXTURE="$WORK/$PROJECT"
CONFIG="$FIXTURE/.devcontainer"
export COMPOSE_PROJECT_NAME="$PROJECT"
export DEVBOX_HOST_HOME="$WORK/host-home"
export HERMES_AUTOSTART_SERVICES=1
export HERMES_AUTOSTART_DASHBOARD=0
# Catalog/network acceptance belongs exclusively to runtime checkpoint H.
export HERMES_SKILLS_INSTALL=
export HERMES_SKILLS_TAPS=
# Inherited Compose overrides can refer to the operator's private env/config.
unset COMPOSE_FILE COMPOSE_ENV_FILES
export COMPOSE_DISABLE_ENV_FILE=1

cleanup() {
  local result=$? cleanup_failed=0
  trap - EXIT
  trap '' TERM INT
  stop_active
  # Attempt every check even when down or an earlier inspection fails.
  set +e
  if [ -f "$CONFIG/docker-compose.test.yml" ]; then
    run_bounded "$HERMES_SMOKE_CLEANUP_TIMEOUT" docker compose -p "$PROJECT" \
      -f "$CONFIG/docker-compose.yml" -f "$CONFIG/docker-compose.test.yml" \
      down -v --remove-orphans >/dev/null || cleanup_failed=1
    run_bounded "$HERMES_SMOKE_CLEANUP_TIMEOUT" docker ps -aq \
      --filter "label=com.docker.compose.project=$PROJECT" > "$WORK/remaining-containers" || cleanup_failed=1
    run_bounded "$HERMES_SMOKE_CLEANUP_TIMEOUT" docker volume ls -q \
      --filter "label=com.docker.compose.project=$PROJECT" > "$WORK/remaining-volumes" || cleanup_failed=1
    if [ -s "$WORK/remaining-containers" ] || [ -s "$WORK/remaining-volumes" ]; then
      cleanup_failed=1
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
      echo "FAIL cleanup of disposable Compose project $PROJECT (containers/volumes not proven absent)" >&2
      [ "$result" -ne 0 ] || result=1
    fi
  fi
  run_bounded "$HERMES_SMOKE_CLEANUP_TIMEOUT" rm -rf -- "$WORK" || {
    echo "FAIL cleanup of temporary fixture $WORK" >&2; result=1;
  }
  if [ "$result" -eq 0 ]; then
    echo "PASS disposable Dev Container starts with features, image-owned gh and protected Webapp; project cleaned"
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$CONFIG" "$DEVBOX_HOST_HOME/.codex"
printf '{"tokens": null}\n' > "$DEVBOX_HOST_HOME/.codex/auth.json"
# This is a synthetic fixture only; the host and container UIDs may differ.
chmod 666 "$DEVBOX_HOST_HOME/.codex/auth.json"
printf 'disposable workspace\n' > "$FIXTURE/smoke-marker.txt"

git -C "$ROOT" ls-files -z -- src/ai-hermes-devbox/.devcontainer/ > "$WORK/tracked-files"
while IFS= read -r -d '' file; do
  # A tracked link must not turn the allowlist into a read of ignored secrets.
  if [ -L "$ROOT/$file" ]; then
    echo "FAIL unsafe tracked file: $file" >&2
    exit 1
  fi
  # Git can still list a tracked file removed in the working tree.
  [ -e "$ROOT/$file" ] || continue
  if [ ! -f "$ROOT/$file" ]; then
    echo "FAIL unsafe tracked file: $file" >&2
    exit 1
  fi
  relative="${file#src/ai-hermes-devbox/.devcontainer/}"
  mkdir -p "$(dirname "$CONFIG/$relative")"
  cp "$ROOT/$file" "$CONFIG/$relative"
done < "$WORK/tracked-files"

python3 - "$CONFIG/devcontainer.json" "$CONFIG/docker-compose.test.yml" "$IMAGE" <<'PY'
import json
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
config = json.loads(re.sub(r"(?m)^\s*//.*$", "", path.read_text()))
config["dockerComposeFile"] = ["docker-compose.yml", "docker-compose.test.yml"]
path.write_text(json.dumps(config, indent=2) + "\n")
# JSON is valid YAML and safely encodes the supplied image identifier.
Path(sys.argv[2]).write_text(json.dumps({
    "services": {"devcontainer": {"image": sys.argv[3]}},
}, indent=2) + "\n")
PY

# Do not let Compose discover the operator's checkout .env.
cd "$FIXTURE"
run_bounded "$HERMES_SMOKE_UP_TIMEOUT" devcontainer up --workspace-folder "$FIXTURE" \
  --id-label "hermes.smoke=$PROJECT" \
  --user-data-folder "$WORK/cli-state" \
  --update-remote-user-uid-default never \
  --frozen-lockfile --log-format json

exec_in() {
  run_bounded "$HERMES_SMOKE_EXEC_TIMEOUT" devcontainer exec --workspace-folder "$FIXTURE" \
    --id-label "hermes.smoke=$PROJECT" \
    --user-data-folder "$WORK/cli-state" "$@"
}

EXPECTED_GH="$(python3 - "$CONFIG/Dockerfile" <<'PY'
from pathlib import Path
import re
import sys
match = re.search(r"(?m)^ARG GITHUB_CLI_VERSION=(\S+)$", Path(sys.argv[1]).read_text())
if not match:
    raise SystemExit("FAIL Dockerfile must pin GITHUB_CLI_VERSION")
print(match.group(1))
PY
)"

exec_in bash -euc '
  test "$(id -un)" = hermes
  test "$(id -u)" = 1000
  test "$(id -g)" = 1000
  test "$PWD" = "/workspaces/$1"
  test -f smoke-marker.txt
  gh_output="$(gh --version)"
  # Match the complete version token, not a prefix such as 2.103.30.
  [[ "$gh_output" == "gh version $2 "* || "$gh_output" == "gh version $2" ]]
  command -v zsh
  bicep --version
  pwsh -NoLogo -NoProfile -NonInteractive -Command "Import-Module Terminal-Icons -ErrorAction Stop"
  hermes --version
  claude --version
  codex --version
' smoke "$PROJECT" "$EXPECTED_GH"

exec_in python3 -c '
import json
import time
import urllib.error
import urllib.request

browser = urllib.request.build_opener(urllib.request.ProxyHandler({}))
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    try:
        with browser.open("http://127.0.0.1:9120/api/sessions", timeout=3):
            raise SystemExit("FAIL Webapp allowed anonymous access")
    except urllib.error.HTTPError as exc:
        with exc:
            body = exc.read()
            if exc.code in (401, 403):
                print("PASS Dev Container Webapp is ready and requires authentication")
                break
            try:
                starting = json.loads(body) == {"error": "gateway_not_ready", "state": "starting"}
            except (ValueError, UnicodeError):
                starting = False
            if exc.code != 503 or not starting:
                raise SystemExit("FAIL unexpected Webapp response")
    except (urllib.error.URLError, ConnectionError, TimeoutError):
        pass
    time.sleep(1)
else:
    raise SystemExit("FAIL Dev Container Webapp never became ready")
'

exec_in bash -euc '
  mapfile -t gateway_pids < <(pgrep -f "[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)")
  test "${#gateway_pids[@]}" -eq 1
  test "$(readlink "/proc/${gateway_pids[0]}/cwd")" = "/workspaces/$1"
' smoke "$PROJECT"

exec_in bash -euc '
  if pgrep -f "[h]ermes dashboard([[:space:]]|$)|[h]ermes_cli[.]main.* dashboard([[:space:]]|$)"; then
    echo "FAIL dashboard started without opt-in" >&2
    exit 1
  else
    test "$?" -eq 1
  fi
  if pgrep -x sshd; then
    echo "FAIL SSH daemon is running in the shell-only image" >&2
    exit 1
  else
    test "$?" -eq 1
  fi
'
