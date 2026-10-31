#!/usr/bin/env bash
# Apply a published template into a fresh consumer directory and run its image.
set -euo pipefail
id=${1:?template id required}
version=${2:?published version required}
repo=${GITHUB_REPOSITORY:-wesleycamargo/devcontainer-template}
source_root=$(cd "$(dirname "$0")/.." && pwd)
case "$id" in ai-devbox|ai-esp32-devbox) ;; *) exit 2 ;; esac
scratch=$(mktemp -d)
project="$scratch/project"
export DEVBOX_HOST_HOME="$scratch/host"
export COMPOSE_PROJECT_NAME="verify-${id}-${GITHUB_RUN_ID:-local}"
unset DEVBOX_WORKSPACE_ROOT
mkdir -p "$project" "$DEVBOX_HOST_HOME"/{.claude,.codex,.hermes}
printf '{}\n' > "$DEVBOX_HOST_HOME/.claude.json"
printf '{}\n' > "$DEVBOX_HOST_HOME/.codex/auth.json"
printf 'Validation fixture.\n' > "$DEVBOX_HOST_HOME/.claude/CLAUDE.md"
# Disposable fixtures must be writable by the image user and the runner UID.
chmod -R a+rwX "$scratch"
compose=(docker compose -f "$project/.devcontainer/docker-compose.yml")
cleanup() {
  "${compose[@]}" logs --no-color || true
  "${compose[@]}" down -v --remove-orphans || true
  rm -rf "$scratch"
}
trap cleanup EXIT
devcontainer templates apply --workspace-folder "$project" --template-id "ghcr.io/$repo/$id:$version"
files=(Dockerfile docker-compose.yml devcontainer.json)
if [ "$id" = ai-devbox ]; then files+=(entrypoint.sh); fi
for file in "${files[@]}"; do
  cmp "$source_root/src/$id/.devcontainer/$file" "$project/.devcontainer/$file"
done
test -d "$project/.agents/skills"
"${compose[@]}" config --format json > "$scratch/compose.json"
jq -e '.services.devcontainer | .image != null and .build == null' "$scratch/compose.json"
"${compose[@]}" pull
docker pull "ghcr.io/$repo/$id-image:$version"
test "$(docker image inspect "ghcr.io/$repo/$id-image:latest" --format '{{.Id}}')" = \
     "$(docker image inspect "ghcr.io/$repo/$id-image:$version" --format '{{.Id}}')"
# Reproduce the reported failure: a nonempty root-owned volume is not seeded
# from the image, so its installation directory is initially missing.
runtime_volume=$(jq -r '.volumes["hermes-runtime"].name' "$scratch/compose.json")
image="ghcr.io/$repo/$id-image:$version"
docker volume create "$runtime_volume"
docker run --rm --user root --entrypoint /bin/bash \
  --mount "type=volume,source=$runtime_volume,target=/home/vscode/.hermes/installs,volume-nocopy" \
  "$image" -euc '
    chown 0:0 /home/vscode/.hermes/installs
    chmod 755 /home/vscode/.hermes/installs
    printf persisted > /home/vscode/.hermes/installs/legacy-marker
  '
if docker run --rm --user vscode --entrypoint /bin/bash \
  -e HOME=/home/vscode \
  --mount "type=volume,source=$runtime_volume,target=/home/vscode/.hermes/installs,volume-nocopy" \
  "$image" -c 'timeout 30 hermes pm repair' > "$scratch/repro.log" 2>&1; then
  echo 'Expected uncorrected root-owned runtime to reject Hermes writes' >&2
  exit 1
fi
grep -F 'install state is not writable by this user' "$scratch/repro.log"
printf unchanged > "$DEVBOX_HOST_HOME/.hermes/host-sentinel"
host_owner=$(stat -c '%u:%g' "$DEVBOX_HOST_HOME/.hermes/host-sentinel")
devcontainer up --workspace-folder "$project"
# The Compose command prepares an old empty runtime asynchronously.
timeout 240 "${compose[@]}" exec -T devcontainer bash -c \
  'until hermes --version >/dev/null 2>&1; do sleep 2; done'
"${compose[@]}" exec -T devcontainer bash -euo pipefail -c '
  test "$(id -un)" = vscode
  test "$HOME" = /home/vscode
  test "$PWD" = /workspace
  ! command -v skills
  ! command -v sync-project-skills
  python --version
  node --version
  gh --version
  timeout 60 claude --version
  timeout 60 codex --version
  test "$(stat -c %u:%g ~/.hermes/installs)" = "$(id -u):$(id -g)"
  test "$(cat ~/.hermes/installs/legacy-marker)" = persisted
  test -w ~/.hermes/installs/legacy-marker
  timeout 180 hermes --version
  pwsh -NoLogo -NoProfile -NonInteractive -Command '\''$ErrorActionPreference = "Stop"; Import-Module Terminal-Icons'\''
  test "$(readlink ~/.codex/AGENTS.md)" = /home/vscode/.claude/CLAUDE.md
  test -w ~/.codex/config.toml
  printf persisted > ~/.cache/devbox-validation
  printf persisted > ~/.hermes/installs/devbox-validation
  printf persisted > ~/.hermes/devbox-validation
'
if [ "$id" = ai-esp32-devbox ]; then
  "${compose[@]}" exec -T devcontainer esptool version
  "${compose[@]}" exec -T devcontainer mpremote --version
fi
"${compose[@]}" down
# Also recover a previously populated runtime, retaining dependencies and data.
docker run --rm --user root --entrypoint /bin/bash \
  --mount "type=volume,source=$runtime_volume,target=/home/vscode/.hermes/installs" \
  "$image" -euc 'chown -Rh 0:0 /home/vscode/.hermes/installs'
devcontainer up --workspace-folder "$project"
"${compose[@]}" exec -T devcontainer bash -euc '
  test "$(stat -c %u:%g ~/.hermes/installs)" = "$(id -u):$(id -g)"
  test -z "$(find ~/.hermes/installs -xdev ! -uid "$(id -u)" -print -quit)"
  timeout 60 hermes --version
  test "$(cat ~/.cache/devbox-validation)" = persisted
  test "$(cat ~/.hermes/installs/devbox-validation)" = persisted
  test "$(cat ~/.hermes/devbox-validation)" = persisted
'
test "$(cat "$DEVBOX_HOST_HOME/.hermes/host-sentinel")" = unchanged
test "$(stat -c '%u:%g' "$DEVBOX_HOST_HOME/.hermes/host-sentinel")" = "$host_owner"
{
  printf '### %s %s\n\n' "$id" "$version"
  printf 'Commit: `%s`\n\n' "${GITHUB_SHA:-local}"
  printf 'Applied published template in a fresh directory; startup, tools, root-owned runtime recovery and persistence passed.\n\n'
  docker image inspect "ghcr.io/$repo/$id-image:$version" --format '{{json .RepoDigests}}'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
