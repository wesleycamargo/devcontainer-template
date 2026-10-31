# AI Hermes Devbox (PowerShell)

A PowerShell-first dev container with the Claude Code / Codex agent CLIs and
Azure tooling preconfigured, plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) from Nous Research.

## What's included

- PowerShell installed in the image, set as the default
  integrated terminal, with Oh My Posh and Terminal-Icons.
- Azure Bicep CLI (`azurebicep` feature) and GitHub CLI (`gh`).
- The official Hermes Node.js runtime, native Claude Code and the Codex CLI.
- Codex's `AGENTS.md` symlinked to the same global agent instructions Claude
  Code reads (`~/.claude/CLAUDE.md`), so both CLIs start from one shared set
  of global guidelines instead of two copies that drift.
- **Hermes Agent** — `hermes`, `hermes-agent` and `hermes-acp` on `PATH`, with the official
  `main-desktop` image's prebuilt Webapp, Chromium and computer-use stack.
  Config and state live in `~/.hermes/` (`.env`, `config.yaml`, sessions, logs,
  skills). Python and Node.js come prepared in the upstream image.

## Prerequisites

1. Docker Engine running (inside WSL2 on Windows).
2. VS Code with the Dev Containers extension, **or** the
   [devcontainer CLI](https://github.com/devcontainers/cli):
   ```powershell
   npm install -g @devcontainers/cli
   ```
   (needs Node.js on the host — this installs the CLI on your machine, not
   inside the container.)

## Getting started

The template and image are **public**. Apply directly; registry login is not required.

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** →
enter the full ID, including `ghcr.io/` —
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`. Without the
registry prefix the template can't be found ("Failed to fetch template
manifest").

Then **Reopen in Container**.

## First run

The Webapp starts automatically. Run `hermes-webapp-open` in the devcontainer's
VS Code terminal to open it already signed in. Model credentials and connectors
still need your account setup; run `hermes` when ready to configure them.

The `hermes-data` Docker named volume persists that directory across normal
rebuilds. It holds credentials, config, sessions, logs, memories, skills, and
per-user dependency environments. Hermes source lives in the image under
`/opt/hermes`, so pulling a newer image updates the source. Do not remove Docker volumes, for example with
`docker compose down -v`, if you need to retain Hermes data.

If an existing volume came from an older image, it may still contain
`~/.hermes/hermes-agent` or `~/.hermes/node`. The entrypoint leaves those files
alone and prints cleanup guidance in `docker compose logs devcontainer`; they
are no longer used by the active `hermes` executable.

**Codex / ChatGPT shortcut.** On container start, `hermes-start-services` seeds
Hermes' default from `~/.codex/auth.json` when that file contains a currently
valid ChatGPT/Codex OAuth token. It copies those tokens into Hermes' auth store
and sets `model.provider: openai-codex` / `model.default: gpt-5.6-terra` in
`config.yaml`, matching the import path behind `hermes model` -> "ChatGPT or
Codex Subscription". It does not run `hermes auth add openai-codex`, which
starts a fresh device-code login.

The seed runs once, guarded by `~/.hermes/.codex-default-seeded`; delete that
marker plus `hermes auth logout openai-codex` to re-seed. If the Codex access
token has expired, the step is skipped and retried on the next start.

## Gateway validation

The SSH gateway contract is checked by
`scripts/validate-hermes-gateway.sh`. Run it on the Docker host, not from
inside a devcontainer:

```bash
./scripts/validate-hermes-gateway.sh build
./scripts/validate-hermes-gateway.sh all
```

The build uses the public official Hermes image, pinned by digest.
Checkpoints A-E cover
raw Docker startup, Compose, concurrent projects, the Dev Container manifest,
and migration from the old Hermes data-volume layout. GitHub Actions runs them
for relevant pull requests and main-branch changes; publishing the Hermes image
also waits for the same checks to pass. Checkpoint G covers the prebuilt Webapp,
local isolation and optional remote password login. CI shares a Buildx layer
cache between validation and publication.

Checkpoint F is optional for browser users and intentionally manual: enable
`docker-compose.ssh.yml`, run `hermes-ssh-info` against the real
Compose project, add its alias to the Windows SSH config, then confirm Hermes
Desktop can execute a terminal action through it. See
[SSH-BACKEND.md](.devcontainer/SSH-BACKEND.md).

## Hermes dashboard

SSH and the optional Hermes services are owned by the image entrypoint, so they
behave the same under `docker run`, `docker compose`, and VS Code Dev
Containers. Compose sets `HERMES_AUTOSTART_SERVICES=1`, which makes the
entrypoint run `hermes-start-services` as `hermes` after SSH setup. A bare
`docker run` leaves that variable unset and starts only the SSH daemon.

`hermes-start-services` starts the Hermes gateway with its Webapp on
`127.0.0.1:9120` by default and the
dashboard on `127.0.0.1:9119`, logging to `~/.hermes/logs/gateway.out` and
`~/.hermes/logs/dashboard.out`. It is safe to rerun; existing gateway and
dashboard processes are reused. `devcontainer.json` forwards both ports locally;
Compose publishes neither.

## Webapp in VS Code

The image reuses `nousresearch/hermes-agent:main-desktop`, pinned to the
multi-arch digest `sha256:cef6ca13cc35452215c5774c0563b0940b0a6ebaebad0d87174b27ca3d5c93d5`
(commit `c419cf7c864ac0ee511dbd9f7091a8bba0b567ee`, after v0.22.5).
Hermes and Webapp are already built upstream; our build adds development tools
and SSH. CI caches these extra layers across validation and publication.
The first pull still downloads the official image (about 1.3 GB compressed).
Back up existing Hermes data before upgrading. Update Hermes by changing the
pinned image digest and publishing/pulling a new devbox image, keeping backend
and browser assets together. The separate AI Devbox template is unchanged.

On a fresh volume, startup creates the local Webapp configuration and starts
the service automatically. Model credentials can be configured separately;
they are not required to open the interface. After **Reopen in Container**,
run one command in that project's VS Code terminal (PowerShell or Bash):

```bash
hermes-webapp-open
```

The image command waits for the Webapp, obtains a one-use sign-in link and
sends it privately to the current VS Code window's browser opener. VS Code
forwards **9120** to an available localhost port, preserving the sign-in link.
Run the same command in each project's window: no SSH keys, manual tunnel,
password, link copying or port editing is needed. The command does not print
the sign-in link or put it in process arguments. No host ports are published
by the default Compose configuration.

This command requires an attached VS Code window. For standalone Docker use,
the image still supports `hermes webapp --no-open` and authenticated remote
access below. The opener uses VS Code's
[remote CLI browser protocol](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/api/browser/mainThreadCLICommands.ts).

Startup fills only missing `webapp.enabled`, `webapp.host` and `webapp.port`
with `true`, `127.0.0.1` and `9120`. Existing settings, including an explicit
`enabled: false`, are preserved. If an older gateway was already running,
restart the container after chats finish. The opener also forwards custom
Webapp ports. To disable the Webapp, set `webapp.enabled` to `false` and
restart the container. Logs are in `~/.hermes/logs/gateway.out`.

### Optional remote access using the image

This is a separate image deployment; the devcontainer does not enable LAN/VPN
access. Prepare a dedicated persistent volume and configuration first:

```bash
docker run -d --init --name hermes-webapp \
  -v hermes-webapp-data:/home/hermes/.hermes \
  ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
docker exec -it -u hermes hermes-webapp hermes
docker exec -u hermes hermes-webapp hermes config set webapp.enabled true
docker exec -u hermes hermes-webapp hermes config set webapp.host 0.0.0.0
docker exec -u hermes hermes-webapp hermes config set webapp.port 9120
docker exec -it -u hermes hermes-webapp bash
```

In that shell, edit `~/.hermes/.env` and set these native login settings, using
your own username, password and the **output** of `openssl rand -hex 32` as the
secret (not the command text):

```dotenv
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<your-username>
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<your-password>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<generated-secret>
```

Keep the file private (`chmod 600 ~/.hermes/.env`), then `exit`. Recreate only
the container, retaining its data volume. On the Docker host, set `PRIVATE_IP`
to its LAN/VPN interface address:

```bash
docker rm -f hermes-webapp
docker run -d --init --name hermes-webapp \
  -e HERMES_AUTOSTART_SERVICES=1 \
  -p "${PRIVATE_IP:?Set PRIVATE_IP to the Docker host LAN/VPN address}:9120:9120" \
  -v hermes-webapp-data:/home/hermes/.hermes \
  ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
```

Open `http://<private-ip>:9120` and sign in. Without a configured auth provider,
Hermes refuses remote Webapp access; inspect `hermes webapp --status` inside
the container for the reason. Keep the signing secret to retain browser logins
across restarts. The dashboard stays on container loopback.

HTTP is for a trusted private network/VPN: it is unencrypted and browsers limit
microphone, clipboard and bot-screen features. Public HTTPS hosting is a
separate setup. With Docker Engine inside WSL2, the bind address belongs to
WSL; Windows localhost forwarding does not automatically expose it to the LAN.
Use an address reachable through your VPN/WSL networking configuration.
See [Hermes Webapp documentation](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#use-the-desktop-workspace-from-a-browser).

## Using the container as Hermes' SSH terminal backend

A Hermes running on the host (for example Hermes Desktop) can optionally use
this container as its sandbox. Add `docker-compose.ssh.yml` after
`docker-compose.yml` in `devcontainer.json`'s `dockerComposeFile` array to
publish SSH on `127.0.0.1:${HERMES_SSH_PORT:-2222}`. Choose a distinct stable
`HERMES_SSH_PORT` in `.devcontainer/.env` per project and recreate the container.
Your host's `~/.ssh/*.pub` keys are authorized
automatically. See [SSH-BACKEND.md](.devcontainer/SSH-BACKEND.md) for setup and
troubleshooting.

## Configuration

### The image

`docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image` — the
prebuilt image. Its `Dockerfile` (which
`.github/workflows/publish-ai-hermes-devbox.yml` builds and pushes) is
`FROM nousresearch/hermes-agent:main-desktop@sha256:...` plus PowerShell,
Oh My Posh, Terminal-Icons, Claude Code, Codex, GitHub CLI and SSH. Hermes,
Python, Node, Chromium and Webapp are reused from upstream. `docker-compose.yml`
pulls our published image rather than building the recipe locally.

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
Hermes data) survive both steps.

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
- `hermes-data` — the complete `~/.hermes` user-data directory: credentials,
  config, sessions, logs, memories, and skills. Hermes' code and runtime live
  in the image, not in this volume.

Docker creates these volumes on demand and initializes the CLI directories
from the image on first use. Log in with `claude` or `codex` inside the
container; that state survives normal rebuilds without copying credentials
into image layers. The template does not read host credentials or Git
settings, so configure Git with `git config --global ...` inside the
container when needed. Do not remove the named volumes if you need to retain
their state.

### Workspace location

The parent directory containing the applied repository is mounted at
`/workspaces`. VS Code automatically opens
`/workspaces/<your-repository-directory-name>`. For Hermes Desktop, set the
terminal working directory to that same path; no template edits are required.

## Troubleshooting

- **First build/pull is slow**: the official base is about 1.3 GB compressed.
  Subsequent builds reuse its layers; CI also caches our development-tool
  layers. There is no local Hermes or Webapp compilation.
- **Agent CLI asks you to log in again every rebuild**: check that the
  `claude-data` and `codex-data` named volumes still exist. Removing volumes
  removes CLI login state.

## AI-native SDLC framework

Project skills are included in `.agents/skills`. Container startup does not install or update them.
### Existing Hermes data volumes

Hermes source and its prepared Python environment live in `/opt/hermes`, outside
the data volume. The devbox keeps UID/GID 1000, `/home/hermes/.hermes` and the
existing named volumes, so no data move is needed. Optional plugin environments
can still live under `~/.hermes/installs`. Startup checks the installed runtime;
it does not reinstall Hermes. If the check fails, SSH remains available and
logs advise pulling/recreating the image. Our SSH entrypoint replaces the
official s6 startup, retaining `HERMES_AUTOSTART_SERVICES` and existing log paths.
