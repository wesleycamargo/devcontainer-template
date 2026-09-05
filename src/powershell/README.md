# Devcontainer notes

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
app holds locks on) that doesn't belong in a Linux container. The
`Dockerfile` creates the container's own `~/.codex` (owned by `vscode`,
with its own `config.toml`) so the `auth.json` bind mount doesn't cause
Docker to create the parent directory as root. Sharing just the
credentials file means token refreshes made in either environment stay in
sync in both directions.

### Using this on a different machine

These are personal host paths for this machine. On a different host
account (or a different OS), edit or remove the `volumes` entries in
`docker-compose.yml` rather than copying credential files into the image.
