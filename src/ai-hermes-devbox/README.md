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

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** →
enter the full ID, including `ghcr.io/` —
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`. Without the
registry prefix the template can't be found ("Failed to fetch template
manifest").

The login has to exist where VS Code runs the devcontainer CLI. For a folder
opened in WSL that's WSL (the `docker login` above, run there). For a Windows
folder it's Windows: either `docker login` on Windows, or start VS Code with a
token for that session:

```powershell
$env:GITHUB_TOKEN = gh auth token   # token needs read:packages
code .
```

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

## Using the container as Hermes' SSH terminal backend

A Hermes running on the host (for example Hermes Desktop) can use this
container as its sandbox, sending its terminal commands in over SSH on
`127.0.0.1:2222`. Your host's `~/.ssh/*.pub` keys are authorized
automatically. See [SSH-BACKEND.md](SSH-BACKEND.md) for setup and
troubleshooting.

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

### Updating to the latest image

Docker caches `:latest`: once the image is on your machine, applying the
template or rebuilding the container **does not download a newer one**. Pull
it yourself whenever a new version is published (a new
`ai-hermes-devbox-v*` tag / **Publish ai-hermes-devbox** run), or when the
container is missing something these docs describe.

Run these where Docker runs (e.g. WSL):

1. Check whether you're behind — the two digests differ if a newer image
   exists:

   ```bash
   img=ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
   docker image inspect -f '{{index .RepoDigests 0}}' "$img"   # local
   docker buildx imagetools inspect "$img" | grep -m1 Digest    # published
   ```

2. Pull it:

   ```bash
   docker pull ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
   ```

3. Recreate the container on the new image — in VS Code, **Dev Containers:
   Rebuild Without Cache and Reopen in Container**, or with the CLI:

   ```bash
   devcontainer up --workspace-folder . --remove-existing-container --build-no-cache
   ```

The image only covers what's baked into it. If the template's
`.devcontainer/` files changed too (new services, features, or ports),
re-run `devcontainer templates apply` first — it overwrites your
`.devcontainer/` files, so redo local edits such as the
[workspace folder name](#workspace-folder-name). Named volumes (Claude, Codex,
Hermes, Open WebUI data) survive both steps.

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
