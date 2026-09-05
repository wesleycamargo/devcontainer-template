# Devcontainer notes

## The image

This devcontainer has no Dockerfile. `docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`, the
prebuilt image with the full build recipe (PowerShell, Oh My Posh,
Terminal-Icons, Node, the agent CLIs) plus the Hermes Agent (Nous
Research) with the full browser + computer-use install — so opening it
pulls the image instead of reinstalling everything. `docker login
ghcr.io` first (private package).

The recipe is split across two files:
`src/ai-devbox/.devcontainer/Dockerfile` (the base) and
`src/ai-hermes-devbox/.devcontainer/Dockerfile` (`FROM ai-devbox-image` +
the Hermes install), published by `publish-ai-devbox.yml` and
`publish-ai-hermes-devbox.yml`. Anything worth baking in goes there and
needs a push to `main`. For a throwaway local tweak, swap the `image:`
line for a `build:` block with a `Dockerfile` that does `FROM` the image.

## Hermes

`hermes`, `hermes-agent`, and `hermes-acp` are on `PATH`. Hermes is
installed but not configured — run `hermes` inside the container to set up
API keys (writes `~/.hermes/.env` and `~/.hermes/config.yaml`). That
`~/.hermes` is container-local; see the commented-out mounts in
`docker-compose.yml` to persist it from a Windows-host copy.

`docker-compose.yml` publishes the dashboard (`9119`) and gateway API
(`8642`) to the host, and `postStartCommand` runs
`.devcontainer/start-hermes.sh` on every container start to bring both up
bound to `0.0.0.0` (Hermes binds to `127.0.0.1` by default, which the
published ports can't reach). The script backgrounds them, skips one
that's already running, logs to `~/.hermes/logs/`, and no-ops until Hermes
is configured. Two prerequisites in `~/.hermes/`, both from `hermes`
first-run:

- **Dashboard** — an auth provider under `dashboard:` in `config.yaml`, or
  Hermes refuses to bind non-loopback and the service just exits.
- **Gateway** — `API_SERVER_KEY` in `.env` (`API_SERVER_HOST=0.0.0.0` is
  passed by the script, so `config.yaml` doesn't need editing).

To disable auto-start, drop the `postStartCommand` line from
`devcontainer.json`.

## Persisting Claude Code / Codex credentials

Without help, both CLIs need you to log in again every time the container
is rebuilt, since a fresh container has no `~/.claude` or `~/.codex`. To
avoid that, `docker-compose.yml` bind-mounts the live credential files from
the Windows host instead of baking them into the image (an image COPY
would leave tokens sitting in `docker history`, and wouldn't pick up
refreshed tokens after login):

- `/mnt/c/Users/Wesle/.claude` -> `/home/vscode/.claude`
- `/mnt/c/Users/Wesle/.claude.json` -> `/home/vscode/.claude.json`
- `/mnt/c/Users/Wesle/.codex/auth.json` -> `/home/vscode/.codex/auth.json`

Claude's mount is the whole `~/.claude` dir, sourced from the WSL install
(native filesystem, correct `0600` perms, and uid 1000 matches the
container's `vscode` user).

Codex only exists on this machine's Windows side, so that mount crosses
`/mnt/c` into the Windows user profile. Only `auth.json` is mounted, not
all of `~/.codex`: the rest of that directory is Windows desktop-app state
(`config.toml` with Windows-only paths, plugin dirs, live SQLite files the
app holds locks on) that doesn't belong in a Linux container.
The image build creates the container's own `~/.codex` (owned by `vscode`,
with its own `config.toml`) so the `auth.json` bind mount doesn't cause
Docker to create the parent directory as root. Sharing just the
credentials file means token refreshes made in either environment stay in
sync in both directions.

### Using this on a different machine

These are personal host paths for this machine. On a different host
account (or a different OS), edit or remove the `volumes` entries in
`docker-compose.yml` rather than copying credential files into the image.
