#!/usr/bin/env bash
# Maintainer script for this repo: mirror the canonical root .agents/ into the
# published template payloads (src/<id>/.agents/).
#
# Usage: scripts/sync-template-agents.sh [--check] [--force]
set -euo pipefail

check=0 force=0
for arg in "$@"; do
  case $arg in
    --check) check=1 ;;
    --force) force=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

repo=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# Exclude generated agent display metadata from published payloads.
rsync_excludes=(--exclude='agents/openai.yaml' --exclude='agents/openai.yml')
templates=(ai-devbox ai-esp32-devbox)

drift=0

for t in "${templates[@]}"; do
  dest=$repo/src/$t
  out=$(rsync -ac --delete "${rsync_excludes[@]}" --itemize-changes --dry-run "$repo/.agents/" "$dest/.agents/" | grep -v '/$' || true)
  if [[ -n $out ]]; then
    drift=1
    echo "tree: src/$t/.agents out of date"
    echo "$out" | sed 's/^/  /'
    ((check)) || { mkdir -p "$dest/.agents"; rsync -ac --delete "${rsync_excludes[@]}" "$repo/.agents/" "$dest/.agents/"; }
  fi
done

if ((drift)); then
  ((check)) && { echo "out of sync (run without --check to fix)"; exit 1; }
  echo "synced"
else
  echo "already in sync"
fi
