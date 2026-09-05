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

## Configuration

### Dockerfile / Dockerfile.base

This template builds in two layers:

- **`Dockerfile.base`** — `FROM
  ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` (the prebuilt
  base with PowerShell, Oh My Posh, Terminal-Icons, Node, and the Claude
  Code/Codex CLIs already installed) plus the Hermes install step.
  `.github/workflows/publish-ai-hermes-devbox.yml` builds this and pushes it
  as `ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`.
- **`Dockerfile`** — thin, just `FROM` that published
  `ai-hermes-devbox-image`. This is what `docker-compose.yml` actually
  builds, so applying the template and rebuilding pulls the prebuilt image
  instead of reinstalling everything from scratch.

Add your own customizations as `RUN`/`COPY` lines in `Dockerfile` — they
layer on top of the prebuilt image, so rebuilds stay fast. Editing
`Dockerfile.base` has **no effect** on a local rebuild (compose builds
`Dockerfile`); a change there only takes effect once a new
`ai-hermes-devbox-image` is published, or if you repoint `Dockerfile` /
`docker-compose.yml` to build `Dockerfile.base` directly.

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
  in `Dockerfile.base` and publish a new `ai-hermes-devbox-image` (or point
  `docker-compose.yml` at `Dockerfile.base` for a local build).
- **Agent CLI asks you to log in again every rebuild**: check that the
  credential bind mounts in `docker-compose.yml` point at real, existing
  paths on your host.
