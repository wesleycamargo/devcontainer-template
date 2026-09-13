# Hermes SSH Terminal Backend

Use this devcontainer as the sandbox for a Hermes that runs on your host
(for example Hermes Desktop on Windows). Hermes itself stays on the host;
only the terminal commands it runs go over SSH into the container
([Hermes docs](https://hermes-agent.nousresearch.com/docs/user-guide/configuration),
[SSH backend guide](https://hermes-agent.ai/how-to/configure-ssh-terminal-backend)).

In this mode the Hermes installed inside the container (and its gateway,
dashboard and Open WebUI) isn't used — it's the host's Hermes doing the work.

## How it works

```text
Host (Windows)                          Docker (e.g. in WSL)
┌──────────────────┐   ssh :2222      ┌───────────────────────────────┐
│ Hermes Desktop / │ ───────────────▶ │ devcontainer                  │
│ Hermes on host   │  127.0.0.1 only  │  sshd (vscode, bash, sudo)    │
└──────────────────┘                  │  ~/.ssh/authorized_keys ◀─┐   │
                                      └───────────────────────────│───┘
~/.ssh (host that starts Docker)                                  │
  *.pub ─────▶ ssh-pubkeys (one-shot) ──▶ ssh-pubkeys volume ─────┘
```

- **SSH server** — the `sshd` feature in `devcontainer.json` listens on
  `2222`; `docker-compose.yml` publishes it on the host's loopback only
  (`127.0.0.1:2222`), so nothing outside your machine can reach it.
- **User and shell** — login is `vscode`, key-only. Its login shell is
  bash: Hermes keeps a `bash -l` session open and runs one-shot commands
  (sudo, stdin) through the login shell, which would break under the base
  image's pwsh. VS Code terminals still open pwsh.
- **Keys** — every `*.pub` in `~/.ssh` of the machine that starts the
  container (`$HOME`, or `%USERPROFILE%` on Windows) is authorized. The
  one-shot `ssh-pubkeys` service copies **only the public keys** into a
  volume and exits; the devcontainer turns them into `authorized_keys` on
  start. Your private keys never enter the devcontainer, where agents run.

## Prerequisites

Run these where Docker runs (WSL, if that's where your Docker engine is).

1. Authenticate to the private GHCR packages — `gh` needs the
   `read:packages` scope, and Docker needs the login:

   ```bash
   gh auth refresh -h github.com -s read:packages
   gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
   ```

2. Pull the latest image. Docker caches `:latest` and never re-downloads it
   on apply or rebuild, so an image from before SSH support (pwsh login
   shell) would otherwise be reused:

   ```bash
   docker pull ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest
   ```

   Do this again whenever a new image is published. See
   [Updating to the latest image](README.md#updating-to-the-latest-image)
   for how to check whether you're behind and rebuild on the new image.
3. If the project already has `.devcontainer/` files from an older version
   of the template, re-apply the template (step 2 of [Setup](#setup)) — SSH
   needs the new `devcontainer.json` and `docker-compose.yml`, not just the
   new image.

## Setup

### 1. Make sure the host has the key Hermes will use

The key must be in `~/.ssh` of the machine that **starts the container**.
If you don't have one yet:

```bash
ssh-keygen -t ed25519
```

**Docker in WSL, Hermes on Windows:** those are two different `~/.ssh`
folders. Copy the Windows public key into WSL once:

```bash
cp /mnt/c/Users/<you>/.ssh/<key>.pub ~/.ssh/
```

### 2. Apply the template and open the container

```bash
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox
```

or in VS Code: **Dev Containers: Add Dev Container Configuration Files** →
enter the full ID `ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`
(the `ghcr.io/` prefix is required), then **Reopen in Container**. Open the
folder in WSL first so VS Code uses WSL's GHCR login — see
[Getting started](README.md#getting-started) for Windows folders.

Keys added or removed later apply on the next container start.

### 3. Check the connection

From the host where Hermes runs (PowerShell on Windows):

```powershell
ssh -p 2222 vscode@127.0.0.1 'echo $SHELL'
# with a key ssh doesn't try by default (not id_ed25519, id_rsa, ...):
ssh -i $HOME\.ssh\<key> -p 2222 vscode@127.0.0.1 'echo $SHELL'
```

It should print `/bin/bash`.

### 4. Point Hermes at the container

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
TERMINAL_SSH_PORT=2222
# only for a key ssh doesn't try by default:
# TERMINAL_SSH_KEY=C:\Users\<you>\.ssh\<key>
```

## Troubleshooting

- **`Permission denied (publickey)`** — the key Hermes uses isn't in
  `~/.ssh` of the machine that started the container (see
  [step 1](#1-make-sure-the-host-has-the-key-hermes-will-use)), or the
  container hasn't been restarted since you added it. Check what the
  container accepts: `cat ~/.ssh/authorized_keys` inside it.
- **`$SHELL` is pwsh, or commands fail with PowerShell errors** — you're on
  an older, cached image. Pull the latest one and rebuild without cache
  (see [Updating to the latest image](README.md#updating-to-the-latest-image)).
- **`Connection refused` on 2222 right after updating** — the project's
  `.devcontainer/` files predate SSH support (no `sshd` feature or port
  mapping). Re-apply the template, then rebuild.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED` / Hermes refuses to connect
  after a rebuild** — the container's SSH host key is generated at build
  time, so it can change after a rebuild. Hermes uses
  `StrictHostKeyChecking=accept-new`, which rejects a changed key. Clear the
  old one on the host:

  ```powershell
  ssh-keygen -R "[127.0.0.1]:2222"
  ```

- **`Connection refused` on 2222** — the container isn't running, or
  another process on the host already uses 2222. Change the left side of
  `127.0.0.1:2222:2222` in `docker-compose.yml` (and `TERMINAL_SSH_PORT`).
- **Port 2222 appears in VS Code's Ports view on a different local port** —
  VS Code auto-forwarding; ignore it. Use the compose mapping,
  `127.0.0.1:2222`.
- **No `~/.ssh` folder on the host** — Docker creates an empty one for the
  mount (owned by root on Linux). Create it yourself with `ssh-keygen` first.
