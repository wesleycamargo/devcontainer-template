# Framework internals

.agents/ is the canonical source for reusable agent instructions: AGENTS.md holds shared rules and skills/sdlc-*/SKILL.md holds focused capabilities. Generated work belongs in sdlc/<work-item>/, never here.

Each skill directory uses a lowercase sdlc-* name and a SKILL.md with YAML 
ame and description frontmatter followed by portable inputs, outputs, responsibilities, boundaries, and handoff instructions. Agents supporting repository-local skills can discover this directory directly. Otherwise, ask an agent to read .agents/skills/<skill-name>/SKILL.md; slash-style invocations are portable shorthand, not provider-specific behavior.

Add a skill only when an existing stage cannot own the work. Keep it focused, retain the sdlc-* prefix, and do not add mandatory artifacts or stages without need. Where an agent needs a discovery adapter, reference this directory rather than copying skill definitions. See the root README for usage.
## Cross-agent skill discovery

Create reusable project skills only in .agents/skills/<skill-name>/ — it is the single source of truth. Exposing it to individual agents (Claude Code, Codex, Hermes) is handled automatically, at container start, by the `skills` CLI (https://github.com/vercel-labs/skills, already installed in the devbox image) via `/usr/local/bin/sync-project-skills` (see src/ai-devbox/.devcontainer/scripts/sync-project-skills.sh, invoked from each template's docker-compose.yml/entrypoint.sh, not a Dev Container hook). It pulls the latest upstream skills into .agents/skills, then symlinks the merged set into every configured agent's project directory (.claude/skills, .hermes/skills; Codex's own project path is .agents/skills itself) and, for agents that need it, into their global (home-directory) skill directory too, so they work outside the project as well. Hermes is additionally configured (`hermes config set skills.external_dirs`) to read .agents/skills directly, while its personal skills remain in ~/.hermes/skills.

Run `sync-project-skills` by hand inside a container to force a refresh mid-session instead of waiting for the next restart.