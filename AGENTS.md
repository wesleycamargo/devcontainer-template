# devcontainer-template

Personal devcontainer, and a published "AI Devbox" dev container
template/image built from the same config.

## Layout

- `.devcontainer/` — the devcontainer used to develop this repo itself.
  Personal, host-specific (bind-mounts Windows host paths for Claude/Codex
  credentials and git config — see `.devcontainer/README.md`). Pulls
  `ai-hermes-devbox-image`; its `devcontainer.json` and `docker-compose.yml`
  track `src/ai-hermes-devbox/.devcontainer/`, including the published
  template's host SSH port and public-key collection service (see
  `.devcontainer/SSH-BACKEND.md`). The image-owned scripts (`entrypoint.sh`,
  `start-services.sh`, `hermes-ssh-info.sh`, and the SSH drop-in) live only
  under `src/ai-hermes-devbox/.devcontainer/`; `.devcontainer/scripts/connect-hermes-desktop.ps1`
  and `.devcontainer/SSH-BACKEND.md` are plain copies of their
  `src/ai-hermes-devbox/.devcontainer/` counterparts (the latter trimmed of
  the template-apply steps), kept in sync by hand. Mirror Compose/devcontainer
  behavior across both directories when it applies.
- `src/ai-devbox/.devcontainer/` — the base template, published via CI. The
  build recipe (`Dockerfile`) lives only here; nothing else consumes this
  directory directly.
- `src/ai-hermes-devbox/` — a second published template: the `ai-devbox`
  config plus the Hermes Agent (Nous Research), full browser + computer-use
  install. Its `Dockerfile` is `FROM ai-devbox-image` + the Hermes
  step, so it doesn't duplicate the base recipe. Published as
  `ai-hermes-devbox` / `ai-hermes-devbox-image`. The root `.devcontainer/`
  tracks this one.
- `src/ai-openhands-devbox/` — a third published template: the `ai-devbox`
  development shell plus OpenHands Agent Canvas as a companion service.
  It is independent from Hermes and uses Codex ACP with the user-supplied
  `CODEX_AUTH_JSON` OAuth secret. Published as `ai-openhands-devbox` /
  `ai-openhands-devbox-image`.
- `.github/workflows/publish-<id>.yml` — one publish workflow per
  devcontainer under `src/` (`publish-ai-devbox.yml`,
  `publish-ai-hermes-devbox.yml`, `publish-ai-openhands-devbox.yml`). Each runs only when its own
  `src/<id>/**` changes, on `push` to `main`, or via `workflow_dispatch`. It
  bumps its own `<id>-vX.Y.Z` git tag (minor by
  default; `[major]`/`[minor]`/`[patch]` in the commit message overrides),
  stamps that version into `src/<id>/devcontainer-template.json`, publishes
  the `<id>` OCI template, and builds/pushes `<id>-image` from
  `src/<id>/.devcontainer/Dockerfile`. The workflows share nothing and
  run in parallel; `ai-hermes-devbox-image` is `FROM ai-devbox-image` but a
  base rebuild does **not** retrigger it.
- `.github/workflows/validate-hermes-gateway.yml` — runs
  `scripts/validate-hermes-gateway.sh build` and `all` for relevant Hermes
  pull requests and main-branch updates. The Hermes publish workflow repeats
  the same A-E contract checks as a required deployment gate; checkpoint F is
  a real Hermes Desktop connection and remains manual.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.
- `scripts/setup-devcontainer-client.ps1` — one-time client-side setup for
  someone *consuming* a published template/image: installs Git/GitHub
  CLI/VS Code + the Dev Containers/Remote-WSL extensions via winget, Docker
  Engine inside WSL (never Docker Desktop), and the `devcontainer` CLI, then
  authenticates `gh` with `read:packages` and logs Docker in to ghcr.io.
  Idempotent; safe to re-run. Windows-only install automation; Linux prints
  manual install instructions.

All published packages under
ghcr.io/wesleycamargo/devcontainer-template/` — the `ai-devbox`,
`ai-hermes-devbox`, and `ai-openhands-devbox` templates and their matching
images — are **private**.

## The devcontainer image

Each template under `src/<id>/.devcontainer/` has one `Dockerfile` — the
full build recipe (PowerShell installed directly via Microsoft's apt repo
so later `pwsh` steps work at build time, Oh My Posh + theme,
Terminal-Icons, an all-users PowerShell profile, the same prompt wired into
`/etc/bash.bashrc`, `esptool`/`mpremote`, Node.js, the Claude Code/Codex
CLIs, Codex's `AGENTS.md` symlinked to `~/.claude/CLAUDE.md`).
`publish-<id>.yml` builds it and publishes it as `<id>-image`.

The `docker-compose.yml` next to it does **not** build anything: it sets
`image:` to that published package, so opening the devcontainer pulls the
prebuilt image instead of reinstalling everything from scratch. The root
`.devcontainer/` does the same — it has no `Dockerfile` at all and pulls
`ai-hermes-devbox-image`.

To bake a change into the shared image, edit the `Dockerfile` and push to
`main` — the publish workflow rebuilds `<id>-image`. For a throwaway local
layer, swap the `image:` line in `docker-compose.yml` for a `build:` block
pointing at a small `Dockerfile` that does `FROM <id>-image`.

`src/ai-hermes-devbox/.devcontainer/Dockerfile` is the exception to the
"full recipe" rule: it's `FROM` the published `ai-devbox-image` plus the
Hermes install, so it carries none of the recipe above. A change to the
shared recipe only needs to be made in
`src/ai-devbox/.devcontainer/Dockerfile`; `ai-hermes-devbox` picks it up
automatically through its `FROM`.

## Related repos

- `wesleycamargo/terminal-bootstrap` — the original Oh My Posh/Terminal-Icons
  installer script. The `Dockerfile` reimplements the same setup natively;
  it's no longer invoked at container-create time (previously via
  `postCreateCommand`, which was slow since it reran on every container
  creation).
- `thecloudexplorers/devcontainer-template` (git remote `tce`) — a similar
  devcontainer-template repo this repo's publishing workflow was originally
  modeled on.
