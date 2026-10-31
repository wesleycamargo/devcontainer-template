#!/usr/bin/env bash
# Finds the running container for this project's Compose "devcontainer"
# service and execs into it. Looked up by the project's working-dir label
# instead of `docker compose exec`, because a bare `docker compose -f ...`
# resolves its own default project name from the compose file's directory,
# which does not match the project name VS Code's "Reopen in Container" /
# `devcontainer up` assign (e.g. `devcontainer-template_devcontainer`) -- so
# it reports "service is not running" against a container started that way
# even while it's up. The working-dir label is stable across all three ways
# of starting it (plain `docker compose up -d`, "Reopen in Container",
# `devcontainer up`).
#
# Usage: find-devcontainer.sh <wsl-project-path> <command> [args...]
set -euo pipefail

project_path="$1"
shift

cid=$(docker ps \
  --filter "label=com.docker.compose.project.working_dir=${project_path}/.devcontainer" \
  --filter "label=com.docker.compose.service=devcontainer" \
  --format '{{.ID}}' | head -n1)

if [ -z "$cid" ]; then
  echo "No running 'devcontainer' service container found for $project_path." >&2
  exit 1
fi

exec docker exec "$cid" "$@"
