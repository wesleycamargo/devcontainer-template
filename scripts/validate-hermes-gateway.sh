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
    docker compose -p "$p" -f "$CTX/docker-compose.yml" -f "$WORK/override.yml" \
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
  cat >"$WORK/override.yml" <<YML
services:
  devcontainer:
    image: $IMAGE
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

  # The runtime must come from the image, not from ~/.hermes.
  sshc 22222 'test -x /usr/local/lib/hermes-agent/venv/bin/python' \
    && ok "runtime lives in the image (/usr/local/lib/hermes-agent)" \
    || bad "image runtime missing"

  sshc 22222 'test ! -e ~/.hermes/hermes-agent' \
    && ok "~/.hermes holds no runtime" || bad "~/.hermes still contains a runtime"

  # Services must NOT run here: HERMES_AUTOSTART_SERVICES is unset.
  [ -z "$(sshc 22222 'pgrep -f "[h]ermes gateway" || true')" ] \
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
  sleep 6
  if [ "$(docker inspect -f '{{.State.Running}}' hermes-test-nokey 2>/dev/null)" = "true" ]; then
    ok "starts and stays up with no authorized keys"
    docker logs hermes-test-nokey 2>&1 | grep -q 'WARNING: no keys' \
      && ok "warns clearly about missing keys" || bad "no warning about missing keys"
  else
    bad "container exited when no keys were supplied"
  fi
  docker rm -f hermes-test-nokey >/dev/null 2>&1
}

# --- B: docker compose -----------------------------------------------------
do_B() {
  head_ "B. docker compose"
  local cmp=(docker compose -p hermes-test-b -f "$CTX/docker-compose.yml" -f "$WORK/override.yml")
  HERMES_SSH_PORT=22230 "${cmp[@]}" up -d >/dev/null 2>&1 || { bad "compose up"; return 1; }

  wait_ssh 22230 || { bad "SSH not reachable on the compose port"; "${cmp[@]}" logs devcontainer | tail -30; return 1; }
  ok "SSH reachable on HERMES_SSH_PORT=22230"

  [ -n "$(sshc 22230 'hermes --version')" ] && ok "hermes runs over SSH" || bad "hermes failed over SSH"

  # Autostart is on for compose, and must be singleton.
  sleep 5
  # NOTE: one running gateway shows up as SEVERAL matching processes (the
  # launcher wrapper plus its python child), so "== 1" is the wrong test.
  # What matters is that starting again does not ADD any.
  # `pgrep -c` already prints 0 when nothing matches (and exits 1), so a
  # trailing `|| echo 0` would append a second zero and corrupt the value.
  local g d
  g="$(sshc 22230 'pgrep -fc "[h]ermes gateway" 2>/dev/null | head -1')"
  d="$(sshc 22230 'pgrep -fc "[h]ermes dashboard" 2>/dev/null | head -1')"
  g="${g:-0}"; d="${d:-0}"
  [ "$g" -gt 0 ] 2>/dev/null && ok "gateway running ($g procs)" \
    || skip "gateway not running (expected until Hermes is configured: ~/.hermes/config.yaml)"
  [ "$d" -gt 0 ] 2>/dev/null && ok "dashboard running ($d procs)" \
    || skip "dashboard not running (expected until Hermes is configured)"

  # Re-running the starter must never duplicate.
  local again msg
  msg="$(sshc 22230 'hermes-start-services 2>&1' || true)"
  again="$(sshc 22230 'pgrep -fc "[h]ermes gateway" 2>/dev/null | head -1')"
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
  HERMES_SSH_PORT=22231 COMPOSE_PROJECT_NAME=hermes-test-c1 "${c1[@]}" up -d >/dev/null 2>&1
  HERMES_SSH_PORT=22232 COMPOSE_PROJECT_NAME=hermes-test-c2 "${c2[@]}" up -d >/dev/null 2>&1

  wait_ssh 22231 && ok "project 1 reachable on 22231" || bad "project 1 unreachable"
  wait_ssh 22232 && ok "project 2 reachable on 22232" || bad "project 2 unreachable"

  [ -n "$(sshc 22231 'hermes --version')" ] && [ -n "$(sshc 22232 'hermes --version')" ] \
    && ok "hermes works in both simultaneously" || bad "hermes failed in one of them"

  # Internal port identical, host ports distinct.
  [ "$(sshc 22231 'ss -ltn 2>/dev/null | grep -c ":2222"')" != "0" ] \
    && ok "internal port stays 2222 in both" || skip "could not inspect listeners (ss missing)"

  # Distinct host identities: a shared key would be a cross-project collision.
  local f1 f2; f1="$(host_fp 22231)"; f2="$(host_fp 22232)"
  [ -n "$f1" ] && [ "$f1" != "$f2" ] && ok "each project has its own host key" \
    || bad "projects share a host key ($f1 / $f2)"

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
  [ -n "$(sshc 22233 'hermes --version')" ] \
    && ok "hermes --version works with the legacy volume mounted" || bad "hermes failed"

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

main() {
  setup
  case "${1:-all}" in
    build) do_build ;;
    A) do_A ;; B) do_B ;; C) do_C ;; D) do_D ;; E) do_E ;;
    all) do_A; do_B; do_C; do_D; do_E ;;
    *) echo "usage: $0 [build|A|B|C|D|E|all]"; exit 2 ;;
  esac
  printf '\n%s%d passed, %d failed, %d skipped%s\n' "$bld" "$PASS" "$FAIL" "$SKIP" "$off"
  printf 'Checkpoint F (real Hermes Desktop connection) is manual: run\n'
  printf '  bash .devcontainer/scripts/find-devcontainer.sh "$(pwd)" hermes-ssh-info\n'
  printf 'and use the printed values.\n'
  [ "$FAIL" -eq 0 ]
}

main "$@"
