---
name: sdlc-execute-plan
description: Implement or resume an approved SDLC plan while updating tests, task progress, and concise handover in the plan artifact.
---

# Execute implementation plan

## Position

This stage implements approved requirements after planning and is also the resume entry point. Its outputs are repository changes, relevant tests, and progress maintained only in sdlc/<work-item>/plan.md.

## Inputs and output

- Required inputs: approved spec.md and plan.md; read intent.md when context helps preserve outcome or scope.
- Inspect repository instructions, current state, existing behavior, and available validation evidence before changing code.
- Output: implementation and tests plus an updated existing plan.md. Do not create status, handover, implementation, or validation-report artifacts.

## Execution and resume

Determine whether work is new or resumed. On resume, read task statuses and handover, inspect the actual repository, and reconcile discrepancies before continuing. Execute tasks in dependency order, preserve required behavior, and follow existing conventions. Test meaningful milestones and never mark work complete without its defined validation evidence.

Use only pending, in-progress, completed, and locked statuses. Update checklists, validation notes, and this concise section after meaningful milestones, status changes, material validation results, blockers, deviations, or decisions affecting later work:

`markdown
## Handover

Current: Task 3 — <Title>
Next: <next concrete action>
Blockers: None
Remaining validation: <pending evidence>
`

Do not log routine commands or duplicate Git history. Do not overwrite another agent work. Distinguish required current-scope work from optional improvements, technical debt, and future follow-up. Add only required work that does not change approved requirements; record significant deviations. Return for artifact review when a discovery changes scope or specification.

## Handoff

When implementation tasks are completed with task-level validation, hand off to sdlc-validate-implementation. Completion here is not a claim that final independent validation passed.