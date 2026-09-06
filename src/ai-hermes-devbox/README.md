# AI Hermes Devbox (PowerShell)

A PowerShell-first dev container with the Claude Code / Codex agent CLIs and
Azure tooling preconfigured, plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) from Nous Research.

## What's included

- PowerShell (via the `powershell` devcontainer feature), set as the default
  integrated terminal, with Oh My Posh and Terminal-Icons.
- Azure Bicep CLI (`azurebicep` feature) and GitHub CLI (`gh`).
- Node.js 20, with `@anthropic-ai/claude-code` and `@openai/codex` installed
  globally.
- Codex's `AGENTS.md` symlinked to the same global agent instructions Claude
  Code reads (`~/.claude/CLAUDE.md`), so both CLIs start from one shared set
  of global guidelines instead of two copies that drift.
- **Hermes Agent** — `hermes`, `hermes-agent`, and `hermes-acp` on `PATH`,
  installed with the **full** option set: Playwright/Chromium for browser
  automation plus the computer-use driver. Config and state live in
  `~/.hermes/` (`.env`, `config.yaml`, sessions, logs, skills). Hermes brings
  its own Python 3.11 (via `uv`) and Node.js runtime, separate from the
  Node.js 20 above.

## Prerequisites

1. Docker Desktop (or another Docker Engine) running.
2. VS Code with the Dev Containers extension, **or** the
   [devcontainer CLI](https://github.com/devcontainers/cli):
   ```powershell
   npm install -g @devcontainers/cli
   ```
   (needs Node.js on the host — this installs the CLI on your machine, not
   inside the container.)
3. [GitHub CLI](https://cli.github.com) (`gh`), used below to authenticate
   to the private package:
   ```powershell
   winget install --id GitHub.cli
   ```

## Getting started

The template is published as a **private** package, so Docker needs to be
logged in to `ghcr.io` before it can pull it:

```powershell
gh auth login                                      # if not already logged in
gh auth refresh -h github.com -s read:packages      # add the packages scope
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
```

Then apply the template into a project:

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code (after the `docker login` step above): **Dev Containers: Add
Dev Container Configuration Files** → search for
`wesleycamargo/devcontainer-template/ai-hermes-devbox`.

Then **Reopen in Container**.

## First run

Hermes is installed but not configured — the image build passes
`--skip-setup` so it doesn't block on the interactive wizard. Run `hermes`
inside the container to set up API keys and connectors; it writes
`~/.hermes/.env` and `~/.hermes/config.yaml`.
The `hermes-data` Docker named volume persists that entire directory,
including credentials, sessions, memory, skills, and logs, across normal
devcontainer rebuilds. Do not remove Docker volumes (for example with
`docker compose down -v`) if you need to retain Hermes data.
After completing setup, restart the devcontainer or run
`bash .devcontainer/start-hermes.sh` to start the gateway and dashboard.

**Codex / ChatGPT shortcut.** If you sign in to Codex inside the container,
`start-hermes.sh` seeds Hermes' default from its `~/.codex/auth.json` on the
next container start: it copies those
tokens into Hermes' own auth store and sets `model.provider: openai-codex`
/ `model.default: gpt-5.6-terra` in `config.yaml` (the same import
`hermes model` → "ChatGPT or Codex Subscription" does — `hermes auth add
openai-codex` is *not* used, it only starts a fresh device-code login). It
needs a currently-valid access token in that file — Codex refresh tokens
are single-use, so Hermes won't adopt a stale pair; if the token has lapsed
the step is skipped and retried on the next start. It runs once, guarded by
`~/.hermes/.codex-default-seeded`; delete that marker (and
`hermes auth logout openai-codex`) to re-seed, or run `hermes model` to
pick a different provider — the marker keeps the seed from overriding your
choice.

## Hermes dashboard and Open WebUI

`postStartCommand` runs `.devcontainer/start-hermes.sh` on every container
start. It first runs the one-time Codex seed described under
[First run](#first-run), then generates `.devcontainer/.openwebui.env` if it
does not exist. This Git-ignored file holds randomly generated Hermes API and
Open WebUI session keys, so the credentials never enter the image or Git.

The script starts Hermes' gateway on `127.0.0.1:8642` and the dashboard on
`127.0.0.1:9119`, logging to `~/.hermes/logs/gateway.out` and
`~/.hermes/logs/dashboard.out`. The gateway is enabled with the generated
key and is never exposed to the host.

`docker-compose.yml` also starts Open WebUI as a companion container sharing
the devcontainer's network namespace. It reaches Hermes at
`http://127.0.0.1:8642/v1`, which means Hermes tool calls run inside this
devcontainer while the API stays private. Its data persists in the named
`open-webui-data` volume across normal Compose stops and rebuilds.

`devcontainer.json` forwards the Hermes dashboard on `9119` and Open WebUI
on `8080`. Open the forwarded `8080` address, create the first account (it
becomes the local admin), and select `hermes-agent` in the model picker. The
first Open WebUI start can take a little longer while it initializes.

To rotate the generated API key, delete `.devcontainer/.openwebui.env` before
rebuilding. Open WebUI persists its connection after first launch, so update
that connection through Admin Settings or reset its named data volume before
using the replacement key.

## Configuration

### The image

`docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image` — the
prebuilt image. Its `Dockerfile` (which
`.github/workflows/publish-ai-hermes-devbox.yml` builds and pushes) is
`FROM ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` (the
prebuilt base with PowerShell, Oh My Posh, Terminal-Icons, Node, and the
Claude Code/Codex CLIs) plus the Hermes install step. `docker-compose.yml`
doesn't build that `Dockerfile` — it's kept as the reference recipe.
Applying the template and rebuilding just re-pulls the image.

For your own customizations, add a second file (e.g. `Dockerfile.local`)
that does `FROM
ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`
followed by your `RUN`/`COPY` lines, and point `docker-compose.yml` at it
with a `build:` block instead of `image:` — your layers sit on top of the
prebuilt image, so rebuilds stay fast.

### Agent CLI credentials

`docker-compose.yml` uses named Docker volumes instead of host-path mounts,
so a fresh template works on any host without pre-creating credential files:

- `claude-data` — the complete `~/.claude` directory
- `codex-data` — the complete `~/.codex` directory
- `hermes-data` — the complete `~/.hermes` directory. The named volume is
  initialized from the image on first use, preserving the installed Hermes
  runtime as well as its credentials and state.

Docker creates these volumes on demand and initializes the CLI directories
from the image on first use. Log in with `claude` or `codex` inside the
container; that state survives normal rebuilds without copying credentials
into image layers. The template does not read host credentials or Git
settings, so configure Git with `git config --global ...` inside the
container when needed. Do not remove the named volumes if you need to retain
their state.

### Workspace folder name

`workspaceFolder` and the compose bind mount both hardcode
`/workspaces/devcontainer-template`. Update both to match your project's
folder name after applying the template.

## Troubleshooting

- **The image build is slow or fails on Chromium**: the full Hermes install
  pulls Playwright/Chromium and the computer-use driver. To build a lean
  image, add `--skip-browser --skip-computer-use` to the `install.sh` line
  in `Dockerfile` and publish a new `ai-hermes-devbox-image` (or point
  `docker-compose.yml` at a local `build:` of that `Dockerfile`).
- **Agent CLI asks you to log in again every rebuild**: check that the
  credential bind mounts in `docker-compose.yml` point at real, existing
  paths on your host.
