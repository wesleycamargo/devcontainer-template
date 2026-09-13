# Hermes SSH Terminal Backend

Use this devcontainer as the sandbox for a Hermes that runs on your host, for
example Hermes Desktop on Windows. Hermes itself stays on the host; only the
terminal commands it runs go over SSH into the container
([Hermes docs](https://hermes-agent.nousresearch.com/docs/user-guide/configuration),
[SSH backend guide](https://hermes-agent.ai/how-to/configure-ssh-terminal-backend)).

In this mode the host's Hermes does the work. The Hermes installed inside the
container is still available for local use, and Compose starts its gateway
and dashboard, but the host SSH backend does not depend on those services.

This mirrors the setup documented in
[`src/ai-hermes-devbox/.devcontainer/SSH-BACKEND.md`](../src/ai-hermes-devbox/.devcontainer/SSH-BACKEND.md)
for the published template; this copy is trimmed to skip the "apply the
template" steps, since this devcontainer is already checked into the repo.

## How it works

```text
Host (Windows)                          Docker (e.g. in WSL)
+------------------+   ssh :2222      +-------------------------------+
| Hermes Desktop / | ----------------> | devcontainer                  |
| Hermes on host   |  127.0.0.1 only  |  OpenSSH (hermes, bash, sudo) |
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
  upgrades, so Hermes' `accept-new` host-key check does not break on every
  rebuild.
- **User and shell** — login is `hermes`, key-only. Its login shell is bash:
  Hermes keeps a `bash -l` session open and runs one-shot commands through the
  login shell, which would break under the base image's pwsh. VS Code terminals
  still open pwsh.
- **Keys** — every `*.pub` in `~/.ssh` of the machine that starts the container
  (`$HOME`, or `%USERPROFILE%` on Windows) is authorized. The one-shot
  `ssh-pubkeys` service copies only public keys into a volume and exits; the
  entrypoint turns them into `authorized_keys` on start. Private keys never
  enter the devcontainer, where agents run.

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

### 2. Start the container

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
```

or in VS Code: **Reopen in Container**.

Keys added or removed later apply on the next container start.

### 3. Read the generated connection details

From the project root on the Docker host:

```bash
bash .devcontainer/scripts/find-devcontainer.sh "$(pwd)" hermes-ssh-info
```

(Not `docker compose exec devcontainer hermes-ssh-info`: a bare `docker
compose` resolves its own default project name from the compose file's
directory, which does not match the project name VS Code's "Reopen in
Container" / `devcontainer up` assign -- so it reports "service is not
running" even while the container is up. `find-devcontainer.sh` looks the
container up by its Compose working-dir label instead, which is stable
across all three ways of starting it.)

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
ssh -p <port-from-hermes-ssh-info> hermes@127.0.0.1 "echo `$SHELL"
```

It should print `/bin/bash` for the shell check, and `hermes --version` should
report the image-installed Hermes from `/usr/local/bin/hermes`.

### 5. Point Hermes at the container

On Windows, `.devcontainer/scripts/connect-hermes-desktop.ps1` does steps 3-5
for you: it reads `hermes-ssh-info` from the running container, adds/updates
a `Host` block for the alias in `%USERPROFILE%\.ssh\config` (a managed block
bounded by `# BEGIN/END hermes-devcontainer <alias>` comments, so re-running
it updates in place and leaves the rest of your SSH config untouched), then
writes the matching `terminal.backend`/`terminal.cwd` into Hermes'
`config.yaml` and the `TERMINAL_SSH_*` values into its `.env` (backing up all
three files first), then runs the connection check from step 4. It targets
`$env:HERMES_HOME` when that's set, otherwise `%USERPROFILE%\.hermes` — check
`echo $env:HERMES_HOME` first if you're not sure which one your Hermes
Desktop install actually reads (the script also prints which one it's using).

```powershell
./.devcontainer/scripts/connect-hermes-desktop.ps1
```

Or by hand: add the `Host` block `hermes-ssh-info` prints to
`~/.ssh/config`, and in the host Hermes' `config.yaml`:

```yaml
terminal:
  backend: ssh
  cwd: /workspaces/devcontainer-template   # the container's workspaceFolder
```

**`terminal.cwd` may not stick from a file edit.** Hermes Desktop has been
observed resetting `cwd` back to `.` on its own startup and demoting the
edited value to a comment — it appears to treat this field as owned by its
own UI rather than something to pick up from an external edit. `backend`
does not have this problem; only `cwd` does. If terminal actions keep
landing in the SSH login's home directory (`ls` showing dotfiles like
`.bashrc`, `.ssh`, `.hermes` instead of the workspace), set the working
directory from Hermes Desktop's own **Settings → Terminal/SSH Backend** UI
instead — that write does stick — then confirm `config.yaml` reflects it.

and in its `~/.hermes/.env`:

```ini
TERMINAL_SSH_HOST=127.0.0.1
TERMINAL_SSH_USER=hermes
TERMINAL_SSH_PORT=<port-from-hermes-ssh-info>
# only for a key ssh does not try by default:
# TERMINAL_SSH_KEY=C:\Users\<you>\.ssh\<key>
```

## Troubleshooting

- **`Permission denied (publickey)`** — the key Hermes uses is not in `~/.ssh`
  of the machine that started the container, or the container has not been
  restarted since you added it. Check what the container accepts with
  `docker compose exec -u hermes devcontainer sh -c 'cat ~/.ssh/authorized_keys'`
  (specify `-u hermes` — `exec` defaults to root — and quote the `~` so it
  expands inside the container instead of on your host shell).
- **Hermes reports SSH auth failure even though a manual `ssh` login works** —
  Hermes runs ssh non-interactively (`BatchMode`), which cannot supply a
  passphrase. If your private key has one, a plain `ssh -p <port> hermes@127.0.0.1`
  will succeed (after prompting for it) while
  `ssh -p <port> -o BatchMode=yes hermes@127.0.0.1 "echo hi"` fails with
  `Permission denied (publickey)`. Load the key into Windows' OpenSSH agent so
  it can be used without a prompt:

  ```powershell
  # once, as Administrator:
  Get-Service ssh-agent | Set-Service -StartupType Automatic
  Start-Service ssh-agent

  # then, as yourself (persists across reboots as long as the service keeps running):
  ssh-add "$env:USERPROFILE\.ssh\<key>"
  ```

  `connect-hermes-desktop.ps1` runs the same `BatchMode` check and prints this
  guidance automatically when it fails.
- **`Connection refused`** — the container may not have finished starting, or
  `docker compose up` was run without `-d` and got interrupted. Check
  `docker compose -f .devcontainer/docker-compose.yml ps`.
- **`REMOTE HOST IDENTIFICATION HAS CHANGED` / Hermes refuses to connect after a
  rebuild** — you may have deleted the `ssh-host-keys` volume. Clear the old
  host key on the machine running Hermes:

  ```powershell
  ssh-keygen -R "[127.0.0.1]:<port>"
  ```

- **Port `2222` is already in use** — set `HERMES_SSH_PORT` in
  `.devcontainer/.env` (copy `.devcontainer/.env.example` first), restart
  Compose, then run `hermes-ssh-info` again and update `TERMINAL_SSH_PORT`.
- **Port `2222` appears in VS Code's Ports view on a different local port** —
  VS Code auto-forwarding; ignore it. Use the Compose mapping printed by
  `hermes-ssh-info`.
- **No `~/.ssh` folder on the host** — Docker can create an empty one for the
  mount. Create a real key with `ssh-keygen` first, then restart the container.
