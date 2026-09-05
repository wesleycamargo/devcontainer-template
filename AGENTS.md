# devcontainer-template

Personal devcontainer, and a published "AI Devbox" dev container
template/image built from the same config.

## Layout

- `.devcontainer/` — the devcontainer used to develop this repo itself.
  Personal, host-specific (bind-mounts Windows host paths for Claude/Codex
  credentials and git config — see `.devcontainer/README.md`).
- `src/ai-devbox/.devcontainer/` — the same config, kept as an intentional
  duplicate of the root, but published via CI. Mirror any change across both.
- `.github/workflows/publish.yml` — on push to `main`: bumps a `vX.Y.Z` git
  tag, updates `src/ai-devbox/devcontainer-template.json`'s version, publishes
  the `ai-devbox` OCI devcontainer template, then builds/pushes
  `ai-devbox-image` from `Dockerfile.base`.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.

All published packages
(`ghcr.io/wesleycamargo/devcontainer-template/ai-devbox` template and
`ai-devbox-image` image) are **private**.

## Dockerfile / Dockerfile.base split

Each `.devcontainer/` directory has two Dockerfiles:

- `Dockerfile.base` — the full build recipe (PowerShell installed directly
  via Microsoft's apt repo so later `pwsh` steps work at build time, Oh My
  Posh + theme, Terminal-Icons, an all-users PowerShell profile, the same
  prompt wired into `/etc/bash.bashrc`, `esptool`/`mpremote`, Node.js, the
  Claude Code/Codex CLIs, Codex's `AGENTS.md` symlinked to
  `~/.claude/CLAUDE.md`). CI builds this and publishes it as
  `ai-devbox-image`.
- `Dockerfile` — thin, just `FROM` that published image. `docker-compose.yml`
  actually builds this one, so local rebuilds pull the prebuilt image instead
  of reinstalling everything from scratch.

Add personal/project customizations to `Dockerfile` (fast, local-only,
layers on top of the published base). Changes meant to be baked into the
shared base for everyone go in `Dockerfile.base` instead, and only take
effect after a push to `main` publishes a new `ai-devbox-image`.

## Related repos

- `wesleycamargo/terminal-bootstrap` — the original Oh My Posh/Terminal-Icons
  installer script. `Dockerfile.base` reimplements the same setup natively;
  it's no longer invoked at container-create time (previously via
  `postCreateCommand`, which was slow since it reran on every container
  creation).
- `thecloudexplorers/devcontainer-template` (git remote `tce`) — a similar
  devcontainer-template repo this repo's publishing workflow was originally
  modeled on.
