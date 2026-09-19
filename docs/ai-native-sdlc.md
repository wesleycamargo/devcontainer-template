# AI-native SDLC framework

This repository includes a reusable, vendor-neutral framework for moving an idea through validated implementation with AI coding agents. It keeps three durable artifacts per work item: intent for **why**, specification for **what**, and plan for **how and current progress**. Code and tests are implementation deliverables; final validation is a concise outcome, not another document.

The artifacts make scope, decisions, and progress available to a new agent, so interrupted work can resume without prior conversation history. The framework is portable across languages, platforms, AI agents, IDEs, and work-item systems.

| Artifact | Fundamental question |
| --- | --- |
| intent.md | Why are we doing this? |
| spec.md | What must the system do? |
| plan.md | How will we implement it, and what is the current progress? |

### Workflow

`mermaid
flowchart TD
    request[Raw idea, bug, or request] --> intentSkill[sdlc-create-intent]
    intentSkill --> intent[intent.md]
    intent --> specSkill[sdlc-create-spec]
    specSkill --> spec[spec.md]
    intent --> planSkill[sdlc-create-plan]
    spec --> planSkill
    planSkill --> plan[plan.md]
    spec --> executeSkill[sdlc-execute-plan]
    plan --> executeSkill
    executeSkill --> implementation[Code changes and tests]
    implementation --> plan
    implementation --> validateSkill[sdlc-validate-implementation]
    intent --> validateSkill
    spec --> validateSkill
    plan --> validateSkill
    validateSkill --> passed[Passed: ready for human review]
    validateSkill --> failed[Failed or Blocked]
    failed --> executeSkill
    plan -. resume from handover .-> executeSkill
`

Review an artifact before treating it as approved, and reuse valid approved artifacts rather than repeating a stage. Skills ask only material questions and record noncritical unknowns as assumptions.

### Skill reference

| Skill | When to invoke | Input | Deliverable | Purpose of deliverable |
| --- | --- | --- | --- | --- |
| sdlc-create-intent | Starting a new feature, bug, improvement, or debt item | Initial request | intent.md | Establishes problem, outcome, scope, and constraints. |
| sdlc-create-spec | After intent approval | intent.md | spec.md | Defines behavior, requirements, and acceptance criteria. |
| sdlc-create-plan | After specification approval | Intent, spec, repository | plan.md | Defines approach, tasks, dependencies, and validation strategy. |
| sdlc-execute-plan | After plan approval or when resuming | Spec, plan, repository | Code, tests, updated plan.md | Implements requirements while tracking progress and handover. |
| sdlc-validate-implementation | After implementation needs final verification | All artifacts and repository state | Validation outcome | Independently verifies requirements and preserved behavior. |

Invoke a supported repository-local skill by name, for example /sdlc-create-intent. If an agent does not auto-discover repository skills, ask it to read .agents/skills/<skill-name>/SKILL.md first. Slash-style prompts are portable shorthand, not a provider dependency.

### Artifacts and work-item layout

`	ext
.agents/                         # How agents work: canonical instructions and skills
  AGENTS.md
  skills/sdlc-*/SKILL.md
sdlc/                        # What agents are working on: created as needed
  api-input-validation/
    intent.md
    spec.md
    plan.md
`

Use a short lowercase kebab-case work-item name: sdlc/api-input-validation/. When an external ID exists, include it: sdlc/6545-pipeline-refactoring/. Do not require an external system and do not place generated work in .agents/.

| Artifact | Primary question | Contents | Created by | Used by |
| --- | --- | --- | --- | --- |
| intent.md | Why? | Problem, outcome, scope, constraints, success criteria | sdlc-create-intent | Spec, plan, validation |
| spec.md | What? | Requirements, contracts, expected behavior, acceptance criteria | sdlc-create-spec | Plan, execution, validation |
| plan.md | How and progress? | Approach, tasks, validation strategy, statuses, handover | sdlc-create-plan | Execution, validation |

Only these three persistent SDLC artifacts are used. intent.md does not prescribe implementation; spec.md makes the outcome testable; plan.md describes technical work and tracks execution. No 	asks.md, status.md, handover file, implementation report, or validation report is needed.

### Practical workflow

For a request to reject invalid API input consistently, review each artifact before approving the next stage.

**1. Capture intent**

`	ext
/sdlc-create-intent

I want to improve input validation in our API so that invalid requests are rejected consistently before being processed.
`

This produces sdlc/api-input-validation/intent.md, documenting problem, desired outcome, scope, constraints, and material unknowns before specifying a solution.

**2. Create specification**

`	ext
/sdlc-create-spec

Create the specification for sdlc/api-input-validation/.
`

The skill reads approved intent and produces spec.md, defining observable behavior, errors, constraints, and acceptance criteria.

**3. Create implementation plan**

`	ext
/sdlc-create-plan

Create the implementation plan for sdlc/api-input-validation/.
`

The skill inspects the repository and produces plan.md with approach, executable tasks, dependencies, and validation strategy.

**4. Execute**

`	ext
/sdlc-execute-plan

Implement sdlc/api-input-validation/.
`

The skill implements the approved plan, adds or updates tests, updates task status, and maintains concise ## Handover content in plan.md.

**5. Validate**

`	ext
/sdlc-validate-implementation

Validate the implementation of sdlc/api-input-validation/.
`

Validation compares evidence against intent, specification, plan, and repository state. It reports **Passed**, **Failed**, or **Blocked**. Failed findings return to execution with actionable gaps; blocked validation states what is needed to continue.

### Revisions, handover, and resumption

- Start a new item with sdlc-create-intent.
- Revise outcome, scope, or constraints with sdlc-create-intent, then update downstream artifacts.
- Add or correct requirements with sdlc-create-spec; re-plan if implementation changes.
- Change approach or task breakdown with sdlc-create-plan; do not silently change requirements.
- Hand over or resume with sdlc-execute-plan.
- Address failed validation with sdlc-execute-plan, then validate again.
- Before a pull request or review, use sdlc-validate-implementation.

To resume:

`	ext
/sdlc-execute-plan

Resume implementation of sdlc/api-input-validation/.
`

The agent reads intent.md, spec.md, plan.md, and repository state, verifies recorded progress against code and validation evidence, then continues at the next incomplete task. Previous chat history is not required.

### Optional mapping to traditional work items

| SDLC artifact | Approximate work-item equivalent |
| --- | --- |
| intent.md | Feature |
| spec.md | User Story / Product Backlog Item |
| Tasks in plan.md | Tasks |
| Implementation | Code changes |
| Validation | Acceptance and testing |

This is conceptual rather than one-to-one. A large intent can later be split, but the default remains one work-item directory containing one intent, one specification, and one implementation plan. Internal conventions are in [.agents/README.md](.agents/README.md).

## Cross-agent skill discovery

Create reusable skills in .agents/skills/<skill-name>/. The AI Devbox template exposes that same tree to Claude Code through .claude/skills, a symlink, so additions are available immediately without copying or a watcher. AI Hermes Devbox also exposes .hermes/skills and configures Hermes to discover and create skills in .agents/skills, while preserving the user profile at ~/.hermes/skills.