## Goal

Keep the Hermes `Dockerfile` in `.devcontainer/`, replace the shell helpers with one Python file, and stop shipping the large bundled `.agents` skills tree.

## Target consumer payload

```text
.devcontainer/
  .env.example
  .gitignore
  Dockerfile
  devcontainer-lock.json
  devcontainer.json
  docker-compose.yml
  hermes_devbox.py
```

Remove:

```text
entrypoint.sh
hermes.sh
start-services.sh
webapp-open.py
scripts/configure-project-skills.sh
src/ai-hermes-devbox/.agents/
```

The root `.devcontainer/` and `src/ai-hermes-devbox/.devcontainer/` must remain identical.

---

## Approach

Create one executable, standard-library-only Python program:

```text
hermes_devbox.py
```

The Dockerfile installs it once, then creates symlinks so existing commands remain unchanged:

```text
/usr/local/bin/hermes                 -> /usr/local/lib/hermes_devbox.py
/usr/local/bin/hermes-entrypoint      -> /usr/local/lib/hermes_devbox.py
/usr/local/bin/hermes-start-services  -> /usr/local/lib/hermes_devbox.py
/usr/local/bin/hermes-webapp-open     -> /usr/local/lib/hermes_devbox.py
```

The Python program dispatches from the executable name. Users still run the same commands; they just no longer need to maintain shell scripts.

---

## Implementation steps

### 1. Confirm the current baseline

Run:

```bash
git status --short
npm test && npm run check
python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
git diff --check
```

Expected: existing tests pass. Preserve any unrelated changes.

---

### 2. Add failing payload-size tests

Update `scripts/test_hermes_template_config.py` to assert:

- `src/ai-hermes-devbox/` contains only:
  - `README.md`
  - `devcontainer-template.json`
  - the seven target `.devcontainer` files
- root `.devcontainer/` contains exactly the same seven files.
- `src/ai-hermes-devbox/.agents/` does not exist.
- neither copy of `scripts/configure-project-skills.sh` exists.
- `scripts/sync-template-agents.sh` contains:

```bash
templates=(ai-devbox ai-esp32-devbox)
```

and does not mention:

```text
ai-hermes-devbox
configure-project-skills
```

Run the focused test first:

```bash
python3 -B -m unittest scripts.test_hermes_template_config -v
```

Expected initially: failure because the old scripts, hook, and `.agents` tree still exist.

---

### 3. Add failing Python-runtime tests

Create `scripts/test_hermes_devbox.py`.

It should import only the canonical future file:

```text
src/ai-hermes-devbox/.devcontainer/hermes_devbox.py
```

Test these public behaviors before writing the implementation:

1. **Command dispatch**
   - `hermes-entrypoint` selects entrypoint behavior.
   - `hermes` selects the official-runtime wrapper.
   - `hermes-start-services` selects service startup.
   - `hermes-webapp-open` selects VS Code Webapp opening.
   - Unknown executable names fail.

2. **Hermes wrapper**
   - Root calls re-exec as user `hermes`.
   - Non-root sets the existing Hermes environment defaults.
   - It executes `/opt/hermes/.venv/bin/hermes` with unchanged arguments.

3. **Entrypoint**
   - Creates required Hermes data folders.
   - Preserves existing persistent Hermes data.
   - Seeds `.env` only when absent.
   - Runs services only when `HERMES_AUTOSTART_SERVICES=1`.
   - Keeps the development shell available if preflight or service startup fails.
   - Runs `sleep infinity` as `hermes`.
   - Does not invoke SSH or Docker socket behavior.

4. **Service startup**
   - Imports Codex tokens only when needed.
   - Preserves an existing provider, login, and chosen model.
   - Adds only missing local Webapp defaults.
   - Starts gateway from the sole `/workspaces/*` project directory.
   - Starts dashboard only when `HERMES_AUTOSTART_DASHBOARD=1`.
   - Does not duplicate or kill existing services.

5. **Webapp opener**
   - Retain all existing security tests:
     - loopback-only URL;
     - authenticated API readiness;
     - no ticket in logs/errors;
     - current VS Code window IPC;
     - no browser open on invalid responses.

Run:

```bash
python3 -B -m unittest scripts.test_hermes_devbox -v
```

Expected initially: failure because `hermes_devbox.py` does not exist.

---

### 4. Implement `hermes_devbox.py`

Create this file in both mirrored directories:

```text
src/ai-hermes-devbox/.devcontainer/hermes_devbox.py
.devcontainer/hermes_devbox.py
```

Use only Python standard library modules.

Keep separate functions inside the one file:

```python
def dispatch_for(program_name): ...
def runtime_environment(environ=None): ...
def run_hermes(args): ...
def entrypoint(args): ...
def seed_codex_default_model(home): ...
def ensure_webapp_defaults(home): ...
def select_workspace(): ...
def process_running(pattern): ...
def start_services(): ...
def open_webapp(): ...
def main(argv=None, program_name=None): ...
```

