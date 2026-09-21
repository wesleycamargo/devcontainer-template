#!/usr/bin/env bash
# Keeps the project's .agents/skills current with upstream and exposes it to
# every configured coding agent, at both project and global scope, using the
# `skills` CLI (npm install -g skills; see the Dockerfile). Installed as
# /usr/local/bin/sync-project-skills, shared by both templates. Takes no
# arguments -- everything comes from env vars set in docker-compose.yml and
# the /workspaces/*/ auto-detect glob already used by hermes-ssh-info.sh.
#
#   SYNC_SKILLS_USER      user to drop to if this runs as root (required to
#                          do anything; skipped for a non-root invocation)
#   SYNC_SKILLS_AGENTS    space-separated agent names to expose skills to, or
#                          "*" for every agent the skills CLI detects
#                          installed (default: "*")
#   SYNC_SKILLS_UPSTREAM  repo to pull .agents/skills from
#                          (default: wesleycamargo/devcontainer-template)
#
# Best-effort throughout: a missing workspace, an unreachable upstream, or a
# failed install must never fail the container's startup. Safe to re-run --
# every step is idempotent by design (skills CLI install tracking).
set -uo pipefail

log() { printf 'sync-project-skills: %s\n' "$*"; }

# Drop from root to the project user so ~/.claude, ~/.codex etc. land in the
# right home directory. HOME is set explicitly: su rewrites it, but PAM may
# not, so it cannot be assumed to survive the switch.
if [ "$(id -u)" = "0" ]; then
  if [ -n "${SYNC_SKILLS_USER:-}" ]; then
    exec su "$SYNC_SKILLS_USER" -s /bin/bash -c \
      "HOME=/home/$SYNC_SKILLS_USER /usr/local/bin/sync-project-skills"
  fi
  log "running as root with no SYNC_SKILLS_USER set; skipping"
  exit 0
fi

if ! command -v skills >/dev/null 2>&1; then
  log "skills CLI not found on PATH; skipping"
  exit 0
fi

workspace_dir=""
for candidate in /workspaces/*/; do
  [ -d "$candidate" ] && workspace_dir="${candidate%/}" && break
done
if [ -z "$workspace_dir" ]; then
  log "no /workspaces/*/ project found; skipping"
  exit 0
fi

upstream=${SYNC_SKILLS_UPSTREAM:-wesleycamargo/devcontainer-template}
read -r -a agents <<<"${SYNC_SKILLS_AGENTS:-*}"

cd "$workspace_dir" || exit 0

log_dir="${TMPDIR:-/tmp}"

# 1. Pull the latest upstream skills into this project's .agents/skills.
#    `universal`'s project path is exactly .agents/skills/, so this lands
#    upstream skills there directly without touching untracked local ones.
if skills add "$upstream" --skill '*' --agent universal -y \
    >"$log_dir/sync-project-skills.upstream.log" 2>&1; then
  log "synced upstream skills from $upstream into .agents/skills"
else
  log "WARNING: could not sync upstream skills from $upstream" \
      "(see $log_dir/sync-project-skills.upstream.log); using existing .agents/skills"
fi

if [ ! -d .agents/skills ]; then
  log "no .agents/skills in $workspace_dir; nothing to replicate"
  exit 0
fi

# 2. Replicate .agents/skills (upstream + any local custom skills) to every
#    other configured agent's project path. A literal "codex" is skipped
#    here: its project path is .agents/skills itself, already populated by
#    step 1. Left in (e.g. as part of "*") it's a harmless re-install of
#    identical content from the same source.
project_agents=()
for a in "${agents[@]}"; do
  [ "$a" = "codex" ] && continue
  project_agents+=("$a")
done
if [ "${#project_agents[@]}" -gt 0 ]; then
  if skills add . --skill '*' --agent "${project_agents[@]}" -y \
      >"$log_dir/sync-project-skills.project.log" 2>&1; then
    log "replicated .agents/skills to ${project_agents[*]} (project scope)"
  else
    log "WARNING: project-scope replication failed" \
        "(see $log_dir/sync-project-skills.project.log)"
  fi
fi

# 3. Replicate .agents/skills to every configured agent's global path, so
#    the current project's skill set is usable from any directory. Codex is
#    included here: its global path differs from its project path. A later
#    run from a different project will overwrite this with that project's
#    set -- accepted tradeoff, global always mirrors the last project synced.
if skills add . --skill '*' --agent "${agents[@]}" -g -y \
    >"$log_dir/sync-project-skills.global.log" 2>&1; then
  log "replicated .agents/skills to ${agents[*]} (global scope)"
else
  log "WARNING: global-scope replication failed" \
      "(see $log_dir/sync-project-skills.global.log)"
fi
