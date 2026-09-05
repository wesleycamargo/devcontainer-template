# AI Devbox (PowerShell)

A PowerShell-first dev container with the Claude Code / Codex agent CLIs
preconfigured, plus Azure tooling and MicroPython/ESP flashing support.

## What's included

- PowerShell (via the `powershell` devcontainer feature), set as the default
  integrated terminal.
- Azure Bicep CLI (`azurebicep` feature) and GitHub CLI (`gh`).
- `esptool` + `mpremote` for flashing and talking to MicroPython boards, with
  the `vscode` user added to `dialout`/`plugdev` so `/dev/ttyUSB*` works
  without `sudo`.
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
4. To flash/talk to a board: pass the serial device through to Docker (e.g.
   `--device=/dev/ttyUSB0` or the Docker Desktop USB passthrough on Windows).

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

### Agent CLI credentials

`docker-compose.yml` bind-mounts `~/.claude` and `~/.codex/auth.json` from
the host so Claude Code / Codex logins survive a container rebuild, instead
of baking tokens into the image (which would leave them in `docker
history` and wouldn't pick up refreshed tokens). The paths in this
template point at the original author's machine — edit or remove those
`volumes` entries in `docker-compose.yml` to match your own host, or drop
them entirely if you don't need persisted agent logins.

### Workspace folder name

`workspaceFolder` and the compose bind mount both hardcode
`/workspaces/devcontainer-template`. Update both to match your project's
folder name after applying the template.

## Troubleshooting

- **Serial device not found / permission denied**: confirm the device is
  passed through to Docker and that its host group ownership matches
  `dialout`/`plugdev` inside the container.
- **Agent CLI asks you to log in again every rebuild**: check that the
  credential bind mounts in `docker-compose.yml` point at real, existing
  paths on your host.
