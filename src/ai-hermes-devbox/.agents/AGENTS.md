# AI-native SDLC framework

Use the canonical skills in .agents/skills/ in this order: sdlc-create-intent, sdlc-create-spec, sdlc-create-plan, sdlc-execute-plan, and sdlc-validate-implementation.

Persistent work-item artifacts belong only in sdlc/<work-item>/, with a short lowercase kebab-case name and an external ID when available. The only persistent artifacts are intent.md, spec.md, and plan.md.

Intent defines why, outcome, scope, non-goals, constraints, and material unknowns; it does not design. Specification defines observable, testable requirements; it does not plan. Plan defines approach, tasks, validation, and handover; it does not change code. Execution implements approved work, tests it, and tracks task status and handover only in plan.md. Validation independently reports Passed, Failed, or Blocked without creating a report file.

Do not treat existing artifacts as approved automatically. Ask only material questions, preserve approved scope and existing behavior, and record noncritical unknowns as assumptions. To resume, read spec.md, plan.md, and relevant intent.md, inspect repository state, reconcile recorded progress with evidence, and continue at the next incomplete task.
## Cross-agent skill discovery

Create reusable project skills only in .agents/skills/<skill-name>/. The native discovery directories .agents/skills, .claude/skills, and .hermes/skills are directory symlinks to that location; never create or copy skills directly into those aliases. Codex and Claude writes through their native paths therefore land in .agents/skills automatically. Hermes is configured during Hermes Devbox creation with .agents/skills as both its external discovery directory and default creation directory, while its personal skills remain in ~/.hermes/skills.