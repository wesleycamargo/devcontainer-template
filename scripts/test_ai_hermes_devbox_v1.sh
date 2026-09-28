#!/usr/bin/env bash
# Verify that the V1 startup hook repairs an older persisted Hermes runtime
# when a newer image-owned `hermes` shim expects the later nested layout.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
startup_script="$repo_root/src/ai-hermes-devbox-v1/.devcontainer/start-hermes.sh"
work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

home="$work/home"
legacy_runtime="$home/.hermes/hermes-agent"
launcher="$legacy_runtime/.hermes/bin/hermes"
mkdir -p "$legacy_runtime/venv/bin" "$work/bin"
ln -s /bin/true "$legacy_runtime/venv/bin/python"
touch "$legacy_runtime/hermes"
ln -s /bin/true "$work/bin/hermes"

HOME="$home" PATH="$work/bin:$PATH" bash "$startup_script"

test -x "$launcher"
"$launcher" --version
echo "PASS: V1 startup repairs the legacy Hermes launcher"