Important implementation rules:

- Do not use `bash -c`, `source`, `eval`, or constructed shell commands.
- Use `subprocess.run([...])`, `subprocess.Popen([...])`, `os.execvp`, and `os.execvpe` with argument lists.
- Preserve the current runtime paths:
  - `/opt/hermes`
  - `/opt/hermes/.venv/bin/python`
  - `/opt/hermes/.venv/bin/hermes`
  - `/home/hermes/.hermes`
- Preserve root-to-`hermes` privilege dropping.
- Preserve existing gateway and dashboard process regexes.
- Preserve `hermes webapp --no-open` parsing and VS Code Unix-socket IPC behavior.
- Never print the Webapp ticket or credential content.

Run:

```bash
python3 -B -m unittest scripts.test_hermes_devbox -v
python3 -m py_compile src/ai-hermes-devbox/.devcontainer/hermes_devbox.py
cmp -s src/ai-hermes-devbox/.devcontainer/hermes_devbox.py .devcontainer/hermes_devbox.py
```

Expected: tests pass, Python compiles, and both copies match.

---

### 5. Update the Dockerfile

In both mirrored Dockerfiles, replace all four helper-file `COPY` instructions and shell syntax checks with:

```dockerfile
COPY --chmod=755 hermes_devbox.py /usr/local/lib/hermes_devbox.py
RUN ln -sf /usr/local/lib/hermes_devbox.py /usr/local/bin/hermes \
    && ln -sf /usr/local/lib/hermes_devbox.py /usr/local/bin/hermes-entrypoint \
    && ln -sf /usr/local/lib/hermes_devbox.py /usr/local/bin/hermes-start-services \
    && ln -sf /usr/local/lib/hermes_devbox.py /usr/local/bin/hermes-webapp-open \
    && /opt/hermes/.venv/bin/python -m py_compile /usr/local/lib/hermes_devbox.py

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]
CMD ["sleep", "infinity"]
```

Keep the existing image preflight checks for:

- Hermes
- Webapp build
- Claude
- Codex
- GitHub CLI
- PowerShell/Terminal Icons
- Node

Then delete the old helper sources from both mirrored `.devcontainer` directories.

---

### 6. Move existing tests instead of losing coverage

Update these test modules:

```text
scripts/test_hermes_auth.py
scripts/test_hermes_dashboard_startup.py
scripts/test_hermes_no_ssh.py
scripts/test_hermes_service_processes.py
scripts/test_hermes_webapp_open.py
```

Preferred approach:

- Move their behavior tests into `scripts/test_hermes_devbox.py`.
- Keep their existing behavior assertions.
- Delete a former test file only after its coverage is fully present in the new Python-runtime test file.
- Keep real-process launcher matching in `test_hermes_service_processes.py`, but import regex constants from Python instead of parsing shell text.

Run:

```bash
python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
git diff --check
```

Expected: all Hermes tests pass.

Suggested commit:

```bash
git add -p -- .devcontainer src/ai-hermes-devbox/.devcontainer scripts/test_hermes_*.py
git commit -m "refactor(hermes): replace runtime shell helpers with Python"
```

---

### 7. Remove bundled skills and unused hook

Delete:

```text
src/ai-hermes-devbox/.agents/
.devcontainer/scripts/configure-project-skills.sh
src/ai-hermes-devbox/.devcontainer/scripts/configure-project-skills.sh
```

Before deleting `.agents`, check for untracked work:

```bash
git status --short -- src/ai-hermes-devbox/.agents
```

If it shows user-created files, stop and coordinate.

Update `scripts/sync-template-agents.sh`:

```bash
templates=(ai-devbox ai-esp32-devbox)
```

Delete the Hermes-hook mirroring variable and block.

Run:

```bash
bash -n scripts/sync-template-agents.sh
python3 -B -m unittest scripts.test_hermes_template_config -v
command -v rsync && bash scripts/sync-template-agents.sh --check
```

Expected: tests pass and the remaining template payloads are in sync.

Suggested commit:

```bash
git add -u -- src/ai-hermes-devbox/.agents .devcontainer src/ai-hermes-devbox/.devcontainer
git add scripts/sync-template-agents.sh scripts/test_hermes_template_config.py
git commit -m "refactor(hermes): stop shipping bundled project skills"
```

---

### 8. Update documentation

Update:

```text
AGENTS.md
README.md
docs/ai-hermes-devbox.md
docs/ai-native-sdlc.md
src/ai-hermes-devbox/README.md
src/ai-hermes-devbox/devcontainer-template.json
```

Document:

- The template keeps its Dockerfile.
- Runtime behavior now lives in one Python helper.
- Existing commands remain:
  - `hermes`
  - `hermes-start-services`
  - `hermes-webapp-open`
- Fresh templates no longer include `.agents/` skills.
- Existing projects are not cleaned automatically when reapplying a template.
- Users should manually compare and remove old `.sh`, `webapp-open.py`, and bundled `.agents` files only if they are unmodified.

