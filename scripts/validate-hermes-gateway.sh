#!/usr/bin/env bash
# Validates the Hermes SSH gateway contract. Run this where Docker runs (the
# WSL2 host), NOT inside the devcontainer:
#
#   ./scripts/validate-hermes-gateway.sh build   # build the test image first
#   ./scripts/validate-hermes-gateway.sh all
#   ./scripts/validate-hermes-gateway.sh A       # a single checkpoint
#
# Checkpoints: A raw docker run · B compose · C two projects at once
#              D Dev Container · E image upgrade over an existing volume
#              G Webapp local defaults + optional remote authentication
# (F, a real Hermes Desktop connection, is manual.)
#
# Uses a throwaway keypair under a temp dir. It never reads, writes or
# registers anything in your own ~/.ssh, and never touches an ssh-agent.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="$REPO_ROOT/src/ai-hermes-devbox/.devcontainer"
IMAGE="${HERMES_TEST_IMAGE:-hermes-devbox:test}"
WORK="$(mktemp -d)"
KEY="$WORK/id_ed25519"
PASS=0; FAIL=0; SKIP=0

red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; bld=$'\033[1m'; off=$'\033[0m'
ok()   { printf '  %sPASS%s %s\n' "$grn" "$off" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$red" "$off" "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  %sSKIP%s %s\n' "$ylw" "$off" "$*"; SKIP=$((SKIP+1)); }
head_() { printf '\n%s== %s%s\n' "$bld" "$*" "$off"; }

cleanup() {
  docker rm -f hermes-test-a hermes-test-nokey hermes-test-e >/dev/null 2>&1
  for p in hermes-test-b hermes-test-c1 hermes-test-c2; do
    docker compose -p "$p" -f "$CTX/docker-compose.yml" -f "$CTX/docker-compose.ssh.yml" \
      -f "$WORK/override.yml" -f "$WORK/ssh-keys.yml" \
      down -v --remove-orphans >/dev/null 2>&1
  done
  docker volume rm -f hermes-test-hostkeys hermes-test-data >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

sshc() { # sshc <port> <command...>
  local port="$1"; shift
  ssh -q -i "$KEY" -p "$port" \
      -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      hermes@127.0.0.1 "$@" 2>/dev/null
}

wait_ssh() { # wait_ssh <port> [tries]
  local port="$1" tries="${2:-40}" i=0
  while [ "$i" -lt "$tries" ]; do
    sshc "$port" true >/dev/null 2>&1 && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

host_fp() { # fingerprint of the container's ed25519 host key
  ssh-keyscan -t ed25519 -p "$1" 127.0.0.1 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
}

setup() {
  command -v docker >/dev/null || { echo "docker not found -- run this on the Docker host"; exit 1; }
  ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C hermes-gateway-test
  # Never mount or mutate the operator's real OpenAI credentials in validation.
  export DEVBOX_HOST_HOME="$WORK/host-home"
  mkdir -p "$DEVBOX_HOST_HOME/.codex"
  printf '{"tokens": null}\n' >"$DEVBOX_HOST_HOME/.codex/auth.json"
  # Synthetic fixture only: let container UID 1000 write even when CI uses 1001.
  chmod 666 "$DEVBOX_HOST_HOME/.codex/auth.json"
  cat >"$WORK/override.yml" <<YML
services:
  devcontainer:
    image: $IMAGE
YML
  cat >"$WORK/ssh-keys.yml" <<YML
services:
  ssh-pubkeys:
    volumes:
      - $WORK:/host-ssh:ro
      - ssh-pubkeys:/keys
YML
}

do_build() {
  head_ "build $IMAGE"
  docker build -t "$IMAGE" -f "$CTX/Dockerfile" "$CTX" || { bad "image build"; return 1; }
  ok "image built"
}

# --- A: raw docker run -----------------------------------------------------
do_A() {
  head_ "A. raw docker run"
  docker rm -f hermes-test-a >/dev/null 2>&1
  docker run -d --init --name hermes-test-a \
    -p 127.0.0.1:22222:2222 \
    -v "$KEY.pub:/run/hermes-ssh/authorized_keys:ro" \
    -v hermes-test-hostkeys:/var/lib/hermes-ssh/host_keys \
    "$IMAGE" >/dev/null || { bad "container start"; return 1; }

  wait_ssh 22222 || { bad "sshd never accepted the key"; docker logs hermes-test-a | tail -30; return 1; }
  ok "SSH accepted the mounted public key"

  # The headline contract requirement.
  local v; v="$(sshc 22222 'hermes --version')"
  [ -n "$v" ] && ok "ssh \"hermes --version\" -> $v" || bad "hermes --version produced nothing"

  # Forced through bash so the assertion tests the PATH, not the login shell's
  # dialect: `command -v` is meaningless if the shell is ever pwsh again.
  [ "$(sshc 22222 "bash -c 'command -v hermes'")" = "/usr/local/bin/hermes" ] \
    && ok "hermes resolves to /usr/local/bin/hermes" || bad "hermes is not at the contract path"

  # Proves Hermes does not depend on interactive shell init: env -i strips
  # everything, so only sshd's own PATH is in play.
  sshc 22222 'env -i /usr/local/bin/hermes --version' >/dev/null \
    && ok "runs with an empty environment (no shell init needed)" \
    || bad "needs shell initialisation"

  [ "$(sshc 22222 'echo $SHELL')" = "/bin/bash" ] \
    && ok "login shell is bash" || bad "login shell is not bash"

  sshc 22222 'claude --version && codex --version' \
    && ok "Claude and Codex run over SSH" || bad "agent CLI missing from SSH PATH"

  # Official source, Python environment and browser assets stay in the image.
  sshc 22222 'test -f /opt/hermes/pyproject.toml && test ! -w /opt/hermes && test -x /opt/hermes/.venv/bin/python && test -f /opt/hermes/apps/desktop/dist-webapp/index.html' \
    && ok "official Hermes runtime and Webapp are image-owned" \
    || bad "official Hermes runtime or Webapp missing"

  sshc 22222 'test "$(id -u)" = 1000 && test "$HOME" = /home/hermes && sudo -n true' \
    && ok "existing user ID, home and sudo contract preserved" \
    || bad "development user contract changed"

  sshc 22222 'pwsh -NoLogo -NoProfile -NonInteractive -Command "Import-Module Terminal-Icons" && gh --version && node --version && timeout 30 hermes-acp --help' >/dev/null \
    && ok "development tools and Hermes ACP remain available" \
    || bad "development tool missing"

  # Module imports alone do not exercise the .NET named mutex used by PSReadLine.
  docker exec -u hermes hermes-test-a pwsh -NoLogo -NoProfile -NonInteractive \
    -Command '$ErrorActionPreference = "Stop"; $mutex = [System.Threading.Mutex]::new($false, "HermesPSReadLineSmoke"); $mutex.Dispose()' \
    && ok "PowerShell can create PSReadLine-style mutexes as hermes" \
    || bad "PowerShell runtime directory is not usable by hermes"

  docker exec hermes-test-a hermes config set webapp.enabled false >/dev/null \
    && sshc 22222 'test "$(stat -c %u ~/.hermes/config.yaml)" = "$(id -u)"' \
    && ok "root docker exec writes config as hermes in the existing data path" \
    || bad "root invocation wrote config under the wrong user or home"

  sshc 22222 'test ! -e ~/.hermes/hermes-agent' \
    && ok "~/.hermes holds no runtime" || bad "~/.hermes still contains a runtime"

  # Services must NOT run here: HERMES_AUTOSTART_SERVICES is unset.
  [ -z "$(sshc 22222 'pgrep -f "[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)" || true')" ] \
    && ok "no gateway process (autostart off)" || bad "gateway started without being asked"

  # Security assertions.
  # Two traps here, both of which make a WORKING refusal look like a failure:
  #   -q on ssh suppresses the very "Permission denied" line being matched;
  #   piping into grep under `set -o pipefail` surfaces ssh's exit 255 (the
  #   expected auth failure) as the pipeline's status.
  # So: capture, then match.
  local out
  out="$(ssh -p 22222 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      hermes@127.0.0.1 true 2>&1)"
  case "$out" in
    *[Pp]ermission\ denied*|*no\ supported\ authentication*) ok "password authentication refused" ;;
    *) bad "password authentication not clearly refused: $out" ;;
  esac

  out="$(ssh -i "$KEY" -p 22222 -o BatchMode=yes -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 root@127.0.0.1 true 2>&1)"
  case "$out" in
    *[Pp]ermission\ denied*) ok "root login refused" ;;
    *) bad "root login not clearly refused: $out" ;;
  esac

  # Do not use `grep -q` here. With pipefail enabled it can close the pipe as
  # soon as it finds a match, turning sshd's harmless SIGPIPE into a failure.
  docker exec hermes-test-a sshd -T 2>/dev/null | grep -i '^x11forwarding no' >/dev/null \
    && ok "X11 forwarding disabled" || bad "X11 forwarding not disabled"
  docker exec hermes-test-a sshd -T 2>/dev/null | grep -i '^allowtcpforwarding yes' >/dev/null \
    && ok "TCP forwarding available" || bad "TCP forwarding disabled"
  docker exec hermes-test-a sshd -T 2>/dev/null | grep -i '^acceptenv.*HERMES' >/dev/null \
    && ok "AcceptEnv passes HERMES_* through" || bad "AcceptEnv missing HERMES_*"
  docker exec hermes-test-a sshd -T 2>/dev/null | grep '^port 2222$' >/dev/null \
    && ok "internal port is 2222" || bad "internal port is not 2222"

  # No private key material anywhere. A bare "*.pem" match is too broad:
  # Debian/Python packages can legitimately ship public CA certificates with
  # that extension. Inspect candidate contents for actual private-key headers.
  local private_key_files
  private_key_files="$(docker exec hermes-test-a sh -c \
      'find / -xdev \( -name "id_*" -o -name "*.pem" \) ! -name "*.pub" -type f -exec grep -Iq "BEGIN .*PRIVATE KEY" {} \; -print 2>/dev/null' || true)"
  if [ -n "$private_key_files" ]; then
    bad "private-key-shaped files found in the container"
    printf '%s\n' "$private_key_files" | sed 's/^/    /'
  else
    ok "no private keys in the container"
  fi

  sshc 22222 'hermes-ssh-info' | grep -q 'Hermes SSH gateway' \
    && ok "hermes-ssh-info works over SSH" || bad "hermes-ssh-info failed"

  # Host key must survive a restart and a recreate against the same volume.
  local fp1 fp2
  fp1="$(host_fp 22222)"
  docker restart hermes-test-a >/dev/null && wait_ssh 22222
  fp2="$(host_fp 22222)"
  [ -n "$fp1" ] && [ "$fp1" = "$fp2" ] && ok "host key survives restart" \
    || bad "host key changed on restart ($fp1 -> $fp2)"

  docker rm -f hermes-test-a >/dev/null
  docker run -d --init --name hermes-test-a -p 127.0.0.1:22222:2222 \
    -v "$KEY.pub:/run/hermes-ssh/authorized_keys:ro" \
    -v hermes-test-hostkeys:/var/lib/hermes-ssh/host_keys "$IMAGE" >/dev/null
  wait_ssh 22222
  fp2="$(host_fp 22222)"
  [ "$fp1" = "$fp2" ] && ok "host key survives recreate" \
    || bad "host key changed on recreate ($fp1 -> $fp2)"

  # Graceful behaviour with no keys supplied at all.
  docker rm -f hermes-test-nokey >/dev/null 2>&1
  docker run -d --init --name hermes-test-nokey -p 127.0.0.1:22229:2222 "$IMAGE" >/dev/null
  # Key generation can outlast a fixed sleep on a busy runner. Wait for the
  # SSH host key before checking startup messages; no authorized key is needed.
  local ready=0 attempt
  for attempt in {1..40}; do
    if [ -n "$(host_fp 22229)" ]; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" -eq 1 ] && [ "$(docker inspect -f '{{.State.Running}}' hermes-test-nokey 2>/dev/null)" = "true" ]; then
    ok "starts and stays up with no authorized keys"
    docker logs hermes-test-nokey 2>&1 | grep -F 'WARNING: no keys' >/dev/null \
      && ok "warns clearly about missing keys" || bad "no warning about missing keys"
  else
    bad "SSH did not become ready when no keys were supplied"
    docker logs hermes-test-nokey 2>&1 | tail -30
  fi
  docker rm -f hermes-test-nokey >/dev/null 2>&1
}

