# AI Hermes Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`

The official [Hermes Agent](https://hermes-agent.nousresearch.com/) image with
prebuilt Webapp, browser and computer-use, plus the development tools familiar
from [AI Devbox](ai-devbox.md) and an SSH gateway a host-side Hermes Desktop can drive.

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

## Connect Hermes Desktop

Optional; browser users do not need this. Add `docker-compose.ssh.yml` after
`docker-compose.yml` in `devcontainer.json`'s `dockerComposeFile` array and
recreate the container. Copy `.devcontainer/.env.example` to `.devcontainer/.env`
and choose a different `HERMES_SSH_PORT` for each project before recreating it.

```powershell
# Windows: reads the running container, writes ~/.ssh/config + Hermes config, verifies
./.devcontainer/scripts/connect-hermes-desktop.ps1
```

```bash
# or read the connection details yourself
bash .devcontainer/scripts/find-devcontainer.sh "$(pwd)" hermes-ssh-info
```

Your host's `~/.ssh/*.pub` keys are authorized automatically; private keys never
enter the container. Details and troubleshooting:
[`SSH-BACKEND.md`](../src/ai-hermes-devbox/.devcontainer/SSH-BACKEND.md).

## Fix three things after applying

`/workspaces/devcontainer-template` is hardcoded in `devcontainer.json`
(`workspaceFolder`) and twice in `docker-compose.yml` (bind mount target,
`HERMES_SSH_CWD`). Change all three to your folder name.

## What runs

| Service | Address | Notes |
| --- | --- | --- |
| SSH gateway | Container port 2222 | Host publication is opt-in with `docker-compose.ssh.yml` |
| Hermes gateway / Webapp | `127.0.0.1:9120` by default | Started by `hermes-start-services`; forwarded locally by VS Code |
| Hermes dashboard | `127.0.0.1:9119` | Forwarded by VS Code; logs in `~/.hermes/logs/` |

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

## Persistence

The host `~/.codex/auth.json` is mounted read/write into each container at
`/home/hermes/.codex/auth.json`. Existing host credentials are immediately
available; Codex logins inside the container also update the host file.

Set `DEVBOX_HOST_HOME` in `.devcontainer/.env` if Compose should use a different
host home. The host credential file must exist before creating the container.
Use Codex's file credential store, as described in the
[Codex authentication documentation](https://learn.chatgpt.com/docs/auth).

Named volumes keep Claude state, Codex settings/history, and Hermes config,
sessions, memories and skills separate per project. `ssh-host-keys` keeps each
project's SSH identity. `docker compose down -v` removes those volumes but
does not remove host credentials. Hermes' code lives in the image.

Hermes imports the Codex login into its own per-project authentication store.
Git settings remain local to the container.

## Notes

- **Project skills**: files are included in `.agents/skills`; startup does not
  install or update skills.
- **Codex/ChatGPT shortcut**: on first start, Hermes imports a valid host Codex
  login and defaults to `openai-codex` / `gpt-5.6-terra`. Explicit provider and
  model choices and existing Hermes logins are preserved. If the initial Codex
  access token has expired, renew it
  with Codex on the host and restart the container.
- **Refresh limitation**: Hermes and Codex CLI renew credentials separately.
  Using multiple clients actively
  with the same imported login can invalidate a refresh token and require
  signing in again.
- **Updating**: Docker caches `:latest`, so pull explicitly, then
  `devcontainer up --workspace-folder . --remove-existing-container --build-no-cache`.
  If the template's `.devcontainer/` changed too, re-run `templates apply` first
  (it overwrites that directory — redo your edits; volumes survive).
- **Validating the gateway** (on the Docker host, not inside a devcontainer):
  `./scripts/validate-hermes-gateway.sh build` then `all` — checkpoints A–E
  and G (Webapp), also run in CI. F (a real Hermes Desktop connection) and
  opening the Webapp through VS Code are manual.
- **Prebuilt runtime**: the official `main-desktop` base includes browser and
  computer-use. There is no Hermes installer or frontend compilation in our build.
- **Old `hermes-data` volumes** may still hold unused `~/.hermes/hermes-agent`
  or `~/.hermes/node`; the entrypoint flags them and leaves them alone.

Source: [`src/ai-hermes-devbox/`](../src/ai-hermes-devbox/) ·
[`Dockerfile`](../src/ai-hermes-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-hermes-devbox.yml`](../.github/workflows/publish-ai-hermes-devbox.yml) ·
[in-template README](../src/ai-hermes-devbox/README.md)

### Existing Hermes data volumes

Hermes source and its prepared Python environment live in `/opt/hermes`, outside
the data volume. The devbox keeps UID/GID 1000, `/home/hermes/.hermes` and the
existing named volumes, so no data move is needed. Optional plugin environments
can still live under `~/.hermes/installs`. Startup checks the installed runtime;
it does not reinstall Hermes. If the check fails, SSH remains available and
logs advise pulling/recreating the image. Our SSH entrypoint replaces the
official s6 startup, retaining `HERMES_AUTOSTART_SERVICES` and existing log paths.
