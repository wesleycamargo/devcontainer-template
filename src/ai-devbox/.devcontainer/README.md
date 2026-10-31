# AI Devbox

Run this devcontainer from WSL or macOS. The Dockerfile installs Python 3.12,
Node.js 24, PowerShell, GitHub CLI, Claude Code, Codex, and Hermes. Bicep is not
installed. VS Code supplies editor settings and extensions. Compose pulls the private
`ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest` image.
Authenticate Docker to GHCR before starting.
Compose runs the service as `vscode` with `HOME=/home/vscode`.

## Start

Open the project with **Dev Containers: Rebuild and Reopen in Container**, or run
these commands from the project root:

```sh
docker compose -f .devcontainer/docker-compose.yml pull
docker compose -f .devcontainer/docker-compose.yml up -d
docker compose -f .devcontainer/docker-compose.yml exec --user vscode devcontainer pwsh
```

The workspace is `/workspace`. Compose mounts this project by default. To share
the parent directory instead, set `DEVBOX_WORKSPACE_ROOT=../..`; paths are relative
to `.devcontainer/docker-compose.yml`, and VS Code will open the shared parent.

## Host configuration

Host mounts use `DEVBOX_HOST_HOME`, then `HOME`, then `/home/vscode` when both
variables are unset or empty. Override the host directory when needed:

```sh
export DEVBOX_HOST_HOME=/path/to/host-home
```

The following sources must already exist in that directory:

| Source | Type |
| --- | --- |
| `.claude` | Directory |
| `.claude.json` | File |
| `.codex/auth.json` | File |
| `.hermes` | Directory |

Prepare those paths using the agents' normal setup/login commands on the host.
Missing sources fail explicitly instead of being created as directories. Mounts
are writable so agents can refresh credentials and persist their settings. Codex
shares only authentication; its other configuration and sessions are container-local
and are recreated when the container is replaced. Codex's global `AGENTS.md`
points to the host's `.claude/CLAUDE.md`, if that file exists.

Hermes configuration stays on the host, while a separate `hermes-runtime` volume
stores its Linux dependency environments under `.hermes/installs`. Docker seeds
this volume from the prepared image, so an empty host directory does not hide the
installed dependencies or trigger a fresh download on first start.

VS Code Dev Containers [shares Git configuration and authentication](https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials)
through the host credential helper or SSH agent. With plain Compose, configure
Git inside the container:

```sh
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
gh auth login
gh auth setup-git
```

Git credential files are not copied into the container.

## Builds and updates

CI builds the Dockerfile and publishes `ai-devbox-image`. Tool versions are build
arguments in that recipe. Maintainers can build it directly:

```sh
docker build -t ai-devbox-local .devcontainer
```

Consumers update with `docker compose -f .devcontainer/docker-compose.yml pull`
and then recreate the container. Compose does not build the Dockerfile.

Hermes pins its installer and checkout to the same commit. Claude background
updates are disabled so the image controls its initial installed version; manual
updates remain available. The base image tag and APT repositories continue to
receive updates, so this is not a fully reproducible dependency snapshot.

BuildKit cache mounts cover npm and the default uv cache directory. Hermes permissions are set
in the installation layer to avoid copying its tree into a second layer.
A named volume preserves the
development user's `.cache` across container replacements. For projects with many
small files, keep the source inside the WSL filesystem rather than `/mnt/c`; mount
large dependency directories such as `node_modules` in dedicated Docker volumes
when the project needs them. Install MesloLGM Nerd Font on the host for terminal icons.

## Project skills

Templates include `.agents/skills`; startup does not install or update skills.
