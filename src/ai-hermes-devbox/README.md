# AI Hermes Devbox (PowerShell)

A PowerShell-first dev container with the Claude Code / Codex agent CLIs and
Azure tooling preconfigured, plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) from Nous Research.

## What's included

- PowerShell installed in the image, set as the default
  integrated terminal, with Oh My Posh and Terminal-Icons.
- Azure Bicep CLI (`azurebicep` feature) and image-baked GitHub CLI (`gh`).
  The common-utils and Azure Bicep Dev Container features remain; `gh` no longer
  needs a creation-time feature installation.
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

The publishing workflow targets both `linux/amd64` and `linux/arm64` and checks
the pushed index for both platforms. Older AMD64-only images fail on Apple
Silicon with `no match for platform in manifest`; native ARM64 use requires a
successful multi-platform publication. Runtime CI currently runs on AMD64;
the manifest check does not replace testing the Dev Container on an ARM64 host.

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** →
enter the full ID, including `ghcr.io/` —
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`. Without the
registry prefix the template can't be found ("Failed to fetch template
manifest").

Before **Reopen in Container**, authenticate once with Codex CLI on the Docker
host (WSL when Docker runs in WSL):

```bash
codex -c 'cli_auth_credentials_store="file"' login
```

The resulting host `~/.codex/auth.json` must exist before Compose starts.
Hermes imports this OpenAI login automatically.

## First run

The Webapp starts automatically with default Compose settings; the dashboard
is opt-in. Run `hermes-webapp-open` in the devcontainer's
VS Code terminal to open it already signed in. OpenAI authentication comes from
the host Codex login. Run `hermes` to configure other providers or connectors.

The `hermes-data` Docker named volume persists that directory across normal
rebuilds. It holds config, sessions, logs, memories, skills, and
per-user dependency environments. Hermes source lives in the image under
`/opt/hermes`, so pulling a newer image and recreating the container updates the
source. Retain the named volumes to preserve your saved Hermes data.

If an existing volume came from an older image, it may still contain
`~/.hermes/hermes-agent` or `~/.hermes/node`. The entrypoint leaves those files
alone and prints cleanup guidance in `docker compose logs devcontainer`; they
are no longer used by the active `hermes` executable.

**Codex / ChatGPT shortcut.** On first start, `hermes-start-services` imports
the valid host Codex login and defaults to `openai-codex` / `gpt-5.6-terra`.
Explicit provider and model choices and existing Hermes logins are preserved.
Each project imports the host Codex credentials into its own Hermes store.
No interactive Hermes login is started.
The marker `~/.hermes/.codex-default-seeded` makes model setup run once per
project. If the initial Codex access token has expired, renew it with Codex on
the host and restart the container; failed imports are retried on startup.

Hermes and Codex CLI renew credentials separately. Actively using multiple
clients with the same imported login can invalidate a refresh token and
require signing in again.

## Runtime validation

In the maintainer repository, run fast checks and runtime validation on the
Docker host, not from inside a devcontainer:

```bash
npm test && npm run check
python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v
./scripts/validate-hermes-runtime.sh build
./scripts/validate-hermes-runtime.sh all
```

The build uses the public official Hermes image, pinned by digest. The runtime
validator accepts `build`, `all`, or one checkpoint: `A`, `B`, `C`, `D`, `E`, `G`.

- **A**: raw image development shell/tools with no listeners.
- **B**: default Compose gateway/Webapp and dashboard opt-in.
- **C**: parallel isolated projects sharing synthetic Codex auth.
- **D**: actual disposable `devcontainer up` with CLI 0.90.0, real features and
  a frozen lockfile, via `scripts/validate-hermes-devcontainer.sh`.
- **E**: migration over an existing Hermes data volume.
- **G**: prebuilt Webapp HTTP authentication and optional remote password login.

Checkpoint D also needs GNU coreutils `timeout`. Commands and cleanup operations
are bounded, and cancellation stops the owned child process group before cleaning
the disposable project. Timeout overrides are documented in the maintainer
repository's root README.

CI builds and caches the validation image with an isolated Buildx builder, then
sets `BUILDX_BUILDER=default` for runtime checks. This lets the feature build in
checkpoint D extend the image loaded in the Docker daemon instead of trying to
pull its local test tag from a registry.

Only `.github/workflows/publish-ai-hermes-devbox.yml` owns Hermes CI:
preflight → one runtime validation → conditional deployment. Relevant pull
requests and main updates validate; only main pushes changing
`src/ai-hermes-devbox/**` or manual dispatch publish. CI shares a Buildx GHA
layer cache; there is no separate Hermes validation workflow. Opening the
Webapp through VS Code remains manual. SSH checkpoint F has been removed.

## Shell lifecycle and optional dashboard

The custom image entrypoint prepares data and, when requested, runs
`hermes-start-services` as `hermes`, then execs the default
`CMD ["sleep", "infinity"]`. Compose retains `init: true`. This is a development
shell keepalive, not a daemon supervisor: a service failure does not take down
the shell. There is no custom sshd, port 2222, SSH host-key volume or SSH overlay,
and no external Desktop SSH backend integration.

Compose defaults to `HERMES_AUTOSTART_SERVICES=1`, starting gateway/Webapp on
`127.0.0.1:9120`. The dashboard is **off by default**; set
`HERMES_AUTOSTART_DASHBOARD=1` to start it on `127.0.0.1:9119`. Copy
`.devcontainer/.env.example` to `.devcontainer/.env` to customize these values,
then recreate the container. Set `HERMES_AUTOSTART_SERVICES=0` for shell-only
mode; it suppresses both services even if dashboard opt-in is set. A bare
`docker run` without `HERMES_AUTOSTART_SERVICES=1` is also shell-only.

Logs remain `~/.hermes/logs/gateway.out` and, when enabled, `dashboard.out`.
`hermes-start-services` is safe to rerun and reuses existing processes.
`devcontainer.json` forwards ports locally; Compose publishes no host ports.
Closing the attached VS Code window stops the Compose project via
`shutdownAction: stopCompose` instead of leaving services running.

## Webapp in VS Code

The image reuses `nousresearch/hermes-agent:main-desktop`, pinned to the
multi-arch digest `sha256:4566f80ee2f594cbd514719a6ba729426f9344eb545f3de4361d2af1a236c5be`
(commit `84a0301415edd6d1385207ec96e4d7f2b6c1fcd9`, built 2026-11-05).
Hermes and Webapp are already built upstream; our build adds development tools
including GitHub CLI (`gh`). CI caches these layers across validation and publication.
The first pull still downloads the official image (about 1.3 GB compressed).
Back up existing Hermes data before upgrading. Update Hermes by changing the
pinned image digest and publishing/pulling a new devbox image, keeping backend
and browser assets together. The separate AI Devbox template is unchanged.

On a fresh volume, default Compose startup creates the local Webapp
configuration and starts the service automatically. Model credentials can be
configured separately;
they are not required to open the interface. After **Reopen in Container**,
run one command in that project's VS Code terminal (PowerShell or Bash):

```bash
hermes-webapp-open
```

The image command waits for the Webapp, obtains a one-use sign-in link and
sends it privately to the current VS Code window's browser opener. VS Code
forwards **9120** to an available localhost port, preserving the sign-in link.
Run the same command in each project's window: no manual tunnel,
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
across restarts. The dashboard remains off unless explicitly enabled, and stays
on container loopback when enabled.

HTTP is for a trusted private network/VPN: it is unencrypted and browsers limit
microphone, clipboard and bot-screen features. Public HTTPS hosting is a
separate setup. With Docker Engine inside WSL2, the bind address belongs to
WSL; Windows localhost forwarding does not automatically expose it to the LAN.
Use an address reachable through your VPN/WSL networking configuration.
See [Hermes Webapp documentation](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#use-the-desktop-workspace-from-a-browser).

## Configuration

### The image

`docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image` — the
prebuilt image. Its `Dockerfile` (which
`.github/workflows/publish-ai-hermes-devbox.yml` builds and pushes) is
`FROM nousresearch/hermes-agent:main-desktop@sha256:...` plus PowerShell,
Oh My Posh, Terminal-Icons, Claude Code, Codex and GitHub CLI. Hermes,
Python, Node, Chromium and Webapp are reused from upstream. `docker-compose.yml`
pulls our published image rather than building the recipe locally.

### Updating to the latest image

Back up your `.devcontainer/` settings and important Hermes data before upgrading;
keep credential-bearing backups private. Docker caches `:latest`: once the
image is on your machine, applying the
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
`.devcontainer/` files, so review and restore your local customizations.
Named volumes (Claude, Codex,
Hermes data) survive both steps.

For your own customizations, add a second file (e.g. `Dockerfile.local`)
that does `FROM
ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`
followed by your `RUN`/`COPY` lines, and point `docker-compose.yml` at it
with a `build:` block instead of `image:` — your layers sit on top of the
prebuilt image, so rebuilds stay fast.

### Migration from the SSH-enabled devbox

Back up your `.devcontainer/`, local `.env`, Hermes data and any host settings
used by the old integration. Record the current Compose project name and named
volumes; keep them unchanged to reuse the existing state.

Reapply the current template and review local customizations. Applying a template
may leave obsolete files behind. Remove these old files from your project's
`.devcontainer/` if present:

- `docker-compose.ssh.yml`
- `SSH-BACKEND.md`
- `hermes-ssh-info.sh`
- `sshd-hermes-gateway.conf`
- `scripts/connect-hermes-desktop.ps1`
- `scripts/find-devcontainer.sh`

Remove the SSH overlay from `devcontainer.json`'s `dockerComposeFile`, keeping
`docker-compose.yml` and unrelated local overlays. Remove `HERMES_SSH_PORT` and
`HERMES_SSH_CWD` from `.env`, local Compose overrides and the host environment;
remove old SSH port mappings, authorized-key mounts and `ssh-host-keys` volume
declarations. If merging manually rather than reapplying, update Compose,
entrypoint, lockfile and Dev Container configuration, including
`shutdownAction: stopCompose`.

Explicitly pull and recreate with the commands above. Template updates alone do
not replace the old image. Keep `claude-data`, `codex-data` and `hermes-data`;
recreate containers without deleting data volumes. The old project-scoped
`ssh-host-keys` volume is now unused and **is not removed automatically**. Leave
it alone or remove only that volume after verifying no container needs it.

After backing up host settings, remove devbox-only SSH aliases and Hermes
`terminal.backend: ssh` settings made for the old integration. Use
`hermes-webapp-open` from the attached project's VS Code terminal instead;
external Hermes Desktop SSH connections are no longer supported by this devbox.

### Agent CLI credentials

`docker-compose.yml` mounts the host `~/.codex/auth.json` read/write at
`/home/hermes/.codex/auth.json`. Existing credentials are immediately available
inside the container. Codex logins inside the container update the host file,
so other containers can reuse it too.

Run the host login command above first. Codex must use file storage rather
than an OS keyring; see the [Codex authentication documentation](https://learn.chatgpt.com/docs/auth).
Set `DEVBOX_HOST_HOME` in `.devcontainer/.env` to override the host home.
Credentials are never baked into the image.

Hermes imports this login into its own store. Hermes credentials, config and
conversations remain separate per project.

Named volumes retain `claude-data` (Claude login/settings), `codex-data`
(Codex settings/history), and `hermes-data` (config, sessions, logs, memories,
skills). Removing those volumes deletes their state but leaves host
credentials intact. Git settings remain local to the container.

### Workspace location

The Dev Container mounts the applied repository directly at
`/workspaces/<your-repository-directory-name>`. VS Code and the Hermes gateway
start in that same directory; no template edits are required.

## Troubleshooting

- **First build/pull is slow**: the official base is about 1.3 GB compressed.
  Subsequent builds reuse its layers; CI also caches our development-tool
  layers. There is no local Hermes or Webapp compilation.
- **OpenAI asks you to log in again**: check `DEVBOX_HOST_HOME` points to the
  Docker host home where Codex saved `~/.codex/auth.json`, and inspect
  `~/.hermes/logs/codex-seed.out`. Refresh conflicts between Codex and Hermes
  can also require another login. Claude authentication remains in `claude-data`.

## AI-native SDLC framework

Project skills are included in `.agents/skills`. Container startup does not install or update them.

## Existing Hermes data volumes

Hermes source and its prepared Python environment live in `/opt/hermes`, outside
the data volume. The devbox keeps UID/GID 1000, `/home/hermes/.hermes` and the
existing named volumes, so no data move is needed. Optional plugin environments
can still live under `~/.hermes/installs`. Startup checks the installed runtime;
it does not reinstall Hermes. If the check fails, the development shell remains
available and logs advise pulling/recreating the image. The custom preparation
entrypoint replaces the official s6 startup, retaining existing log paths;
`sleep infinity` keeps the container alive independently of optional services.