# --- B: docker compose -----------------------------------------------------
do_B() {
  head_ "B. docker compose"
  local cmp=(docker compose -p hermes-test-b -f "$CTX/docker-compose.yml" -f "$CTX/docker-compose.ssh.yml" -f "$WORK/override.yml" -f "$WORK/ssh-keys.yml")
  HERMES_SSH_PORT=22230 "${cmp[@]}" up -d >/dev/null 2>&1 || { bad "compose up"; return 1; }

  wait_ssh 22230 || { bad "SSH not reachable on the compose port"; "${cmp[@]}" logs devcontainer | tail -30; return 1; }
  ok "SSH reachable on HERMES_SSH_PORT=22230"

  local webapp_port
  webapp_port="$("${cmp[@]}" port devcontainer 9120 2>/dev/null || true)"
  [ -z "$webapp_port" ] && ok "Compose does not publish Webapp" \
    || bad "Compose publishes Webapp: $webapp_port"

  [ -n "$(sshc 22230 'hermes --version')" ] && ok "hermes runs over SSH" || bad "hermes failed over SSH"

  # Autostart is on for compose, and must be singleton.
  sleep 5
  # NOTE: one running gateway shows up as SEVERAL matching processes (the
  # launcher wrapper plus its python child), so "== 1" is the wrong test.
  # What matters is that starting again does not ADD any.
  # `pgrep -c` already prints 0 when nothing matches (and exits 1), so a
  # trailing `|| echo 0` would append a second zero and corrupt the value.
  local g d
  g="$(sshc 22230 'pgrep -fc "[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)" 2>/dev/null | head -1')"
  d="$(sshc 22230 'pgrep -fc "[h]ermes dashboard([[:space:]]|$)|[h]ermes_cli[.]main.* dashboard([[:space:]]|$)" 2>/dev/null | head -1')"
  g="${g:-0}"; d="${d:-0}"
  [ "$g" -gt 0 ] 2>/dev/null && ok "gateway running ($g procs)" \
    || bad "gateway did not start on a fresh volume"
  [ "$d" -gt 0 ] 2>/dev/null && ok "dashboard running ($d procs)" \
    || bad "dashboard did not start on a fresh volume"

  # Re-running the starter must never duplicate.
  local again msg
  msg="$(sshc 22230 'hermes-start-services 2>&1' || true)"
  again="$(sshc 22230 'pgrep -fc "[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)" 2>/dev/null | head -1')"
  again="${again:-0}"
  if [ "$g" -eq 0 ] 2>/dev/null; then
    skip "duplicate guard untested (services not running yet)"
  elif [ "$again" -le "$g" ] 2>/dev/null; then
    ok "re-running hermes-start-services adds no processes ($g -> $again)"
  else
    bad "hermes-start-services duplicated processes ($g -> $again)"
  fi
  case "$msg" in
    *"already running"*) ok "re-run reports services already running" ;;
    *) skip "no 'already running' notice (services may not have been up)" ;;
  esac

  "${cmp[@]}" down -v --remove-orphans >/dev/null 2>&1
}

