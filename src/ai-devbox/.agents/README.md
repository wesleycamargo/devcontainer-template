# Framework internals

.agents/ is the canonical source for reusable agent instructions: AGENTS.md holds shared rules and skills/sdlc-*/SKILL.md holds focused capabilities. Generated work belongs in sdlc/<work-item>/, never here.

Each skill directory uses a lowercase sdlc-* name and a SKILL.md with YAML 
ame and description frontmatter followed by portable inputs, outputs, responsibilities, boundaries, and handoff instructions. Agents supporting repository-local skills can discover this directory directly. Otherwise, ask an agent to read .agents/skills/<skill-name>/SKILL.md; slash-style invocations are portable shorthand, not provider-specific behavior.

Add a skill only when an existing stage cannot own the work. Keep it focused, retain the sdlc-* prefix, and do not add mandatory artifacts or stages without need. Where an agent needs a discovery adapter, reference this directory rather than copying skill definitions. See the root README for usage.
## Project skills

Create reusable project skills in `.agents/skills/<skill-name>/`. Templates include these files; container startup does not download, update, or install skills. Agents with repository-local discovery can read them directly; otherwise ask the agent to read the desired `SKILL.md`.
