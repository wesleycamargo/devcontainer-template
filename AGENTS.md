# devcontainer-template

Personal development container for maintaining published AI devcontainer
templates and images.

## Layout

- `.devcontainer/` — the repo's development container. Keep its tracked files
  identical to `src/ai-hermes-devbox/.devcontainer/`. Compose pulls the public
  `ai-hermes-devbox-image`; it needs the Docker host's Codex credential file
  (`~/.codex/auth.json`, or `DEVBOX_HOST_HOME/.codex/auth.json`).
- `src/ai-devbox/.devcontainer/` — the base template, published via CI. The
  build recipe (`Dockerfile`) lives only here; nothing else consumes this
  directory directly.
- `src/ai-hermes-devbox/` — a second published template based on the official
  `nousresearch/hermes-agent:main-desktop` image, pinned by multi-arch digest.
  Hermes, Webapp, browser and computer-use are prebuilt; this Dockerfile adds
  development tools and the existing SSH lifecycle. Keep user `hermes` at
  UID/GID 1000 and data at `/home/hermes/.hermes` for volume compatibility;
  the sealed runtime lives at `/opt/hermes`. Published as
  `ai-hermes-devbox` / `ai-hermes-devbox-image`. The root `.devcontainer/`
  mirrors this template for repository development.
- `src/ai-hermes-devbox-v1/` — a third published template: the pre-gateway
  generation of `ai-hermes-devbox`, frozen from `ai-hermes-devbox-v0.12.0`.
  Uses `FROM ai-devbox-image` + Hermes step, but no sshd, no SSH gateway and
  no Open WebUI — just Hermes' own gateway and dashboard on container
  loopback, started by `start-hermes.sh`. Published as `ai-hermes-devbox-v1` /
  `ai-hermes-devbox-v1-image`. Its publish workflow's tag prefix
  (`ai-hermes-devbox-v1-`) extends the older template's (`ai-hermes-devbox-v`),
  so both workflows post-filter `git tag --list` with a regex; do not drop
  that `grep -E` from either.
- `src/ai-openhands-devbox/` — a fourth published template: the `ai-devbox`
  development shell plus OpenHands Agent Canvas as a companion service.
  It is independent from Hermes and uses Codex ACP with the user-supplied
  `CODEX_AUTH_JSON` OAuth secret. Published as `ai-openhands-devbox` /
  `ai-openhands-devbox-image`.
- `src/ai-esp32-devbox/` — AI Devbox plus esptool/mpremote for MicroPython.
  Its image derives from ai-devbox-image. Publish the base first, then this
  variant; publishing the base does not trigger dependent image rebuilds.
  Serial access is opt-in through docker-compose.serial.yml.
- `docs/<id>.md` — the repo-side user-facing page for each published template
  (`docs/ai-devbox.md`, `docs/ai-hermes-devbox.md`,
  `docs/ai-hermes-devbox-v1.md`, `docs/ai-openhands-devbox.md`), linked from the root `README.md`'s Templates
  table. `src/<id>/README.md` is the copy that ships *inside* the template and
  lands in a consumer's project on `devcontainer templates apply`; the `docs/`
  page is what someone reads before applying it. They overlap, so a change to
  one template's behavior usually needs both updated.
- `.github/workflows/publish-<id>.yml` — one publish workflow per
  devcontainer under `src/` (`publish-ai-devbox.yml`,
  `publish-ai-hermes-devbox.yml`, `publish-ai-hermes-devbox-v1.yml`,
  `publish-ai-openhands-devbox.yml`). Each runs only when its own
  `src/<id>/**` changes, on `push` to `main`, or via `workflow_dispatch`. It
  bumps its own `<id>-vX.Y.Z` git tag (minor by
  default; `[major]`/`[minor]`/`[patch]` in the commit message overrides),
  stamps that version into `src/<id>/devcontainer-template.json`, publishes
  the `<id>` OCI template, and builds/pushes `<id>-image` from
  `src/<id>/.devcontainer/Dockerfile`. The workflows share nothing and
  run in parallel. Hermes uses its own pinned official base; variants derived
  from `ai-devbox-image` are **not** retriggered by a base rebuild.
