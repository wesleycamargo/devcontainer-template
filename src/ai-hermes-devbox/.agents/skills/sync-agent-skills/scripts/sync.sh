#!/usr/bin/env bash
# Point .claude/skills (and .hermes/skills) at ../.agents/skills in a repo root.
#
# Usage: sync.sh [--check] [--force] [--hermes] [root]
#   --check  report drift, change nothing, exit 1 if anything is out of sync
#   --force  replace a real directory/file sitting where a symlink belongs
#            (moved aside to <path>.bak, never deleted)
#   --hermes also manage .hermes/skills when no .hermes/ dir exists yet
#   root     repo root to operate on (default: the repo holding this script)
set -euo pipefail

check=0 force=0 hermes=0 root=
for arg in "$@"; do
  case $arg in
    --check) check=1 ;;
    --force) force=1 ;;
    --hermes) hermes=1 ;;
    -*) echo "unknown argument: $arg" >&2; exit 2 ;;
    *) root=$arg ;;
  esac
done

root=${root:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}
root=$(cd -P "$root" && pwd -P)

[[ -d $root/.agents/skills ]] || { echo "missing $root/.agents/skills" >&2; exit 1; }

aliases=(.claude)
[[ -d $root/.hermes ]] || ((hermes)) && aliases+=(.hermes)

drift=0
for dir in "${aliases[@]}"; do
  link=$root/$dir/skills
  rel=$dir/skills
  if [[ -L $link && $(readlink "$link") == ../.agents/skills ]]; then
    continue
  fi
  echo "symlink: $rel -> ../.agents/skills"
  drift=1
  ((check)) && continue
  mkdir -p "$root/$dir"
  if [[ -L $link ]]; then
    rm "$link"
  elif [[ -e $link ]]; then
    if ((force)); then
      mv "$link" "$link.bak"
      echo "  moved existing $rel to $rel.bak"
    else
      echo "  $rel is not a symlink; move its skills into .agents/skills or pass --force" >&2
      exit 1
    fi
  fi
  ln -s ../.agents/skills "$link"
done

if ((drift)); then
  ((check)) && { echo "out of sync (run without --check to fix)"; exit 1; }
  echo "synced"
else
  echo "already in sync"
fi
