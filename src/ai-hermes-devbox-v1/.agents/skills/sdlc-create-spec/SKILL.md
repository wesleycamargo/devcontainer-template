---
name: sdlc-create-spec
description: Convert an approved SDLC intent into a concrete, testable system specification without planning implementation work.
---

# Create specification

## Position

This stage follows an approved intent.md and creates sdlc/<work-item>/spec.md. It defines what the system must do; planning and production-code changes belong to later stages.

## Inputs and output

- Required input: approved sdlc/<work-item>/intent.md.
- Also inspect relevant repository instructions, existing behavior, interfaces, dependencies, and architecture when needed to specify a compatible change.
- Output: a self-contained, scope-preserving spec.md in the same work item.

## Responsibilities

Translate intent into clear observable functional requirements, relevant nonfunctional requirements, contracts, inputs, outputs, failure behavior, and testable acceptance criteria. Preserve existing public behavior when required. Use identifiers such as FR-1 only when they improve traceability. State security, compatibility, and operational requirements when applicable.

Repository inspection informs required behavior; it must not become a file-by-file implementation prescription. Prefer MUST, SHOULD, and MAY when they improve precision. Include positive, negative, and failure scenarios where relevant. Surface conflicts, missing requirements, and assumptions that could affect correctness.

Use only useful sections, typically:

`markdown
# Specification: <Title>

## Context
## Goals
## Non-Goals
## Functional Requirements
## Interfaces and Contracts
## Error and Failure Behavior
## Nonfunctional Requirements
## Acceptance Criteria
## Assumptions and Open Questions
`

If the intent cannot support a reliable specification, ask the question needed or return the intent for revision. Ask through the agent's interactive question tool (Claude Code: AskUserQuestion), grouping related questions in one call, with 2-4 suggested options each, the recommended one first and labeled "(Recommended)", so the user answers with buttons; use plain text only when no such tool exists. Do not generate tasks, prescribe implementation sequence, modify production code, expand scope, or create plan.md.

## Handoff

After specification review and approval, hand off the work-item path to sdlc-create-plan. Changes to requirements or acceptance criteria require revising this artifact before replanning.