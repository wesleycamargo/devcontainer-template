# AI Hermes Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`

[AI Devbox](ai-devbox.md) plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) (full browser +
computer-use install) and an SSH gateway a host-side Hermes Desktop can drive.

## Command line

```powershell
# 1. log in — the packages are private
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin

# 2. apply into your project
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox

# 3. pick a stable SSH port
cp .devcontainer/.env.example .devcontainer/.env
```

Then **Reopen in Container** and run `hermes` once inside it to set up API keys
and connectors.

Keep `HERMES_SSH_PORT` fixed once chosen — Hermes Desktop saves it in its
connection:

```dotenv
HERMES_SSH_PORT=2222
```

## VS Code UI

1. Do the `docker login` above — it must exist where VS Code runs the
   devcontainer CLI: WSL for a WSL folder, Windows for a Windows folder.
2. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
3. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
   ```

4. Copy `.devcontainer/.env.example` to `.devcontainer/.env` as above, then
   **Reopen in Container** and run `hermes` once inside it.

## Connect Hermes Desktop

```powershell
# Windows: reads the running container, writes ~/.ssh/config + Hermes config, verifies
./.devcontainer/scripts/connect-hermes-desktop.ps1
```

```bash
# or read the connection details yourself
bash .devcontainer/scripts/find-devcontainer.sh "$(pwd)" hermes-ssh-info
```

Your host's `~/.ssh/*.pub` keys are authorized automatically; private keys never
enter the container. Details and troubleshooting:
[`SSH-BACKEND.md`](../src/ai-hermes-devbox/.devcontainer/SSH-BACKEND.md).

## Fix three things after applying

`/workspaces/devcontainer-template` is hardcoded in `devcontainer.json`
(`workspaceFolder`) and twice in `docker-compose.yml` (bind mount target,
`HERMES_SSH_CWD`). Change all three to your folder name.

## What runs

| Service | Address | Notes |
| --- | --- | --- |
| SSH gateway | `127.0.0.1:${HERMES_SSH_PORT:-2222}` | Container side is always 2222, so several projects run at once |
| Hermes gateway | `127.0.0.1:8642` | Started by `hermes-start-services`; safe to rerun |
| Hermes dashboard | `127.0.0.1:9119` | Forwarded by VS Code; logs in `~/.hermes/logs/` |

## Persistence

Named volumes, created on demand: `claude-data`, `codex-data`, `hermes-data`
(credentials, config, sessions, memories, skills — Hermes' *code* lives in the
image, so a newer image really upgrades Hermes), `ssh-host-keys` (stable host
identity across recreates). `docker compose down -v` destroys all of them.

The container reads no host credentials — run `claude`, `codex` and
`git config --global …` inside it.

## Notes

- **Skills**: on every start, `entrypoint.sh` pulls the latest
  `.agents/skills` from the upstream template repo into your project (custom
  skills you've added are preserved), then installs the merged set for
  Claude Code, Codex, and Hermes — both inside the project and, so they work
  from any directory, at each agent's global/home-directory level too.
  Configurable via `SYNC_SKILLS_USER`/`SYNC_SKILLS_AGENTS`/`SYNC_SKILLS_UPSTREAM`
  in `docker-compose.yml`; run `sync-project-skills` by hand inside the
  container to refresh mid-session.
- **Codex/ChatGPT shortcut**: on start, a valid `~/.codex/auth.json` seeds
  Hermes with `model.provider: openai-codex` / `gpt-5.6-terra`. Runs once,
  guarded by `~/.hermes/.codex-default-seeded`; delete that plus
  `hermes auth logout openai-codex` to re-seed.
- **Updating**: Docker caches `:latest`, so pull explicitly, then
  `devcontainer up --workspace-folder . --remove-existing-container --build-no-cache`.
  If the template's `.devcontainer/` changed too, re-run `templates apply` first
  (it overwrites that directory — redo your edits; volumes survive).
- **Validating the gateway** (on the Docker host, not inside a devcontainer):
  `./scripts/validate-hermes-gateway.sh build` then `all` — checkpoints A–E,
  also run in CI. F (a real Hermes Desktop connection) is manual.
- **Lean image**: add `--skip-browser --skip-computer-use` to the `install.sh`
  line in the `Dockerfile` if the Chromium/computer-use build is too heavy.
- **Old `hermes-data` volumes** may still hold unused `~/.hermes/hermes-agent`
  or `~/.hermes/node`; the entrypoint flags them and leaves them alone.

Source: [`src/ai-hermes-devbox/`](../src/ai-hermes-devbox/) ·
[`Dockerfile`](../src/ai-hermes-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-hermes-devbox.yml`](../.github/workflows/publish-ai-hermes-devbox.yml) ·
[in-template README](../src/ai-hermes-devbox/README.md)
