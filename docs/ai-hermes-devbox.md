# AI Hermes Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`

[AI Devbox](ai-devbox.md) plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) (full browser +
computer-use install) and an SSH gateway a host-side Hermes Desktop can drive.

## Command line

```powershell
# Apply the public template (no registry login required)
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox

# Pick a stable SSH port
cp .devcontainer/.env.example .devcontainer/.env
```

Then **Reopen in Container** and run `hermes` once inside it to set up API keys
and connectors.

Keep `HERMES_SSH_PORT` fixed once chosen — Hermes Desktop saves it in its
connection:

```dotenv
HERMES_SSH_PORT=2222
```

## VS Code UI

1. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
2. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
   ```

3. Copy `.devcontainer/.env.example` to `.devcontainer/.env` as above, then
   **Reopen in Container** and run `hermes` once inside it.

## Connect Hermes Desktop

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
| SSH gateway | `127.0.0.1:${HERMES_SSH_PORT:-2222}` | Container side is always 2222, so several projects run at once |
| Hermes gateway / Webapp | `127.0.0.1:9120` by default | Started by `hermes-start-services`; forwarded locally by VS Code |
| Hermes dashboard | `127.0.0.1:9119` | Forwarded by VS Code; logs in `~/.hermes/logs/` |

## Webapp in VS Code

The image includes the prebuilt Desktop workspace for browsers. Hermes is pinned
to commit `c419cf7c864ac0ee511dbd9f7091a8bba0b567ee` (after v0.22.5, before the
next stable release); the base AI Devbox stays on v0.22.5. Back up existing
Hermes data before upgrading. Update Hermes by rebuilding/pulling this image,
so the backend and browser bundle stay together.

After running `hermes` once to configure it, run in the container terminal:

```bash
hermes-start-services
hermes webapp --status
hermes webapp --no-open
```

Open the last command's one-use link within 60 seconds. A bare URL does not sign
you in. VS Code forwards **9120** to localhost; if its Ports panel assigns a
different local port, replace only the port in the link. No Webapp port is
published by Compose. The existing SSH mapping remains localhost-only.

Startup fills only missing `webapp.enabled`, `webapp.host` and `webapp.port`
with `true`, `127.0.0.1` and `9120`. Existing settings, including an explicit
`enabled: false`, are preserved. If an older gateway was already running,
restart the container after chats finish. Custom Webapp ports need a matching
VS Code forward. To disable the Webapp, set `webapp.enabled` to `false` and
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

Named volumes, created on demand: `claude-data`, `codex-data`, `hermes-data`
(credentials, config, sessions, memories, skills — Hermes' *code* lives in the
image, so a newer image really upgrades Hermes), `ssh-host-keys` (stable host
identity across recreates). `docker compose down -v` destroys all of them.

The container reads no host credentials — run `claude`, `codex` and
`git config --global …` inside it.

## Notes

- **Project skills**: files are included in `.agents/skills`; startup does not
  install or update skills.
- **Codex/ChatGPT shortcut**: on start, a valid `~/.codex/auth.json` seeds
  Hermes with `model.provider: openai-codex` / `gpt-5.6-terra`. Runs once,
  guarded by `~/.hermes/.codex-default-seeded`; delete that plus
  `hermes auth logout openai-codex` to re-seed.
- **Updating**: Docker caches `:latest`, so pull explicitly, then
  `devcontainer up --workspace-folder . --remove-existing-container --build-no-cache`.
  If the template's `.devcontainer/` changed too, re-run `templates apply` first
  (it overwrites that directory — redo your edits; volumes survive).
- **Validating the gateway** (on the Docker host, not inside a devcontainer):
  `./scripts/validate-hermes-gateway.sh build` then `all` — checkpoints A–E
  and G (Webapp), also run in CI. F (a real Hermes Desktop connection) and
  opening the Webapp through VS Code are manual.
- **Lean image**: add `--skip-browser --skip-computer-use` to the `install.sh`
  line in the `Dockerfile` if the Chromium/computer-use build is too heavy.
- **Old `hermes-data` volumes** may still hold unused `~/.hermes/hermes-agent`
  or `~/.hermes/node`; the entrypoint flags them and leaves them alone.

Source: [`src/ai-hermes-devbox/`](../src/ai-hermes-devbox/) ·
[`Dockerfile`](../src/ai-hermes-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-hermes-devbox.yml`](../.github/workflows/publish-ai-hermes-devbox.yml) ·
[in-template README](../src/ai-hermes-devbox/README.md)

### Existing Hermes data volumes

Hermes source stays in the image at `/opt/hermes/hermes-agent`. The package
manager keeps per-user dependency environments under `~/.hermes/installs`.
An existing volume can hide the environment prepared by the image; startup runs
a bounded `hermes pm repair` when the version check fails, retaining user
configuration, credentials, plugins and sessions. If repair cannot finish,
SSH remains available and startup logs explain the failure.
