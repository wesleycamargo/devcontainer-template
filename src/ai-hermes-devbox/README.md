# AI Hermes Devbox (PowerShell)

Everything in [AI Devbox](../ai-devbox/README.md) — a PowerShell-first dev
container with the Claude Code / Codex agent CLIs and Azure tooling — plus
the [Hermes Agent](https://hermes-agent.nousresearch.com/) from Nous
Research.

## What's included

- Everything from `ai-devbox`: PowerShell, Azure Bicep CLI, GitHub CLI,
  Node.js 20 with `@anthropic-ai/claude-code` and `@openai/codex`, Oh My
  Posh / Terminal-Icons.
- **Hermes Agent** (`hermes`, `hermes-agent`, `hermes-acp` on `PATH`),
  installed with the **full** option set: Playwright/Chromium for browser
  automation and the computer-use driver. Config and state live in
  `~/.hermes/`.

## Prerequisites

Same as `ai-devbox` — Docker, VS Code with the Dev Containers extension (or
the [devcontainer CLI](https://github.com/devcontainers/cli)), and
[GitHub CLI](https://cli.github.com) for authenticating to the private
package.

## Getting started

The template is published as a **private** package, so Docker needs to be
logged in to `ghcr.io` first:

```powershell
gh auth login                                      # if not already logged in
gh auth refresh -h github.com -s read:packages      # add the packages scope
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
```

Then apply the template into a project:

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** →
search for `wesleycamargo/devcontainer-template/ai-hermes-devbox`.

Then **Reopen in Container**.

## First run

Hermes is installed but not configured — `--skip-setup` skips the API-key
wizard at build time. Run `hermes` once inside the container to set up API
keys and connectors (`~/.hermes/.env`, `~/.hermes/config.yaml`).

## Configuration

### Dockerfile / Dockerfile.base

Same two-layer split as `ai-devbox`, with one difference:
`Dockerfile.base` here is **not** the full recipe — it's
`FROM ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` plus the
Hermes install step, published by `.github/workflows/publish.yml` as
`ai-hermes-devbox-image`. `Dockerfile` is thin, just `FROM` that published
image, and is what `docker-compose.yml` builds. Add your own customizations
to `Dockerfile`.

### Agent CLI credentials

`docker-compose.yml` bind-mounts `~/.claude` and `~/.codex/auth.json` from
the host, exactly as in `ai-devbox`. The paths point at the original
author's machine — edit or remove those `volumes` entries to match your own
host, or drop them if you don't need persisted agent logins. Hermes stores
its own credentials in `~/.hermes/` inside the container; add a mount for it
if you want those to survive a rebuild.

### Workspace folder name

`workspaceFolder` and the compose bind mount both hardcode
`/workspaces/devcontainer-template`. Update both to match your project's
folder name after applying the template.

## Troubleshooting

- **The image build is slow / fails on Chromium**: the full Hermes install
  pulls Playwright/Chromium and the computer-use driver. Switch to the lean
  install by adding `--skip-browser --skip-computer-use` to the
  `install.sh` line in `Dockerfile.base`.
- **Agent CLI asks you to log in again every rebuild**: check that the
  credential bind mounts in `docker-compose.yml` point at real, existing
  paths on your host.