Remove stale live references to deleted files:

```bash
git grep -nE 'configure-project-skills|entrypoint\.sh|hermes\.sh|start-services\.sh|webapp-open\.py|src/ai-hermes-devbox/\.agents' -- \
  README.md AGENTS.md docs src/ai-hermes-devbox scripts .github .devcontainer
```

Only intentional migration text may still mention old filenames.

---

### 9. Full validation

Run:

```bash
npm test && npm run check
python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
python3 -m py_compile .devcontainer/hermes_devbox.py
python3 -m py_compile src/ai-hermes-devbox/.devcontainer/hermes_devbox.py
bash -n scripts/validate-hermes-runtime.sh
bash -n scripts/validate-hermes-devcontainer.sh
bash -n scripts/sync-template-agents.sh
actionlint .github/workflows/publish-ai-hermes-devbox.yml
git diff --check
```

On a Docker-capable host:

```bash
bash scripts/validate-hermes-runtime.sh build
BUILDX_BUILDER=default bash scripts/validate-hermes-runtime.sh all
```

Expected final runtime output:

```text
PASS: requested Hermes runtime checkpoints completed
```

This must include the real disposable Dev Container smoke test, protected Webapp check, default-off dashboard check, no-SSH check, and cleanup verification.

---

### 10. Post-release payload verification

Only after an explicitly authorized release, apply the exact published template into an empty scratch project and verify it produces exactly these seven files:

```text
.devcontainer/.env.example
.devcontainer/.gitignore
.devcontainer/Dockerfile
.devcontainer/devcontainer-lock.json
.devcontainer/devcontainer.json
.devcontainer/docker-compose.yml
.devcontainer/hermes_devbox.py
```

Do not dispatch publication merely to test this.

---

## Risks and tradeoffs

- One Python file is easier to maintain than three shell files plus a separate Python file, but it centralizes security-sensitive runtime behavior. Keep functions small and tests focused.
- This is intentionally a **seven-file** payload, not the prior five-file concept: the Dockerfile stays because that is your preference.
- Existing consumer projects keep old files after reapplying a template; automatic deletion would risk removing user changes.
- Unit tests are not enough. Docker runtime validation remains mandatory.
- No publishing, pushing, tag changes, or workflow dispatch should happen without explicit approval.

## Execution status

The user explicitly approved this standalone plan. No accompanying specification exists; the behavior and acceptance criteria in this plan define the approved scope.

- Task 1: completed — baseline npm tests/check pass; 105 of 106 Python tests pass. The existing validator-mode assertion fails on this environment (0777 in the primary checkout, 0775 in the new worktree versus required 0755).
- Tasks 2–7: completed — exact payload tests observed RED before implementation; runtime consolidated with migrated behavior/security coverage; both mirrors contain exactly seven source files. Skills/hook removed only after confirming no user changes. Implementation isolated on branch `refactor/hermes-python-runtime` at `/home/hermes/.hermes/cache/scratch/hermes-python-runtime`; primary checkout remains unchanged.
- Task 8: completed — all six documentation/metadata files updated and diff reviewed; version unchanged, migration preserves modified/user-created files.
- Task 9: blocked — npm tests (10), npm check, all 125 Hermes Python tests, both helper compilations, mirror comparison, shell syntax, actionlint v1.7.12 and whitespace checks pass. Remaining skill trees are byte-identical (29 files each); worktree-only timestamps aligned so sync `--check` also passes. Local validator permissions normalized to 0755 without changing Git's executable mode. Both actual `build` and `all` commands fail at Docker daemon connection; Buildx is also unavailable. Real Docker validation is blocked in this environment. Initial independent review found a dangling `.env` symlink write regression; fixed using a fresh temporary file descriptor and atomic replacement, with RED/GREEN tests for both mirrors. Independent re-review passed with no security or logic findings; 39 runtime tests and 12 additional success/failure-cleanup probes passed. This does not replace mandatory Docker runtime acceptance.
- Task 10: pending — intentionally deferred until an explicitly authorized release.

Required integration adjustment: replace CI preflight references to removed shell scripts with Python compilation and cover the change with a regression test.

## Handover

Current: Task 9 — reviewed changes transferred at the user's request to `/workspaces/devcontainer-template` on `refactor/hermes-python-runtime`; scratch worktree retained as a detached backup. The 39 runtime tests, npm check and whitespace check pass in the primary checkout. Exact-payload tests encounter pre-existing ignored `.openwebui.env` and stale Python cache files, which were preserved without reading their contents. Full 125-test success above was measured in the clean isolated worktree; Docker runtime acceptance remains blocked.
Next: Review changes in the primary checkout. Resolve ignored local payload artifacts without deleting user data, then run build/all on a Docker-capable host before final acceptance. Changes remain uncommitted.
Blockers: Docker daemon unavailable and Buildx missing; no publication authorized.
Remaining validation: Docker build and all runtime checkpoints; post-release payload application only after authorized release.