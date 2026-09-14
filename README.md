# devcontainer-template

Three published dev container templates built from one shared image recipe: a
PowerShell-first devbox with the Claude Code / Codex agent CLIs and Azure
tooling, on its own or paired with an agent stack.

## Templates

| Template | What it adds | Page |
| --- | --- | --- |
| **AI Devbox** | The base: PowerShell 7, Oh My Posh, Node.js, Claude Code + Codex CLIs, Azure Bicep, GitHub CLI, esptool/mpremote | [docs/ai-devbox.md](docs/ai-devbox.md) |
| **AI Hermes Devbox** | AI Devbox + the [Hermes Agent](https://hermes-agent.nousresearch.com/) (full browser + computer-use) and an SSH gateway for Hermes Desktop | [docs/ai-hermes-devbox.md](docs/ai-hermes-devbox.md) |
| **AI OpenHands Devbox** | AI Devbox + [OpenHands Agent Canvas](https://www.openhands.dev/) via Codex ACP / ChatGPT OAuth | [docs/ai-openhands-devbox.md](docs/ai-openhands-devbox.md) |

Each page covers both install paths — command line and VS Code UI — plus first
run, persistence, and troubleshooting.

**Command line:**

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/<template-id>
```

**VS Code UI:** palette → **Dev Containers: Add Dev Container Configuration
Files** → paste one of these into the search box (the `ghcr.io/` prefix is
required, or the template isn't found):

```
ghcr.io/wesleycamargo/devcontainer-template/ai-devbox
ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox
```

## Authentication

All packages under `ghcr.io/wesleycamargo/devcontainer-template/` — the three
templates and their matching images — are **private**, so Docker has to be
logged in to `ghcr.io` before any of them will pull:

```powershell
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
```

On Windows, [`scripts/setup-devcontainer-client.ps1`](scripts/setup-devcontainer-client.ps1)
does this plus installing everything else a consumer needs (Git, GitHub CLI,
VS Code + the Dev Containers/Remote-WSL extensions, Docker Engine inside WSL, the
`devcontainer` CLI). It's idempotent — re-run it whenever the token expires.

## How the images work

Every template's `docker-compose.yml` sets `image:` to a prebuilt package and
builds nothing locally; the `Dockerfile` next to it is the recipe CI builds from
and publishes as `<template-id>-image`. Applying a template or rebuilding the
container just re-pulls that image. `ai-hermes-devbox` and `ai-openhands-devbox`
are both `FROM ai-devbox-image`, so a change to the shared recipe is made once,
in [`src/ai-devbox/.devcontainer/Dockerfile`](src/ai-devbox/.devcontainer/Dockerfile).

Docker caches `:latest`: a rebuild will not fetch a newer image on its own. Pull
it explicitly when a new `<template-id>-v*` tag is published.

## Repo setup

For working on *this repo* (the templates, the image recipes, the publish
workflows), not just consuming a published template.

### 1. Host prerequisites

Windows + WSL2 is the supported host. One script installs everything a
contributor needs — Git, GitHub CLI, VS Code + the Dev Containers/Remote-WSL
extensions, Docker Engine **inside WSL** (never Docker Desktop), the
`devcontainer` CLI — and does the [ghcr.io login](#authentication):

```powershell
./scripts/setup-devcontainer-client.ps1
```

On Linux it only checks and prints install instructions. The repo's own
devcontainer pulls the private `ai-hermes-devbox-image`, so that login has to
succeed before the container will start.

### 2. Clone and open the devcontainer

```bash
git clone https://github.com/wesleycamargo/devcontainer-template.git
cd devcontainer-template
```

Optionally pick a stable host port for the Hermes SSH gateway — create
`.devcontainer/.env` (gitignored; the container-side port is always 2222, only
the host side varies, and Hermes Desktop stores whatever you pick):

```dotenv
HERMES_SSH_PORT=2222
```

Then start it any of these ways:

- VS Code: **Dev Containers: Reopen in Container**
- `devcontainer up --workspace-folder .`
- `docker compose -f .devcontainer/docker-compose.yml up -d`

There is no build step — `docker-compose.yml` pulls the prebuilt image. A
one-shot `ssh-pubkeys` service copies `~/.ssh/*.pub` from the host into a
volume before the devcontainer starts.

### 3. Configure credentials inside the container

The container deliberately reads no host credentials; `~/.claude`, `~/.codex`
and `~/.hermes` are named volumes that survive normal rebuilds. Run once,
inside the container:

```bash
git config --global user.name "..." && git config --global user.email "..."
claude     # sign in
codex      # sign in
hermes     # API keys / connectors
```

Don't `docker compose down -v` (or delete the `claude-data`, `codex-data`,
`hermes-data` volumes) unless you mean to lose those logins. The Hermes gateway
(`127.0.0.1:8642`) and dashboard (`127.0.0.1:9119`, forwarded by VS Code) are
started automatically by the image entrypoint.

### 4. Optional: point Hermes Desktop at the container

On Windows, from the host:

```powershell
./.devcontainer/scripts/connect-hermes-desktop.ps1
```

It reads the live connection details from the running container, updates
`~/.ssh/config` and Hermes' `config.yaml`/`.env`, and verifies with a real SSH
connection. To read the details by hand:

```bash
bash .devcontainer/scripts/find-devcontainer.sh "$(pwd)" hermes-ssh-info
```

Full details and troubleshooting: [`.devcontainer/SSH-BACKEND.md`](.devcontainer/SSH-BACKEND.md).

### 5. Validation and tests

Run these on the **WSL host** where Docker runs, not inside the devcontainer:

```bash
./scripts/validate-hermes-gateway.sh build   # build the test image first
./scripts/validate-hermes-gateway.sh all     # or a single checkpoint: A..E
bash scripts/test_ai_openhands_devbox.sh     # static config checks (any shell)
```

Checkpoints A–E cover raw `docker run`, Compose, two projects at once, Dev
Container, and an image upgrade over an existing volume; F (a real Hermes
Desktop connection) is manual. CI runs the same checks via
`.github/workflows/validate-hermes-gateway.yml`.

### 6. One-time publishing setup (maintainer only)

```bash
python scripts/setup_github_publishing.py --template-id ai-devbox
```

Requires `gh` authenticated. It grants the workflows write permission, pushes,
watches the first `publish-<id>.yml` run, and confirms the published package
stayed private. After that, a push to `main` touching `src/<id>/**` bumps the
`<id>-vX.Y.Z` tag (minor by default; `[major]`/`[minor]`/`[patch]` in the commit
message overrides) and republishes the template and its image.

### Script reference

| Script                                          | Where it runs        | Purpose                                                     |
| ----------------------------------------------- | -------------------- | ----------------------------------------------------------- |
| `scripts/setup-devcontainer-client.ps1`         | Windows host         | Install prerequisites + `gh`/Docker ghcr.io login           |
| `scripts/validate-hermes-gateway.sh`            | WSL host             | Hermes SSH gateway contract checks (`build`, `A`–`E`, `all`) |
| `scripts/test_ai_openhands_devbox.sh`           | anywhere             | Static config checks for the OpenHands template             |
| `scripts/setup_github_publishing.py`            | anywhere with `gh`   | One-time GitHub publishing setup                            |
| `.devcontainer/scripts/connect-hermes-desktop.ps1` | Windows host      | Wire Hermes Desktop to the container's SSH gateway          |
| `.devcontainer/scripts/find-devcontainer.sh`    | WSL host             | Exec a command in this project's running devcontainer       |

[github.com/wesleycamargo/devcontainer-template](https://github.com/wesleycamargo/devcontainer-template)
