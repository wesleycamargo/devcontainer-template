# AI Hermes Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`

The official [Hermes Agent](https://hermes-agent.nousresearch.com/) image with
prebuilt Webapp, browser and computer-use, plus the development tools familiar
from [AI Devbox](ai-devbox.md). Use the Webapp from the project's VS Code window;
the devbox no longer includes a custom SSH server or external Desktop SSH backend.
The publishing workflow targets both `linux/amd64` and `linux/arm64` and checks
the pushed index for both platforms. Older AMD64-only images fail on Apple
Silicon with `no match for platform in manifest`; native ARM64 use requires a
successful multi-platform publication. Runtime CI currently runs on AMD64;
the manifest check does not replace testing the Dev Container on an ARM64 host.

## Command line

```powershell
# Apply the public template (no registry login required)
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

Before opening the container, authenticate once with Codex CLI on the Docker
host (WSL when Docker runs in WSL):

```bash
codex -c 'cli_auth_credentials_store="file"' login
```

This creates the required `~/.codex/auth.json` host file. Then **Reopen in
Container** and run `hermes-webapp-open` in its terminal. Hermes imports the
OpenAI login automatically; there is no separate Hermes OpenAI login step.

The default devcontainer publishes no host ports. VS Code forwards the Webapp
locally, choosing an available port for each project.

## VS Code UI

1. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
2. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
   ```

3. Complete the host Codex login above, then **Reopen in Container** and run
   `hermes-webapp-open` in its VS Code terminal.

## Workspace location

The Dev Container mounts the opened repository directly at
`/workspaces/${localWorkspaceFolderBasename}`. VS Code and the Hermes gateway
start in that same directory; no hardcoded repository-name edits are required.

## What runs

The template keeps its `Dockerfile`. Its `.devcontainer/` payload contains
exactly seven files: `.env.example`, `.gitignore`, `Dockerfile`,
`devcontainer-lock.json`, `devcontainer.json`, `docker-compose.yml` and
`hermes_devbox.py`. The standard-library-only Python helper implements
preparation, CLI wrapping, service startup and Webapp opening. The image installs
it at `/usr/local/lib/hermes_devbox.py` and creates command symlinks;
`hermes`, `hermes-start-services` and `hermes-webapp-open` remain unchanged.

| Service | Address | Notes |
| --- | --- | --- |
| Development shell | `sleep infinity` keeps the container alive | Custom entrypoint prepares state and optionally starts services; Compose retains `init: true` |
| Hermes gateway / Webapp | `127.0.0.1:9120` by default | Automatic in Compose; forwarded locally by VS Code |
| Hermes dashboard | `127.0.0.1:9119` | Off by default; opt in with `HERMES_AUTOSTART_DASHBOARD=1` |

Compose defaults to `HERMES_AUTOSTART_SERVICES=1`. Copy
`.devcontainer/.env.example` to `.devcontainer/.env` to customize it, then
recreate the container. Set `HERMES_AUTOSTART_SERVICES=0` for shell-only mode;
this master switch also suppresses the dashboard even if its opt-in is set.
A bare `docker run` without `HERMES_AUTOSTART_SERVICES=1` is shell-only.

The entrypoint runs preparation/autostart and then execs the image's default
`CMD ["sleep", "infinity"]`; it is not a daemon supervisor. Service failure does
not terminate the development shell. Inspect `~/.hermes/logs/gateway.out` and,
when enabled, `dashboard.out`; `hermes-start-services` is safe to rerun and
reuses existing processes. Closing the attached VS Code window stops the
Compose project (`shutdownAction: stopCompose`), rather than leaving it running.
No custom sshd, port 2222, SSH host-key volume or SSH overlay remains.

## Optional Hermes defaults

Copy `.devcontainer/.env.example` to `.devcontainer/.env` before opening or recreating the container. Uncomment `HERMES_MODEL_PROVIDER` and `HERMES_DEFAULT_MODEL`, replacing the model ID with one supported by that provider. Uncomment other entries only when needed: `HERMES_MODEL_BASE_URL`, `HERMES_TERMINAL_CWD`, `HERMES_TERMINAL_BACKEND`, `HERMES_TERMINAL_TIMEOUT`, `HERMES_WEBAPP_ENABLED`, `HERMES_WEBAPP_HOST`, and `HERMES_WEBAPP_PORT`.

These are initial defaults, not forced overrides. Saved Hermes settings always win, including false or empty values; blank environment inputs do nothing. Later edits to this file do not replace saved choices. Use `hermes model` or `hermes config set model.default YOUR_MODEL_ID` to change an existing model, and recreate after active work finishes while retaining named volumes.

The custom endpoint input requires provider `custom` and must not contain credentials. Workspace paths are absolute paths inside the target environment, not host paths or VS Code substitution variables. Selecting a backend does not provision or authenticate it. Webapp host bootstrap accepts loopback only; remote access still follows the separate authenticated procedure. A different Webapp port may require changing VS Code forwarding too.

Credentials belong in Hermes' private secret store, not Compose's `.env`. Provider settings do not authenticate you, and the existing host Codex file mount prerequisite remains unchanged. Without these optional inputs, existing Codex model seeding and local Webapp fallback defaults remain unchanged. In shell-only mode, bootstrap runs when you explicitly start services. Changed Compose environment inputs require container recreation, not a process restart.

Environment bootstrap runs before Codex seeding and Webapp fallbacks. Unrequested, missing Webapp settings still receive true/127.0.0.1/9120.


## Webapp in VS Code

The image reuses `nousresearch/hermes-agent:main-desktop`, pinned to the
multi-arch digest `sha256:4566f80ee2f594cbd514719a6ba729426f9344eb545f3de4361d2af1a236c5be`
(commit `84a0301415edd6d1385207ec96e4d7f2b6c1fcd9`, built 2026-11-05).
Hermes and Webapp are already built upstream; our build adds development tools
including GitHub CLI (`gh`). It is baked into the image rather than installed
by a Dev Container feature; common-utils and Azure Bicep features remain.
CI caches the development-tool layers across validation and publication.
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

Environment bootstrap runs first. Startup fallbacks then fill only missing
`webapp.enabled`, `webapp.host` and `webapp.port`
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

## Persistence

The host `~/.codex/auth.json` is mounted read/write into each container at
`/home/hermes/.codex/auth.json`. Existing host credentials are immediately
available; Codex logins inside the container also update the host file.

Set `DEVBOX_HOST_HOME` in `.devcontainer/.env` if Compose should use a different
host home. The host credential file must exist before creating the container.
Use Codex's file credential store, as described in the
[Codex authentication documentation](https://learn.chatgpt.com/docs/auth).

Named volumes keep Claude state, Codex settings/history, and Hermes config,
sessions, memories and skills separate per project. Keep `claude-data`,
`codex-data` and `hermes-data` when recreating or upgrading; deleting them
destroys their saved state. Host credentials remain in the host file.
Hermes' code lives in the image.

Hermes imports the Codex login into its own per-project authentication store.
Git settings remain local to the container.

## Workspace write access

The image, Compose service and CLI wrapper allow file-tool writes to
`/home/hermes/.hermes` and the mounted `/workspaces` tree by default through
`HERMES_WRITE_SAFE_ROOT`. Explicit scope overrides are preserved; credential and
sealed-runtime protections remain enabled. Recreate the container to apply
Compose changes; image-only changes also require a rebuilt/pulled image.

## Skills bootstrap

For **new projects with a fresh `hermes-data` volume**, AI Hermes Devbox registers
these public taps and installs this 18-skill starter baseline:

- **`wesleycamargo/skills`** (six skills):
  - `sdlc-create-intent`
  - `sdlc-create-spec`
  - `sdlc-create-plan`
  - `sdlc-execute-plan`
  - `sdlc-validate-implementation`
  - `write-for-me`
- **`mattpocock/skills`** (twelve skills):
  - Engineering: `wayfinder`, `code-review`, `codebase-design`, `diagnosing-bugs`,
    `grill-with-docs`, `improve-codebase-architecture`, `prototype`, `research`,
    `wizard`.
  - Productivity: `handoff`, `wait-what`, `teach`.

### Configure before first startup

Copy `.devcontainer/.env.example` to `.devcontainer/.env` and customize the public,
non-secret `HERMES_SKILLS_TAPS` and `HERMES_SKILLS_INSTALL` lists before launching
the new project. Both are ordered, comma-separated lists. Install identifiers are
source-qualified: for example, `wesleycamargo/skills/write-for-me` or
`mattpocock/skills/skills/engineering/code-review`. Matt's engineering and
productivity entries retain their nested repository-relative paths; each skill's
source must also appear in the taps list. Do not put credentials in these inputs.

To disable starter installation, set an **explicit empty value**:

```dotenv
HERMES_SKILLS_INSTALL=
```

A blank install list on the fresh volume's first startup disables automatic
enrollment, not just that one attempt. Later setting a nonblank list does not
automatically enroll that volume. Existing projects/data volumes are never
silently enrolled or changed by this bootstrap; manual skill installation remains
available on both existing and initially disabled volumes, for example:

```bash
hermes skills install wesleycamargo/skills/write-for-me --yes
```

### Persistence, retries and upgrades

A fresh volume with a nonblank list is enrolled before the first install attempt,
recorded by `~/.hermes/.skills-bootstrap-enrolled`. Only a completely successful
batch writes `~/.hermes/.skills-bootstrap.json` with the requested taps and skills.
A matching success marker makes later startup a no-op: no repeated tap/install
commands, marker rewrite or skill update. Existing success markers are recognized
as enrolled for compatibility.

For an enrolled volume, deliberately changing the taps/install configuration and
recreating the container triggers another attempt. Failures warn without blocking
the development shell; partial installs may remain, but no new success marker is
written. A failed changed configuration preserves the previous success marker and
is retried on later startup until successful. Public GitHub rate limits can
interrupt a large first batch; already installed copies are preserved on retry.
Startup never runs
`hermes skills update`, uses `--force`, overwrites installed/user-edited skills, or
removes skills omitted from a changed list.

Tap registrations, installed copies and markers persist in the project-scoped
`hermes-data` volume. Keep that volume during normal upgrades. Removing it destroys
Hermes settings, sessions and skills as well as bootstrap state; it is not a normal
upgrade or retry step.

Check for updates, then choose an explicit manual update when wanted:

```bash
hermes skills check
hermes skills update
hermes skills update <name>
```

`update` without a name targets all outdated installed hub skills; replace
`<name>` with one installed skill to target only that skill. Do not add `--force`
unless you deliberately intend to replace local edits. To publish a small personal
change to the Wesley repository, with the required GitHub access:

```bash
hermes skills publish ~/.hermes/skills/<name> --to github --repo wesleycamargo/skills
```

Replace `<name>` with your installed skill directory. Prefer normal Git branches
and pull requests for reviewed multi-skill changes.

This starter set lives in Hermes' user data, not the project: the template still
ships no bundled `.agents/` tree or project-skills configuration hook. Optional
repository-local skills remain separate and are not installed or updated at
container startup.

## Notes

- **Project skills**: fresh templates include no bundled `.agents/` tree or
  project-skills configuration hook. Skills are optional: add the ones you need
  manually and ask the agent to read their `SKILL.md`. Startup does not install
  or update project skills.
- **Codex/ChatGPT shortcut**: on first start, Hermes imports a valid host Codex
  login and defaults to `openai-codex` / `gpt-6.1-sol` with medium reasoning. Explicit provider and
  model choices and existing Hermes logins are preserved. If the initial Codex
  access token has expired, renew it
  with Codex on the host and restart the container.
- **Refresh limitation**: Hermes and Codex CLI renew credentials separately.
  Using multiple clients actively
  with the same imported login can invalidate a refresh token and require
  signing in again.
- **Updating**: back up your `.devcontainer/` settings and Hermes data first.
  Docker caches `:latest`, so pull explicitly, then
  `devcontainer up --workspace-folder . --remove-existing-container --build-no-cache`.
  If the template's `.devcontainer/` changed too, re-run `templates apply` first
  (it overwrites files — review/restore local edits; volumes survive). Follow
  the migration below if you previously enabled the SSH overlay.
- **Validation** (in the maintainer repo, on the Docker host): run
  `npm test && npm run check` and
  `python3 -B -m unittest discover -s scripts -p 'test_*hermes*.py' -v`.
  Then run `./scripts/validate-hermes-runtime.sh build` and `all` (or one of
  `A`, `B`, `C`, `D`, `E`, `G`). A checks raw shell/tools/no listeners; B default
  services/dashboard opt-in; C isolated parallel projects/shared synthetic auth;
  D real disposable `devcontainer up` with CLI 0.90.0, actual features and frozen
  lockfile via `scripts/validate-hermes-devcontainer.sh`; E existing-volume
  migration; G Webapp HTTP auth. VS Code browser opening remains manual;
  SSH checkpoint F is removed.
- **Smoke prerequisites**: checkpoint D also requires GNU coreutils `timeout`.
  Commands and cleanup operations have deadlines; cancellation stops only the
  owned child process group before cleaning the disposable project. Timeout
  overrides are documented in the [maintainer README](../README.md#4-validation-and-tests).
- **CI**: only `.github/workflows/publish-ai-hermes-devbox.yml` owns Hermes
  preflight → validation → conditional deployment. Relevant pull requests/main
  updates validate; only main pushes changing `src/ai-hermes-devbox/**` or
  manual dispatch publish. There is no separate Hermes validation workflow.
- **Prebuilt runtime**: the official `main-desktop` base includes browser and
  computer-use. There is no Hermes installer or frontend compilation in our build.
- **Old `hermes-data` volumes** may still hold unused `~/.hermes/hermes-agent`
  or `~/.hermes/node`; the entrypoint flags them and leaves them alone.

Source: [`src/ai-hermes-devbox/`](../src/ai-hermes-devbox/) ·
[`Dockerfile`](../src/ai-hermes-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-hermes-devbox.yml`](../.github/workflows/publish-ai-hermes-devbox.yml) ·
[in-template README](../src/ai-hermes-devbox/README.md)

## Migration to the Python runtime

Back up `.devcontainer/`, any bundled `.agents/` files and important Hermes
data before reapplying the template. Keep credential-bearing backups private.
Reapplying does not automatically clean existing projects: obsolete files can
remain even though fresh templates no longer ship them.

Compare these files with the template version you originally applied, and
manually remove only unmodified copies:

- `.devcontainer/entrypoint.sh`
- `.devcontainer/hermes.sh`
- `.devcontainer/start-services.sh`
- `.devcontainer/webapp-open.py`
- `.devcontainer/scripts/configure-project-skills.sh`
- Old bundled files under `.agents/`.

Preserve user-created or edited files; review and port any needed customizations
before deciding what to retain. Keep the `Dockerfile` and the other seven-file
payload entries listed above. Pull the new image and recreate the container as
described under **Updating**, retaining the same Compose project and named data
volumes. Updating template files alone does not change the image-owned runtime.

## Migration from the SSH-enabled devbox

1. Back up `.devcontainer/` (including local `.env` settings) and important
   Hermes data before applying the new template. Keep backups containing
   credentials private. Record the existing Compose project name and named
   volumes so the recreated container uses the same data.
2. Reapply the template and review your local customizations. Applying it may
   leave files deleted from the new payload behind: remove these obsolete files
   from your project's `.devcontainer/` if present:
   - `docker-compose.ssh.yml`
   - `SSH-BACKEND.md`
   - `hermes-ssh-info.sh`
   - `sshd-hermes-gateway.conf`
   - `scripts/connect-hermes-desktop.ps1`
   - `scripts/find-devcontainer.sh`
3. Remove the SSH overlay from `devcontainer.json`'s `dockerComposeFile`, leaving
   `docker-compose.yml` and any unrelated local overlays. Remove
   `HERMES_SSH_PORT`/`HERMES_SSH_CWD` settings from `.env`, Compose overrides and
   host environment, and any old SSH port mappings, authorized-key mounts or
   `ssh-host-keys` volume declarations. If you merge manually instead of
   reapplying, bring over the current Compose, entrypoint, lockfile and Dev
   Container configuration, including `shutdownAction: stopCompose`.
4. Explicitly pull the new image on the Docker host; updating template files or
   rebuilding from cached `:latest` alone does not replace the old runtime:

   ```bash
   docker pull ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
   devcontainer up --workspace-folder . --remove-existing-container --build-no-cache
   ```

   Keep the same project name and `claude-data`, `codex-data`, `hermes-data`
   volumes. Recreate containers only; do not delete the data volumes.
5. Open the project in VS Code and run `hermes-webapp-open`. Remove any
   devbox-only host SSH aliases or Hermes `terminal.backend: ssh` configuration
   created for the old integration, after backing up those host settings. An
   external Hermes Desktop SSH connection is no longer supported by this devbox.

The old project-scoped `ssh-host-keys` volume becomes unused and is **not
removed automatically**. It can be left alone or removed individually after
you verify that no container needs it; preserve all agent data volumes.

### Existing Hermes data volumes

Hermes source and its prepared Python environment live in `/opt/hermes`, outside
the data volume. The devbox keeps UID/GID 1000, `/home/hermes/.hermes` and the
existing named volumes, so no data move is needed. Optional plugin environments
can still live under `~/.hermes/installs`. Startup checks the installed runtime;
it does not reinstall Hermes. If the check fails, the development shell remains
available and logs advise pulling/recreating the image. The custom preparation
entrypoint replaces the official s6 startup, retaining the existing log paths;
`sleep infinity` keeps the container alive independently of optional services.
