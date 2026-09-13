# Hermes SSH Terminal Backend

Use this devcontainer as the sandbox for a Hermes that runs on your host, for
example Hermes Desktop on Windows. Hermes itself stays on the host; only the
terminal commands it runs go over SSH into the container
([Hermes docs](https://hermes-agent.nousresearch.com/docs/user-guide/configuration),
[SSH backend guide](https://hermes-agent.ai/how-to/configure-ssh-terminal-backend)).

In this mode the host's Hermes does the work. The Hermes installed inside the
container is still available for local use, and Compose can start its gateway,
dashboard, and Open WebUI, but the host SSH backend does not depend on those
services.

## How it works

```text
Host (Windows)                          Docker (e.g. in WSL)
+------------------+   ssh :2222      +-------------------------------+
| Hermes Desktop / | ----------------> | devcontainer                  |
| Hermes on host   |  127.0.0.1 only  |  OpenSSH (vscode, bash, sudo) |
+------------------+                  |  ~/.ssh/authorized_keys <---+ |
                                      +-----------------------------|-+
~/.ssh (host that starts Docker)                                    |
  *.pub ----> ssh-pubkeys (one-shot) ----> ssh-pubkeys volume -------+
```

- **SSH server** — OpenSSH is installed in the image and started by the image
  entrypoint. The internal port is always `2222`; `docker-compose.yml` publishes
  it on the host's loopback only using `${HERMES_SSH_PORT:-2222}`, so nothing
  outside your machine can reach it.
- **Stable host identity** — host keys are generated on first start into the
  `ssh-host-keys` named volume. They survive restarts, recreates, and image
  upgrades for the same Compose project, so Hermes' `accept-new` host-key check
  does not break on every rebuild.
- **User and shell** — login is `vscode`, key-only. Its login shell is bash:
  Hermes keeps a `bash -l` session open and runs one-shot commands through the
  login shell, which would break under the base image's pwsh. VS Code terminals
  still open pwsh.
- **Keys** — every `*.pub` in `~/.ssh` of the machine that starts the container
  (`$HOME`, or `%USERPROFILE%` on Windows) is authorized. The one-shot
  `ssh-pubkeys` service copies only public keys into a volume and exits; the
  entrypoint turns them into `authorized_keys` on start. Private keys never enter
  the devcontainer, where agents run.

## Prerequisites

Run these where Docker runs (WSL, if that's where your Docker engine is).

1. Authenticate to the private GHCR packages — `gh` needs the `read:packages`
   scope, and Docker needs the login:

   ```bash
   gh auth refresh -h github.com -s read:packages
   gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
   ```

2. Pull the latest image. Docker caches `:latest` and never re-downloads it on
   apply or rebuild:

   ```bash
   docker pull ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
   ```

   Do this again whenever a new image is published. See
   [Updating to the latest image](README.md#updating-to-the-latest-image) for
   how to check whether you're behind and rebuild on the new image.
3. If the project already has `.devcontainer/` files from an older version of
   the template, re-apply the template so you get the image-owned gateway
   compose wiring, public-key collector, host-key volume, and helper scripts.

## Setup

### 1. Make sure the host has the key Hermes will use

The key must be in `~/.ssh` of the machine that starts the container. If you do
not have one yet:

```bash
ssh-keygen -t ed25519
```

**Docker in WSL, Hermes on Windows:** those are two different `~/.ssh` folders.
Copy the Windows public key into WSL once:

```bash
cp /mnt/c/Users/<you>/.ssh/<key>.pub ~/.ssh/
```

### 2. Apply the template and open the container

```bash
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** ->
enter the full ID `ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`
(the `ghcr.io/` prefix is required), then **Reopen in Container**. Open the
folder in WSL first so VS Code uses WSL's GHCR login; see
[Getting started](README.md#getting-started) for Windows folders.

Keys added or removed later apply on the next container start.

### 3. Read the generated connection details

From the project root on the Docker host:

```bash
docker compose -f .devcontainer/docker-compose.yml exec devcontainer hermes-ssh-info
```

It prints an SSH config block with the alias, host, port, user, and Hermes path.
Use that output instead of assuming port `2222` if you changed
`HERMES_SSH_PORT` in `.devcontainer/.env`.

### 4. Check the connection

From the host where Hermes runs (PowerShell on Windows):

```powershell
ssh <alias-from-hermes-ssh-info> "hermes --version"
```

Or, without adding the alias first:

```powershell
ssh -p <port-from-hermes-ssh-info> vscode@127.0.0.1 "echo `$SHELL"
```

It should print `/bin/bash` for the shell check, and `hermes --version` should
report the image-installed Hermes from `/usr/local/bin/hermes`.

### 5. Point Hermes at the container

In the host Hermes' `config.yaml`:

```yaml
terminal:
  backend: ssh
  cwd: /workspaces/devcontainer-template   # the container's workspaceFolder
```

and in its `~/.hermes/.env`:

```ini
TERMINAL_SSH_HOST=127.0.0.1
TERMINAL_SSH_USER=vscode
TERMINAL_SSH_PORT=<port-from-hermes-ssh-info>
# only for a key ssh does not try by default:
# TERMINAL_SSH_KEY=C:\Users\<you>\.ssh\<key>
```

## Troubleshooting

- **`Permission denied (publickey)`** — the key Hermes uses is not in `~/.ssh`
  of the machine that started the container, or the container has not been
  restarted since you added it. Check what the container accepts with
  `docker compose exec devcontainer cat ~/.ssh/authorized_keys`.
- **`$SHELL` is pwsh, or commands fail with PowerShell errors** — you are on an
  older, cached image. Pull the latest one and rebuild without cache; see
  [Updating to the latest image](README.md#updating-to-the-latest-image).
- **`Connection refused` after updating** — the project's `.devcontainer/` files
  predate the image-owned gateway wiring. Re-apply the template, then rebuild.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED` / Hermes refuses to connect after a
  rebuild** — you may have deleted the `ssh-host-keys` volume or reused the same
  host alias for a different Compose project. Clear the old host key on the
  machine running Hermes:

  ```powershell
  ssh-keygen -R "[127.0.0.1]:<port>"
  ```

- **Port `2222` is already in use** — set `HERMES_SSH_PORT` in
  `.devcontainer/.env`, restart Compose, then run `hermes-ssh-info` again and
  update `TERMINAL_SSH_PORT`.
- **Port `2222` appears in VS Code's Ports view on a different local port** —
  VS Code auto-forwarding; ignore it. Use the Compose mapping printed by
  `hermes-ssh-info`.
- **No `~/.ssh` folder on the host** — Docker can create an empty one for the
  mount. Create a real key with `ssh-keygen` first, then restart the container.