# --- C: two projects at once ----------------------------------------------
do_C() {
  head_ "C. two compose projects simultaneously"
  local c1=(docker compose -p hermes-test-c1 -f "$CTX/docker-compose.yml" -f "$WORK/override.yml")
  local c2=(docker compose -p hermes-test-c2 -f "$CTX/docker-compose.yml" -f "$WORK/override.yml")
  "${c1[@]}" up -d >/dev/null 2>&1 || { bad "project 1 startup"; return 1; }
  "${c2[@]}" up -d >/dev/null 2>&1 || { bad "project 2 startup"; return 1; }

  # No per-project port configuration or manual Hermes setup.
  local id1 id2 cid attempt status
  id1="$("${c1[@]}" ps -q devcontainer)"
  id2="$("${c2[@]}" ps -q devcontainer)"
  for cid in "$id1" "$id2"; do
    [ -z "$(docker port "$cid")" ] && ok "project $cid publishes no host ports" \
      || bad "project $cid publishes a host port"
    docker exec -u hermes "$cid" hermes --version >/dev/null \
      && ok "hermes works in project $cid" || bad "hermes failed in project $cid"
    for attempt in {1..45}; do
      status="$(docker exec -u hermes "$cid" hermes webapp --status 2>&1 || true)"
      [[ "$status" == *"Serving at http://127.0.0.1:9120"* ]] && break
      sleep 2
    done
    [[ "$status" == *"Serving at http://127.0.0.1:9120"* ]] \
      && ok "project $cid serves its own local Webapp on first boot" \
      || bad "project $cid did not serve Webapp: $status"
  done

  # Distinct host identities: a shared key would be a cross-project collision.
  local f1 f2
  f1="$(docker exec "$id1" ssh-keygen -lf /var/lib/hermes-ssh/host_keys/ssh_host_ed25519_key.pub)"
  f2="$(docker exec "$id2" ssh-keygen -lf /var/lib/hermes-ssh/host_keys/ssh_host_ed25519_key.pub)"
  [ -n "$f1" ] && [ "$f1" != "$f2" ] && ok "each project has its own host key" \
    || bad "projects share a host key ($f1 / $f2)"

  # A credential write from one container must reach the host and the other
  # project. This touches only the synthetic file created by setup().
  if docker exec -i -u hermes "$id1" /opt/hermes/.venv/bin/python - <<'PY'
import json
from pathlib import Path
path = Path.home() / ".codex/auth.json"
assert json.loads(path.read_text()) == {"tokens": None}
path.write_text('{"tokens": null, "fixture": "persisted-on-host"}\n')
PY
  then
    if python3 - "$DEVBOX_HOST_HOME/.codex/auth.json" <<'PY'
import json, sys
from pathlib import Path
assert json.loads(Path(sys.argv[1]).read_text())["fixture"] == "persisted-on-host"
PY
    then ok "Codex credential writes persist on the host"
    else bad "Codex credential write did not reach the host"; fi
    docker exec -u hermes "$id2" /opt/hermes/.venv/bin/python -c \
      'import json; from pathlib import Path; assert json.loads((Path.home()/".codex/auth.json").read_text())["fixture"] == "persisted-on-host"' \
      && ok "second project reuses host Codex credentials" \
      || bad "second project did not see host Codex credentials"
  else bad "container cannot read/write the host Codex credential file"; fi

  "${c1[@]}" down -v --remove-orphans >/dev/null 2>&1
  "${c2[@]}" down -v --remove-orphans >/dev/null 2>&1
}

