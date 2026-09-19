#!/usr/bin/env bash
set -euo pipefail

workspace_dir=${1:-$(pwd -P)}
skills_dir="$workspace_dir/.agents/skills"

if [[ ! -d "$skills_dir" ]]; then
  echo "AI skill directory not found: $skills_dir" >&2
  exit 1
fi

hermes config set skills.create_dir "$skills_dir"
hermes config set skills.external_dirs "[\"$skills_dir\"]"