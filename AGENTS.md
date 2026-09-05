# devcontainer-template

Personal devcontainer, and a published "AI Devbox" dev container
template/image built from the same config.

## Layout

- `.devcontainer/` — the devcontainer used to develop this repo itself.
  Personal, host-specific (bind-mounts Windows host paths for Claude/Codex
  credentials and git config — see `.devcontainer/README.md`).
- `src/ai-devbox/.devcontainer/` — the same config, kept as an intentional
  duplicate of the root, but published via CI. Mirror any change across both.
- `src/ai-hermes-devbox/` — a second published template: the `ai-devbox`
  config plus the Hermes Agent (Nous Research), full browser + computer-use
  install. Its `Dockerfile.base` is `FROM ai-devbox-image` + the Hermes
  step, so it doesn't duplicate the base recipe. Published as
  `ai-hermes-devbox` / `ai-hermes-devbox-image`.
- `.github/workflows/publish.yml` — on push to `main`: bumps a `vX.Y.Z` git
  tag, stamps the version into both `devcontainer-template.json`s, publishes
  the `ai-devbox` and `ai-hermes-devbox` OCI devcontainer templates, then
  builds/pushes `ai-devbox-image` from its `Dockerfile.base` and
  `ai-hermes-devbox-image` (`FROM ai-devbox-image` + Hermes) after it.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.

All published packages under
`ghcr.io/wesleycamargo/devcontainer-template/` — the `ai-devbox` and
`ai-hermes-devbox` templates, the `ai-devbox-image` and
`ai-hermes-devbox-image` images — are **private**.

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

`src/ai-hermes-devbox/.devcontainer/Dockerfile.base` is the exception to
the "full recipe" rule: it's `FROM` the published `ai-devbox-image` plus
the Hermes install, so it carries none of the recipe above and isn't
mirrored against the others. A change to the shared recipe still only
needs to be made in the `ai-devbox` `Dockerfile.base` (root + `src`);
`ai-hermes-devbox` picks it up automatically through its `FROM`.

## Related repos

- `wesleycamargo/terminal-bootstrap` — the original Oh My Posh/Terminal-Icons
  installer script. `Dockerfile.base` reimplements the same setup natively;
  it's no longer invoked at container-create time (previously via
  `postCreateCommand`, which was slow since it reran on every container
  creation).
- `thecloudexplorers/devcontainer-template` (git remote `tce`) — a similar
  devcontainer-template repo this repo's publishing workflow was originally
  modeled on.
