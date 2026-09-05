# devcontainer-template

Personal devcontainer, and a published "AI Devbox" dev container
template/image built from the same config.

## Layout

- `.devcontainer/` — the devcontainer used to develop this repo itself.
  Personal, host-specific (bind-mounts Windows host paths for Claude/Codex
  credentials and git config — see `.devcontainer/README.md`).
- `src/ai-devbox/.devcontainer/` — published via CI. Its `devcontainer.json`
  and `docker-compose.yml` are near-duplicates of the root's; mirror changes
  to those across both. The build recipe (`Dockerfile`) lives only here — the
  root pulls the published image instead of carrying its own copy.
- `src/ai-hermes-devbox/` — a second published template: the `ai-devbox`
  config plus the Hermes Agent (Nous Research), full browser + computer-use
  install. Its `Dockerfile` is `FROM ai-devbox-image` + the Hermes
  step, so it doesn't duplicate the base recipe. Published as
  `ai-hermes-devbox` / `ai-hermes-devbox-image`.
- `.github/workflows/publish-<id>.yml` — one publish workflow per
  devcontainer under `src/` (`publish-ai-devbox.yml`,
  `publish-ai-hermes-devbox.yml`). Each runs only when its own
  `src/<id>/**` changes, on `push` to `main`, or via `workflow_dispatch`. It
  bumps its own `<id>-vX.Y.Z` git tag (minor by
  default; `[major]`/`[minor]`/`[patch]` in the commit message overrides),
  stamps that version into `src/<id>/devcontainer-template.json`, publishes
  the `<id>` OCI template, and builds/pushes `<id>-image` from
  `src/<id>/.devcontainer/Dockerfile`. The workflows share nothing and
  run in parallel; `ai-hermes-devbox-image` is `FROM ai-devbox-image` but a
  base rebuild does **not** retrigger it.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.

All published packages under
`ghcr.io/wesleycamargo/devcontainer-template/` — the `ai-devbox` and
`ai-hermes-devbox` templates, the `ai-devbox-image` and
`ai-hermes-devbox-image` images — are **private**.

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
`.devcontainer/` does the same and has no `Dockerfile` at all.

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