# --- D: Dev Container ------------------------------------------------------
do_D() {
  head_ "D. Dev Container"
  if ! command -v devcontainer >/dev/null 2>&1; then
    skip "devcontainer CLI not installed (npm i -g @devcontainers/cli) -- open it in VS Code instead"
    return 0
  fi
  grep -q 'sshd' "$CTX/devcontainer.json" && bad "devcontainer.json still references sshd" \
    || ok "devcontainer.json has no sshd feature"
  grep -q 'postStartCommand' "$CTX/devcontainer.json" && bad "devcontainer.json still has postStartCommand" \
    || ok "devcontainer.json has no postStartCommand"
  skip "full 'devcontainer up' run left to you -- it mounts the real workspace"
}

# --- E: image upgrade over an existing volume ------------------------------
do_E() {
  head_ "E. image upgrade with an existing (old-layout) volume"
  docker rm -f hermes-test-e >/dev/null 2>&1
  docker volume rm -f hermes-test-data >/dev/null 2>&1
  docker volume create hermes-test-data >/dev/null

  # Seed the volume the way an older image left it: runtime AND user data.
  docker run --rm -v hermes-test-data:/d busybox:1.37 sh -c '
    mkdir -p /d/hermes-agent/venv/bin /d/node/bin /d/sessions /d/memories /d/skills
    echo "OLD-RUNTIME"        > /d/hermes-agent/MARKER
    echo "model: old"         > /d/config.yaml
    echo "SECRET=keepme"      > /d/.env
    echo "session-data"       > /d/sessions/s1.json
    echo "memory-data"        > /d/memories/m1.md
    echo "skill-data"         > /d/skills/sk1.md
    chown -R 1000:1000 /d' >/dev/null

  docker run -d --init --name hermes-test-e -p 127.0.0.1:22233:2222 \
    -v "$KEY.pub:/run/hermes-ssh/authorized_keys:ro" \
    -v hermes-test-data:/home/hermes/.hermes "$IMAGE" >/dev/null
  wait_ssh 22233 || { bad "container with legacy volume did not come up"; docker logs hermes-test-e | tail -30; return 1; }
  ok "starts against a volume from the old layout"

  # The new runtime must win.
  [ "$(sshc 22233 "bash -c 'command -v hermes'")" = "/usr/local/bin/hermes" ] \
    && ok "uses the image's hermes, not the volume's" || bad "resolved hermes outside the image"
  local version
  if version="$(sshc 22233 'hermes --version 2>&1')"; then
    ok "hermes --version works with the legacy volume mounted: $version"
  else
    bad "hermes failed with the legacy volume mounted: $version"
  fi

  # User data must survive untouched.
  local lost=""
  for f in config.yaml .env sessions/s1.json memories/m1.md skills/sk1.md; do
    sshc 22233 "test -s ~/.hermes/$f" || lost="$lost $f"
  done
  [ -z "$lost" ] && ok "config, credentials, sessions, memories, skills all survived" \
    || bad "user data lost:$lost"
  [ "$(sshc 22233 'cat ~/.hermes/.env')" = "SECRET=keepme" ] \
    && ok "credential file contents unchanged" || bad "credential file was modified"

  # Obsolete runtime must be left alone, but called out.
  sshc 22233 'test -f ~/.hermes/hermes-agent/MARKER' \
    && ok "obsolete runtime left in place (not deleted automatically)" \
    || bad "entrypoint deleted user-owned files"
  docker logs hermes-test-e 2>&1 | grep -F 'leftover from an older image' >/dev/null \
    && ok "start-up explains how to remove the leftovers" || bad "no guidance about leftovers"

  docker rm -f hermes-test-e >/dev/null 2>&1
  docker volume rm -f hermes-test-data >/dev/null 2>&1
}

