# AI Hermes Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`

[AI Devbox](ai-devbox.md) plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) (full browser +
computer-use install) and an SSH gateway a host-side Hermes Desktop can drive.

## Command line

```powershell
# Apply the public template (no registry login required)
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox

# Pick a stable SSH port
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

1. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
2. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
   ```

3. Copy `.devcontainer/.env.example` to `.devcontainer/.env` as above, then
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

- **Project skills**: files are included in `.agents/skills`; startup does not
  install or update skills.
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

### Existing Hermes data volumes

Hermes source stays in the image at `/opt/hermes/hermes-agent`. The package
manager keeps per-user dependency environments under `~/.hermes/installs`.
An existing volume can hide the environment prepared by the image; startup runs
a bounded `hermes pm repair` when the version check fails, retaining user
configuration, credentials, plugins and sessions. If repair cannot finish,
SSH remains available and startup logs explain the failure.
