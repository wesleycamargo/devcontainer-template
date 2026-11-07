# Implementation Plan: AI Hermes Devbox GitHub Skills Tap

## Scope

Add a public skills-tap bootstrap to **AI Hermes Devbox only**. A new `hermes-data` volume registers `wesleycamargo/skills` and `mattpocock/skills`, then installs:

- `sdlc-create-intent`
- `sdlc-create-spec`
- `sdlc-create-plan`
- `sdlc-execute-plan`
- `sdlc-validate-implementation`
- `write-for-me`
- `wayfinder`
- `code-review`
- `codebase-design`
- `diagnosing-bugs`
- `grill-with-docs`
- `improve-codebase-architecture`
- `prototype`
- `research`
- `wizard`
- `handoff`
- `wait-what`
- `teach`

Do not modify other templates, ship a bundled `.agents` tree, publish images, push branches, or change the skills repository.

## Approach

Add non-secret Compose environment inputs for an ordered public-tap list and source-qualified, comma-separated baseline skills. Extend the image-owned Python entrypoint to validate them, run noninteractive `hermes skills tap add` plus `hermes skills install --yes`, and persist an atomic marker in `~/.hermes` only after all installs succeed. Registering `mattpocock/skills` satisfies the requested tap subscription, but its selected skills must use direct repo-relative install paths because its catalog is grouped below `skills/engineering/` and `skills/productivity/`; default tap discovery is not recursive.

The marker contains the normalized tap list and requested source-qualified skill list. This prevents duplicate work across normal container recreation, but permits a deliberately changed configuration to bootstrap again. Bootstrap must never call `hermes skills update`, use `--force`, or overwrite user-modified skills. It must warn and leave the shell available if GitHub or a catalog is unavailable.

The current public `wesleycamargo/skills` repository uses the compatible `skills/<name>/SKILL.md` layout and contains the SDLC/write-for-me set. The public `mattpocock/skills` repository has the requested engineering/productivity skills, including `skills/productivity/teach/SKILL.md`.

## Affected components

- `src/ai-hermes-devbox/.devcontainer/.env.example`
- `src/ai-hermes-devbox/.devcontainer/docker-compose.yml`
- `src/ai-hermes-devbox/.devcontainer/hermes_devbox.py`
- Matching root `.devcontainer/` files
- `scripts/test_hermes_devbox.py`
- `scripts/test_hermes_template_config.py`
- `docs/ai-hermes-devbox.md`
- `src/ai-hermes-devbox/README.md`

## Implementation Tasks

### Task 1 — Consumer configuration
Status: pending

- [ ] Add these defaults to both `.env.example` files:

  ```dotenv
  HERMES_SKILLS_TAPS=wesleycamargo/skills,mattpocock/skills
  HERMES_SKILLS_INSTALL=wesleycamargo/skills/sdlc-create-intent,wesleycamargo/skills/sdlc-create-spec,wesleycamargo/skills/sdlc-create-plan,wesleycamargo/skills/sdlc-execute-plan,wesleycamargo/skills/sdlc-validate-implementation,wesleycamargo/skills/write-for-me,mattpocock/skills/skills/engineering/wayfinder,mattpocock/skills/skills/engineering/code-review,mattpocock/skills/skills/engineering/codebase-design,mattpocock/skills/skills/engineering/diagnosing-bugs,mattpocock/skills/skills/engineering/grill-with-docs,mattpocock/skills/skills/engineering/improve-codebase-architecture,mattpocock/skills/skills/engineering/prototype,mattpocock/skills/skills/engineering/research,mattpocock/skills/skills/engineering/wizard,mattpocock/skills/skills/productivity/handoff,mattpocock/skills/skills/productivity/wait-what,mattpocock/skills/skills/productivity/teach
  ```

- [ ] Document that the values are public/non-secret, and a blank install list disables new-volume installation.
- [ ] Pass both values through each Compose `environment:` mapping using the established interpolation style.
- [ ] Keep root and canonical template files byte-identical.

Validation:

```bash
docker compose -f src/ai-hermes-devbox/.devcontainer/docker-compose.yml \
  --env-file src/ai-hermes-devbox/.devcontainer/.env.example config
```

### Task 2 — RED tests
Status: in-progress

- [ ] Add isolated filesystem/subprocess tests to `scripts/test_hermes_devbox.py`.
- [ ] Prove first startup adds both taps in configured order and installs only the 18 source-qualified skills in deterministic order.
- [ ] Prove matching marker/configuration produces no tap, install, or update call on later startup.
- [ ] Prove a blank list does nothing.
- [ ] Reject malformed tap identifiers, malformed repo-relative skill identifiers, duplicate names, unknown sources, and whitespace-only values.
- [ ] Prove a failed CLI command writes no success marker and does not break entrypoint shell availability.
- [ ] Prove a changed repository or requested list is not hidden by an old marker.
- [ ] Extend static tests to require matching Compose passthrough/defaults in both mirrors.

