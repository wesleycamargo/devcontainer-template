# Framework internals

.agents/ is the canonical source for reusable agent instructions: AGENTS.md holds shared rules and skills/sdlc-*/SKILL.md holds focused capabilities. Generated work belongs in sdlc/<work-item>/, never here.

Each skill directory uses a lowercase sdlc-* name and a SKILL.md with YAML 
ame and description frontmatter followed by portable inputs, outputs, responsibilities, boundaries, and handoff instructions. Agents supporting repository-local skills can discover this directory directly. Otherwise, ask an agent to read .agents/skills/<skill-name>/SKILL.md; slash-style invocations are portable shorthand, not provider-specific behavior.

Add a skill only when an existing stage cannot own the work. Keep it focused, retain the sdlc-* prefix, and do not add mandatory artifacts or stages without need. Where an agent needs a discovery adapter, reference this directory rather than copying skill definitions. See the root README for usage.
## Cross-agent skill discovery

Create reusable project skills only in .agents/skills/<skill-name>/. The native discovery directories .agents/skills, .claude/skills, and .hermes/skills are directory symlinks to that location; never create or copy skills directly into those aliases. Codex and Claude writes through their native paths therefore land in .agents/skills automatically. Hermes is configured during Hermes Devbox creation with .agents/skills as both its external discovery directory and default creation directory, while its personal skills remain in ~/.hermes/skills.