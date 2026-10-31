---
name: sdlc-create-plan
description: Turn an approved SDLC specification into a proportional, executable implementation plan with tasks, validation, and handover.
---

# Create implementation plan

## Position

This stage follows approved intent and specification artifacts. It creates sdlc/<work-item>/plan.md, combining implementation strategy and executable tasks; do not create a separate task artifact or modify production code.

## Inputs and output

- Required inputs: approved intent.md and spec.md in one work-item directory.
- Also inspect the repository, relevant instructions, current implementation, interfaces, dependencies, and engineering conventions.
- Output: self-contained plan.md in the same work-item directory.

## Responsibilities

Choose an approach consistent with the repository. Identify affected components and material compatibility, migration, security, operational, and dependency concerns. Break only required approved-scope work into dependency-ordered, independently verifiable tasks. Keep the plan proportional.

Each task has a clear objective, meaningful work checklist, dependencies when applicable, validation criteria, and initial Status: pending. Include testing strategy and a concise resumable handover. Use this shape when useful:

`markdown
# Implementation Plan: <Title>

## Approach
## Affected Components
## Implementation Tasks

### Task 1 — <Title>
Status: pending

- [ ] Implementation step
- [ ] Test or validation

Validation:
- Expected completion criteria.

## Risks and Dependencies
## Final Validation
## Handover

Current: Not started
Next: Task 1
Blockers: None
`

If planning exposes a genuine specification gap, report it for specification revision rather than silently changing requirements. Do not add unrelated refactoring, new functionality, or tasks.md, and do not edit code. Ask only about a material approach choice the specification leaves open, otherwise record an assumption. Ask through the agent's interactive question tool (Claude Code: AskUserQuestion), grouping related questions in one call, with 2-4 suggested options each, the recommended one first and labeled "(Recommended)", so the user answers with buttons; use plain text only when no such tool exists.

## Handoff

After plan approval, hand off to sdlc-execute-plan. Revise plan.md for a material approach or task change; return to specification (and intent when outcome or scope changes) when requirements change.