Run:

```bash
python3 -B -m unittest scripts.test_hermes_devbox scripts.test_hermes_template_config -v
```

Expected before implementation: new bootstrap tests fail.

### Task 3 — Safe bootstrap implementation
Status: pending

- [ ] Add focused Python helpers such as `parse_skills_bootstrap`, `skills_bootstrap_marker`, and `bootstrap_skills`.
- [ ] Require strict `owner/repository` tap and repo-relative install identifiers (including nested `skills/<category>/<skill>` paths); reject URLs, traversal, shell fragments, empty parts, unsupported characters, and requested skills whose source is not a configured tap.
- [ ] Parse the two comma-separated lists, trim safely, reject duplicates, and retain requested order.
- [ ] Invoke only argument arrays, as user `hermes`, with the current runtime environment:

  ```text
  hermes skills tap add <owner/repository>
  hermes skills install <owner/repository>/<repo-relative-skill-path> --yes
  ```

- [ ] Write the marker atomically only after all installations succeed.
- [ ] Make failure retry-safe and non-fatal; continue normal startup.
- [ ] Invoke bootstrap during entrypoint preparation, before optional services, so shell-only and standard modes match.
- [ ] Mirror the helper exactly to root `.devcontainer/`.

Validation:

```bash
python3 -B -m unittest scripts.test_hermes_devbox -v
python3 -m py_compile src/ai-hermes-devbox/.devcontainer/hermes_devbox.py
cmp -s src/ai-hermes-devbox/.devcontainer/hermes_devbox.py .devcontainer/hermes_devbox.py
```

### Task 4 — Runtime and volume validation
Status: pending

- [ ] Extend the existing runtime validation flow with a disposable skills-bootstrap checkpoint.
- [ ] Verify a fresh volume registers both taps and installs exactly 18 skills.
- [ ] Verify the 12 Matt Pocock installs use the exact nested `skills/engineering/` or `skills/productivity/` paths, rather than assuming default-tap discovery scans recursively.
- [ ] Recreate with the same volume and verify no repeated install/update.
- [ ] Change the disposable list and prove the new configuration is attempted without deleting existing skills.
- [ ] Verify network/catalog failure leaves `sleep infinity` and the shell usable.
- [ ] Keep fixtures independent of user state, tokens, and personal skills.

On a Docker-capable host:

```bash
bash scripts/validate-hermes-runtime.sh build
BUILDX_BUILDER=default bash scripts/validate-hermes-runtime.sh all
```

### Task 5 — Documentation
Status: pending

- [ ] Document the new-volume two-tap bootstrap and all 18 baseline skills, identifying which source owns each skill.
- [ ] Document customising or disabling the list in `.devcontainer/.env`.
- [ ] Document deliberate updates only:

  ```bash
  hermes skills check
  hermes skills update
  hermes skills update <name>
  ```

- [ ] Document quick publishing from an installed copy:

  ```bash
  hermes skills publish ~/.hermes/skills/<name> --to github --repo wesleycamargo/skills
  ```

  Recommend normal Git branches and pull requests in `wesleycamargo/skills` for reviewed or multi-skill work.
- [ ] State that both tap registrations, installed copies, and marker persist in project-scoped `hermes-data`; removing the volume resets them.
- [ ] Preserve the current promise of no bundled project `.agents` tree or automatic project-skill setup.

### Task 6 — Full validation
Status: pending

- [ ] Run focused Python tests while implementing.
- [ ] Run:

  ```bash
  npm test
  npm run check
  python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
  git diff --check
  ```

- [ ] Run Compose/mirror checks and Docker runtime validation separately. Do not claim Docker validation from static checks.

## Risks and dependencies

- Depends on public GitHub access plus the `wesleycamargo/skills` and `mattpocock/skills` catalog layouts.
- Existing volumes must not silently receive changed skills after an image update; manual `hermes skills update` remains the upgrade path.
- This first version excludes private repositories and all other devcontainer variants.

## Final Validation

1. Start AI Hermes Devbox with a fresh disposable `hermes-data` volume.
2. Verify both tap registrations and all 18 named installed skills.
3. Recreate against the same volume; verify no installation/update reruns.
4. Verify blank configuration and upstream failure retain a usable shell and no success marker.
5. Verify mirror equality and the published seven-file payload contract.

## Handover

Current: Task 2 — a first RED/GREEN slice now proves a fresh volume registers both taps and installs all 18 requested skills through non-shell, noninteractive commands.

Next: Add the remaining failure/idempotency/input-validation tests before wiring bootstrap into the entrypoint and Compose configuration.

Blocker: Docker runtime acceptance needs a Docker-capable host.