- `.github/workflows/validate-hermes-gateway.yml` — builds the Hermes image with
  Buildx and a shared GHA layer cache, then runs
  `scripts/validate-hermes-gateway.sh all` for relevant Hermes pull requests
  and main-branch updates. The Hermes publish workflow repeats the same A-E
  and G (Webapp) checks as a required deployment gate; checkpoint F is
  a real Hermes Desktop connection and remains manual.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.
- `scripts/sync-template-agents.sh` — maintainer-only: mirrors the canonical
  root `.agents/` into `src/ai-devbox/.agents/`, `src/ai-hermes-devbox/.agents/`
  `src/ai-hermes-devbox-v1/.agents/`, and `src/ai-esp32-devbox/.agents/`, and keeps the Hermes hook (`configure-project-skills.sh`) copy identical. Run
  it (`--check` to only report) after any change under `.agents/`. It only
  mirrors files between the maintainer repo and template payloads.
- `scripts/setup-devcontainer-client.ps1` — one-time client-side setup for
  someone *consuming* a published template/image: installs Git/GitHub
  CLI/VS Code + the Dev Containers/Remote-WSL extensions via winget, Docker
  Engine inside WSL (never Docker Desktop), and the `devcontainer` CLI, then
  authenticates `gh` with `read:packages` and logs Docker in to ghcr.io.
  Idempotent; safe to re-run. Windows-only install automation; Linux prints
  manual install instructions.

The `ai-devbox`, `ai-esp32-devbox`, `ai-hermes-devbox` and
`ai-hermes-devbox-v1` templates and matching images under
`ghcr.io/wesleycamargo/devcontainer-template/` are **public**. Keep their current
package names and public visibility. Consumers do not need registry login;
publishing requires authenticated write access. OpenHands authentication is
documented separately in `docs/ai-openhands-devbox.md`.

## The devcontainer image

Each template under `src/<id>/.devcontainer/` has one `Dockerfile` — the
full build recipe (PowerShell installed directly via Microsoft's apt repo
so later `pwsh` steps work at build time, Oh My Posh + theme,
Terminal-Icons, an all-users PowerShell profile, the same prompt wired into
`/etc/bash.bashrc`, Node.js, the Claude Code/Codex
CLIs, Codex's `AGENTS.md` symlinked to `~/.claude/CLAUDE.md`).
`publish-<id>.yml` builds it and publishes it as `<id>-image`.

The `docker-compose.yml` next to it does **not** build anything: it sets
`image:` to that published package, so opening the devcontainer pulls the
prebuilt image instead of reinstalling everything from scratch. The root
`.devcontainer/` mirrors `ai-hermes-devbox` and pulls `ai-hermes-devbox-image`.

To bake a change into the shared image, edit the `Dockerfile` and push to
`main` — the publish workflow rebuilds `<id>-image`. For a throwaway local
layer, swap the `image:` line in `docker-compose.yml` for a `build:` block
pointing at a small `Dockerfile` that does `FROM <id>-image`.

`src/ai-hermes-devbox/.devcontainer/Dockerfile` consumes the official Hermes
image directly. Update its digest to upgrade Hermes; do not run the Hermes
installer or rebuild Webapp in this Dockerfile. Its development-tool versions
are maintained alongside ai-devbox's. It retains our SSH entrypoint rather
than the official s6 lifecycle, so Compose's `init: true` remains valid.

## Related repos

- `wesleycamargo/terminal-bootstrap` — the original Oh My Posh/Terminal-Icons
  installer script. The `Dockerfile` reimplements the same setup natively;
  it's no longer invoked at container-create time (previously via
  `postCreateCommand`, which was slow since it reran on every container
  creation).
- `thecloudexplorers/devcontainer-template` (git remote `tce`) — a similar
  devcontainer-template repo this repo's publishing workflow was originally
  modeled on.

## Project skills

Create reusable project skills in `.agents/skills/<skill-name>/`. Templates include these files; container startup does not download, update, or install skills. Agents with repository-local discovery can read them directly; otherwise ask the agent to read the desired `SKILL.md`.
