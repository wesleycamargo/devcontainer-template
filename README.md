# devcontainer-template

See the [AI-native SDLC framework guide](docs/ai-native-sdlc.md) included with the AI Devbox template.

Five published dev container templates: a PowerShell-first devbox with the
Claude Code / Codex agent CLIs and Python/Node.js tooling, on its own or paired
with an agent stack.

## Templates

| Template | What it adds | Page |
| --- | --- | --- |
| **AI Devbox** | The base: PowerShell 7, Oh My Posh, Node.js, Claude Code + Codex + lean Hermes CLIs, GitHub CLI, Python 3.12, Node.js 24 | [docs/ai-devbox.md](docs/ai-devbox.md) |
| **AI ESP32 Devbox** | AI Devbox + esptool and mpremote for MicroPython | [docs/ai-esp32-devbox.md](docs/ai-esp32-devbox.md) |
| **AI Hermes Devbox** | Prebuilt official [Hermes Agent](https://hermes-agent.nousresearch.com/) with Webapp, browser + computer-use and development tools; VS Code browser access | [docs/ai-hermes-devbox.md](docs/ai-hermes-devbox.md) |
| **AI Hermes Devbox v1** | AI Devbox + the [Hermes Agent](https://hermes-agent.nousresearch.com/), gateway and dashboard only — the pre-gateway generation, no SSH, no Open WebUI | [docs/ai-hermes-devbox-v1.md](docs/ai-hermes-devbox-v1.md) |
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
ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-v1
ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox
ghcr.io/wesleycamargo/devcontainer-template/ai-esp32-devbox
```

## Authentication

The AI Devbox, AI ESP32 Devbox, AI Hermes Devbox and AI Hermes Devbox v1
templates and images are **public** under
`ghcr.io/wesleycamargo/devcontainer-template/`. Applying these templates and
pulling their images does not require GitHub or GHCR login. Publishing still
requires authenticated write access.

OpenHands has separate authentication requirements; see
[its setup guide](docs/ai-openhands-devbox.md).

On Windows, [`scripts/setup-devcontainer-client.ps1`](scripts/setup-devcontainer-client.ps1)
installs the prerequisites and also configures GitHub/GHCR authentication for
private-package access. That authentication is optional when consuming only the
public templates above.

## How the images work

Every template's `docker-compose.yml` sets `image:` to a prebuilt package and
builds nothing locally; the `Dockerfile` next to it is the recipe CI builds from
and publishes as `<template-id>-image`. Applying a template or rebuilding the
container uses that prebuilt image. `ai-hermes-devbox` instead layers its
development tools and development-shell lifecycle directly on the pinned official
`nousresearch/hermes-agent:main-desktop` image; it does not derive from
`ai-devbox-image`.

Hermes includes GitHub CLI (`gh`) in its image; common-utils and Azure Bicep
remain Dev Container features. Its entrypoint prepares state and autostarts
requested services before `sleep infinity` keeps the development shell alive;
it is not a daemon supervisor. Compose retains `init: true` and starts the
loopback gateway/Webapp by default. The dashboard requires
`HERMES_AUTOSTART_DASHBOARD=1`; `HERMES_AUTOSTART_SERVICES=0` disables both.
Bare `docker run` without the master autostart flag stays shell-only. Custom
SSH server/Desktop backend support is removed; existing installations should
follow the [migration guide](docs/ai-hermes-devbox.md#migration-from-the-ssh-enabled-devbox).

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
devcontainer pulls the public `ai-hermes-devbox-image`; registry login is not
required for it. Before first start, authenticate Codex on the Docker host so
the required credential file exists:

```bash
codex -c 'cli_auth_credentials_store="file"' login
```

### 2. Clone and open the devcontainer

```bash
git clone https://github.com/wesleycamargo/devcontainer-template.git
cd devcontainer-template
```

Then start it any of these ways:

- VS Code: **Dev Containers: Reopen in Container**
- `devcontainer up --workspace-folder .`
- `docker compose -f .devcontainer/docker-compose.yml up -d`

There is no build step — `docker-compose.yml` pulls the prebuilt image.

### 3. Credentials and persistence

The root configuration mirrors AI Hermes Devbox. Compose uses
`DEVBOX_HOST_HOME` (falling back to host `HOME`) to mount only
`~/.codex/auth.json`; it must exist before Compose starts. Claude state, Codex
configuration/history and Hermes state are per-project Docker
named volumes. See [AI Hermes Devbox](docs/ai-hermes-devbox.md) for the Webapp,
VS Code opener, shell-only mode, migration, and volume details. Gateway/Webapp
starts by default; the dashboard is opt-in. Closing the attached VS Code window
stops the Compose project (`shutdownAction: stopCompose`).

### 4. Validation and tests

Run these on the **WSL host** where Docker runs, not inside the devcontainer:

```bash
npm test && npm run check
python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
./scripts/validate-hermes-runtime.sh build   # build the test image first
./scripts/validate-hermes-runtime.sh all     # or a single checkpoint: A, B, C, D, E, G
bash scripts/test_ai_openhands_devbox.sh     # static config checks (any shell)
```

Checkpoint A checks raw image shell/tools with no listeners; B checks the default
gateway/Webapp and dashboard opt-in; C checks isolated projects sharing synthetic
Codex auth; D runs a disposable `devcontainer up` with CLI 0.90.0, actual features
and a frozen lockfile; E checks existing-volume migration; G checks Webapp HTTP
authentication. D uses `scripts/validate-hermes-devcontainer.sh`. Opening the
browser through the VS Code opener remains manual; there is no SSH checkpoint F.

Checkpoint D also requires GNU coreutils `timeout`. Its commands and each cleanup
operation have deadlines; cancellation stops the owned child process group before
cleaning only the disposable project. Positive integer overrides are seconds:

| Variable | Default |
| --- | ---: |
| `HERMES_SMOKE_INFO_TIMEOUT` | 30 |
| `HERMES_SMOKE_UP_TIMEOUT` | 900 |
| `HERMES_SMOKE_EXEC_TIMEOUT` | 180 |
| `HERMES_SMOKE_CLEANUP_TIMEOUT` | 60 per operation |
| `HERMES_SMOKE_KILL_AFTER` | 5 |

Hermes CI has one owner: `.github/workflows/publish-ai-hermes-devbox.yml` runs
preflight → runtime validation → conditional deployment. Relevant pull requests
and main updates validate; only a push to `main` changing `src/ai-hermes-devbox/**`
or a manual dispatch publishes. There is no separate Hermes validation workflow.

### 5. One-time publishing setup (maintainer only)

```bash
python scripts/setup_github_publishing.py --template-id ai-devbox
```

Requires `gh` authenticated. It grants the workflows write permission, pushes,
watches the first `publish-<id>.yml` run, and reports the published package
visibility without changing it. After that, a push to `main` touching `src/<id>/**` bumps the
`<id>-vX.Y.Z` tag (minor by default; `[major]`/`[minor]`/`[patch]` in the commit
message overrides) and republishes the template and its image.

### Script reference

| Script                                          | Where it runs        | Purpose                                                     |
| ----------------------------------------------- | -------------------- | ----------------------------------------------------------- |
| `scripts/setup-devcontainer-client.ps1`         | Windows host         | Install prerequisites + `gh`/Docker ghcr.io login           |
| `scripts/validate-hermes-runtime.sh`            | Docker host          | Hermes runtime checks (`build`, `all`, `A`, `B`, `C`, `D`, `E`, `G`) |
| `scripts/validate-hermes-devcontainer.sh`       | Docker host          | Disposable Dev Container CLI validation with real features and frozen lockfile |
| `scripts/test_ai_openhands_devbox.sh`           | anywhere             | Static config checks for the OpenHands template             |
| `scripts/setup_github_publishing.py`            | anywhere with `gh`   | One-time GitHub publishing setup                            |

[github.com/wesleycamargo/devcontainer-template](https://github.com/wesleycamargo/devcontainer-template)

## Interactive npm setup

[`devcontainer-setup-cli`](https://www.npmjs.com/package/devcontainer-setup-cli)
uses `@clack/prompts` to install Docker Engine and `@devcontainers/cli`, select
one of the published images, perform the GHCR login, and write a safe minimal
`.devcontainer/devcontainer.json` for a project:

```bash
npx devcontainer-setup-cli
```

The first prompt is a checklist: choose any combination of Docker Engine, the
Dev Container CLI, GHCR sign-in, and devcontainer configuration. Leave an item
unchecked to skip it; the default selects all four. Each selected prerequisite
is checked against the host (or the chosen WSL distribution on Windows)
before anything runs, so items already installed are reported and left alone.

On Debian/Ubuntu it can install Docker directly. On Windows it installs and
runs Docker and the Dev Container CLI inside a selected WSL distribution; it
never installs or requires Docker Desktop. Existing devcontainer configuration
is only replaced after explicit confirmation. See the [package README](https://www.npmjs.com/package/devcontainer-setup-cli) for details.

For Hermes, this CLI's minimal image-only configuration is **shell-only**; it
does not add the template's Compose autostart, credential mount, named volumes
or VS Code Webapp forwarding. Apply the full
[Hermes template](docs/ai-hermes-devbox.md) for that integrated setup.

The [`Publish package`](.github/workflows/publish.yml) workflow publishes a
scoped `@wesleycamargo/devcontainer-setup-cli` copy to GitHub Packages on
`main` and `feature/*` pushes when that version is new. A manual dispatch lets
a maintainer publish to GitHub Packages, npm, or both. Its npm path uses trusted
publishing through GitHub OIDC and provenance; it needs no `NPM_TOKEN` secret.