do_G() {
  head_ "G. Webapp local defaults and optional remote login"
  if python3 -m unittest discover -s "$REPO_ROOT/scripts" -p 'test_*hermes*.py' \
      && python3 "$REPO_ROOT/scripts/validate-hermes-webapp.py" "$IMAGE"; then
    ok "Webapp contract"
  else
    bad "Webapp contract"
  fi
}

main() {
  setup
  case "${1:-all}" in
    build) do_build ;;
    A) do_A ;; B) do_B ;; C) do_C ;; D) do_D ;; E) do_E ;; G) do_G ;;
    all) do_A; do_B; do_C; do_D; do_E; do_G ;;
    *) echo "usage: $0 [build|A|B|C|D|E|G|all]"; exit 2 ;;
  esac
  printf '\n%s%d passed, %d failed, %d skipped%s\n' "$bld" "$PASS" "$FAIL" "$SKIP" "$off"
  printf 'Checkpoint F is optional for Webapp users; it tests a real Hermes Desktop connection.\n'
  printf 'It requires a running ai-hermes-devbox project with docker-compose.ssh.yml enabled.\n'
  printf 'Validation containers are disposable and removed when this script exits.\n'
  printf 'Replace /path/to/hermes-project with the project where the Hermes template is applied:\n'
  printf '  bash %q /path/to/hermes-project hermes-ssh-info\n' "$CTX/scripts/find-devcontainer.sh"
  printf 'Use the printed values in Hermes Desktop.\n'
  [ "$FAIL" -eq 0 ]
}

main "$@"
