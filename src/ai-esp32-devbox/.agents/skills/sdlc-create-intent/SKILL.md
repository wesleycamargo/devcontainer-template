---
name: sdlc-create-intent
description: Turn a new software request, bug, improvement, debt item, or refactor into a scoped intent artifact before specification or design.
---

# Create intent

## Position

This is the first SDLC stage. Given an informal request, create sdlc/<work-item>/intent.md. Do not create spec.md, plan.md, tasks, or code.

## Inputs and output

- Required input: the request. Inspect repository instructions and relevant conventions when they can affect scope or constraints.
- Output: a self-contained intent artifact in a short lowercase kebab-case work-item directory. Include an external work-item ID when supplied; never require one.

## Responsibilities

Find the underlying problem or opportunity, desired outcome, included scope, non-goals, affected users, systems, or capabilities, material constraints, and measurable success indicators when appropriate. Separate requested outcomes from suggested solutions. Capture material ambiguities, assumptions, and open questions without inventing business decisions or expanding scope.

For bugs, describe actual behavior, expected behavior, and impact. For technical debt, describe the current risk or cost. For features, describe the capability and enabled outcome. For refactors, explain why it is needed and behavior that must remain unchanged.

Use only relevant sections, typically:

`markdown
# Intent: <Title>

## Problem
## Desired Outcome
## Scope
## Non-Goals
## Constraints
## Success Criteria
## Open Questions
`

Ask a question only when the answer materially changes intent. Ask through the agent's interactive question tool (Claude Code: AskUserQuestion), grouping related questions in one call, with 2-4 suggested options each, the recommended one first and labeled "(Recommended)", so the user answers with buttons; use plain text only when no such tool exists. Record a reasonable noncritical assumption instead of blocking. Do not choose a technology or architecture unless it is a confirmed constraint.

## Handoff

Request human review when appropriate. Once the intent is approved, hand off to sdlc-create-spec with the work-item path. A later change to outcome or scope requires revising this artifact before downstream work relies on it.