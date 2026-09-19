---
name: sync-agent-skills
description: Force-create the .claude/skills (and .hermes/skills) symlinks to .agents/skills at the repo root. Use after adding, editing, or removing a skill in .agents/skills, or when a skill is missing from Claude Code or Hermes.
---

# Sync agent skills

`.agents/skills/` at the repo root is canonical. `.claude/skills` and `.hermes/skills` are directory symlinks to `../.agents/skills`, so a skill added there is visible to every agent with no copying. This skill recreates those links.

## Run

```bash
.agents/skills/sync-agent-skills/scripts/sync.sh           # create or repair the symlinks
.agents/skills/sync-agent-skills/scripts/sync.sh --check   # report drift only, exit 1 if any
.agents/skills/sync-agent-skills/scripts/sync.sh --force   # replace a real directory where a symlink belongs
.agents/skills/sync-agent-skills/scripts/sync.sh --hermes  # also manage .hermes/skills when .hermes/ is absent
```

- `.claude/skills` is always managed. `.hermes/skills` only if `.hermes/` exists or `--hermes` is passed.
- `--force` moves a conflicting real directory to `<path>.bak`, never deletes it. Without it the script stops so you can move that directory's skills into `.agents/skills/` first.
- Only the repo root is touched. No other directories are created.

## After running

- Run `--check`; it must print `already in sync`.
- Create skills only in `.agents/skills/<name>/`, never through the aliases.
- Hermes also needs its own config to discover `.agents/skills`; the symlink alone does not set that.
