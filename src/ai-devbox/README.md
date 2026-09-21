# AI Devbox (PowerShell)

A PowerShell-first dev container with the Claude Code / Codex agent CLIs
preconfigured, plus Azure tooling.

## What's included

- PowerShell (via the `powershell` devcontainer feature), set as the default
  integrated terminal.
- Azure Bicep CLI (`azurebicep` feature) and GitHub CLI (`gh`).
- Node.js 20, with `@anthropic-ai/claude-code` and `@openai/codex` installed
  globally.
- Codex's `AGENTS.md` symlinked to the same global agent instructions Claude
  Code reads (`~/.claude/CLAUDE.md`), so both CLIs start from one shared set
  of global guidelines instead of two copies that drift.

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
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-devbox
```

or in VS Code (after the `docker login` step above): **Dev Containers: Add
Dev Container Configuration Files** → search for
`wesleycamargo/devcontainer-template/ai-devbox`.

Then **Reopen in Container**.

## Configuration

### The image

`docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` — the
prebuilt image with the full recipe (PowerShell, Oh My Posh,
Terminal-Icons, Node, the Claude Code/Codex CLIs) already installed.
`.github/workflows/publish-ai-devbox.yml` builds it from the `Dockerfile`
in this directory and pushes it there. `docker-compose.yml` doesn't build
that `Dockerfile` — it's kept as the reference recipe for what's in the
image. Applying the template and rebuilding just re-pulls the image.

For your own customizations, add a second file (e.g. `Dockerfile.local`)
that does `FROM
ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` followed by
your `RUN`/`COPY` lines, and point `docker-compose.yml` at it with a
`build:` block instead of `image:` — your layers sit on top of the
prebuilt image, so rebuilds stay fast.

### Agent CLI credentials

`docker-compose.yml` bind-mounts `~/.claude` and `~/.codex/auth.json` from
the host so Claude Code / Codex logins survive a container rebuild, instead
of baking tokens into the image (which would leave them in `docker
history` and wouldn't pick up refreshed tokens). The paths in this
template point at the original author's machine — edit or remove those
`volumes` entries in `docker-compose.yml` to match your own host, or drop
them entirely if you don't need persisted agent logins.

### Workspace location

The parent directory containing the applied repository is mounted at
`/workspaces`. VS Code automatically opens
`/workspaces/<your-repository-directory-name>`, so no repository-specific path
changes are required.

## Troubleshooting

- **Agent CLI asks you to log in again every rebuild**: check that the
  credential bind mounts in `docker-compose.yml` point at real, existing
  paths on your host.

## AI-native SDLC framework

This template includes a vendor-neutral AI-native SDLC framework in .agents/. Use its five sdlc-* skills to create intent.md, spec.md, and plan.md in sdlc/<work-item>/ only when work begins. See .agents/README.md for the internal conventions and the repository [framework guide](../../docs/ai-native-sdlc.md) before applying the template.

`.agents/skills` is the single source of truth for skills — create them only there. On every container start, `sync-project-skills` (via the `skills` CLI, already installed in the image) pulls the latest upstream skills into it, then exposes the merged set to Claude Code and Codex, both inside the project and at each agent's global level so they work from any directory. Configurable via `SYNC_SKILLS_USER`/`SYNC_SKILLS_AGENTS`/`SYNC_SKILLS_UPSTREAM` in `docker-compose.yml`; run `sync-project-skills` by hand to refresh mid-session.