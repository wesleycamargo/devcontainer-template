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

## Reaching Hermes from the host

`docker-compose.yml` publishes the Hermes dashboard (`9119`) and gateway
API (`8642`) to the host, and `postStartCommand` runs
`.devcontainer/start-hermes.sh` on every container start to bring both up.
Publishing the port isn't enough on its own — Hermes binds to `127.0.0.1`
*inside the container* by default, which the published port can't reach, so
the script starts them on `0.0.0.0`. It backgrounds each service, skips one
that's already running, logs to `~/.hermes/logs/<service>.out`, and no-ops
until Hermes is configured. Each service still needs one thing set up
during `hermes` first-run:

- **Dashboard** (`http://localhost:9119` on the host) — an auth provider
  (OAuth or basic auth) under the `dashboard` key in
  `~/.hermes/config.yaml`. Binding to a non-loopback address makes Hermes
  refuse to start without one, so the service just exits and logs the error.
- **Gateway / OpenAI-compatible API** (`http://localhost:8642` on the host)
  — `API_SERVER_KEY` in `~/.hermes/.env`, required for every deployment
  since the gateway exposes the full Hermes toolset including terminal
  commands. (`API_SERVER_HOST=0.0.0.0` is passed by the script, so
  `config.yaml` doesn't need editing.)

To start them by hand instead, drop the `postStartCommand` line from
`devcontainer.json` and run `hermes dashboard --host 0.0.0.0` /
`API_SERVER_HOST=0.0.0.0 hermes gateway` yourself. Change or drop the
`ports:` entries in `docker-compose.yml` if you don't want these reachable
from the host.

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

`docker-compose.yml` bind-mounts agent config from the host so logins
survive a container rebuild, instead of baking tokens into the image (which
would leave them in `docker history` and wouldn't pick up refreshed tokens):

- `~/.claude` and `~/.claude.json` — Claude Code
- `~/.codex/auth.json` — Codex (just the credential file; the rest of
  `~/.codex` is desktop-app state)
- `~/.hermes/.env` and `~/.hermes/config.yaml` — Hermes. Only these two
  files, **not** all of `~/.hermes`: that directory also holds Hermes' own
  cloned code, its `uv` venv, and live session/log state, which must stay
  container-local. `.env` holds the API keys; drop the `config.yaml` mount
  if host and container settings need to diverge.

The paths in this template point at the original author's machine — edit or
remove those `volumes` entries in `docker-compose.yml` to match your own
host, or drop them entirely if you don't need persisted logins.

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
