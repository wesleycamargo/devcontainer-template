# AI-native SDLC framework

Use the canonical skills in .agents/skills/ in this order: sdlc-create-intent, sdlc-create-spec, sdlc-create-plan, sdlc-execute-plan, and sdlc-validate-implementation.

Persistent work-item artifacts belong only in sdlc/<work-item>/, with a short lowercase kebab-case name and an external ID when available. The only persistent artifacts are intent.md, spec.md, and plan.md.

Intent defines why, outcome, scope, non-goals, constraints, and material unknowns; it does not design. Specification defines observable, testable requirements; it does not plan. Plan defines approach, tasks, validation, and handover; it does not change code. Execution implements approved work, tests it, and tracks task status and handover only in plan.md. Validation independently reports Passed, Failed, or Blocked without creating a report file.

Do not treat existing artifacts as approved automatically. Ask only material questions, preserve approved scope and existing behavior, and record noncritical unknowns as assumptions. To resume, read spec.md, plan.md, and relevant intent.md, inspect repository state, reconcile recorded progress with evidence, and continue at the next incomplete task.

## Asking questions

When the agent has an interactive question tool (Claude Code: AskUserQuestion), use it so the user answers with buttons rather than typed text; otherwise ask in plain text. Group related questions in one call rather than asking them one by one. Give 2-4 mutually exclusive suggested options per question with a one-line consequence each, put the recommended option first and label it "(Recommended)", and rely on the tool's built-in free-text choice instead of adding an "Other" option. Record each answer in the artifact. The skills that ask questions repeat this rule inline.
