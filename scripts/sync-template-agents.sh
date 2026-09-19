#!/usr/bin/env bash
# Maintainer script for this repo: mirror the canonical root .agents/ into the
# published template payloads (src/<id>/.agents/) and repair their skill
# symlinks, and keep the Hermes hook copy identical to the root one.
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
skill_sync=$repo/.agents/skills/sync-agent-skills/scripts/sync.sh
templates=(ai-devbox ai-hermes-devbox)
hook_rel=.devcontainer/scripts/configure-project-skills.sh
flags=(--hermes)
((check)) && flags+=(--check)
((force)) && flags+=(--force)

drift=0

"$skill_sync" "${flags[@]}" "$repo" >/dev/null || drift=1

for t in "${templates[@]}"; do
  dest=$repo/src/$t
  out=$(rsync -ac --delete --itemize-changes --dry-run "$repo/.agents/" "$dest/.agents/" | grep -v '/$' || true)
  if [[ -n $out ]]; then
    drift=1
    echo "tree: src/$t/.agents out of date"
    echo "$out" | sed 's/^/  /'
    ((check)) || { mkdir -p "$dest/.agents"; rsync -ac --delete "$repo/.agents/" "$dest/.agents/"; }
  fi
  out=$("$skill_sync" "${flags[@]}" "$dest" | grep -v '^\(synced\|already in sync\|out of sync.*\)$' || true)
  if [[ -n $out ]]; then
    drift=1
    echo "$out" | sed "s|^|src/$t: |"
  fi
done

if ! cmp -s "$repo/$hook_rel" "$repo/src/ai-hermes-devbox/$hook_rel"; then
  drift=1
  echo "hook: src/ai-hermes-devbox/$hook_rel differs from root"
  ((check)) || install -m 755 "$repo/$hook_rel" "$repo/src/ai-hermes-devbox/$hook_rel"
fi

if ((drift)); then
  ((check)) && { echo "out of sync (run without --check to fix)"; exit 1; }
  echo "synced"
else
  echo "already in sync"
fi
