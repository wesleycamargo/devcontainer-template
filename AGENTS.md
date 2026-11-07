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
  development tools (including image-baked `gh`) and a development-shell
  lifecycle, not an SSH server. Keep user `hermes` at
  UID/GID 1000 and data at `/home/hermes/.hermes` for volume compatibility;
  the sealed runtime lives at `/opt/hermes`. Published as
  `ai-hermes-devbox` / `ai-hermes-devbox-image`. The root `.devcontainer/`
  mirrors this template for repository development.
- `src/ai-openhands-devbox/` — the `ai-devbox`
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
  `docs/ai-esp32-devbox.md`, `docs/ai-openhands-devbox.md`), linked from the root `README.md`'s Templates
  table. `src/<id>/README.md` is the copy that ships *inside* the template and
  lands in a consumer's project on `devcontainer templates apply`; the `docs/`
  page is what someone reads before applying it. They overlap, so a change to
  one template's behavior usually needs both updated.
- `.github/workflows/publish-<id>.yml` — one publish workflow per
  devcontainer under `src/` (`publish-ai-devbox.yml`,
  `publish-ai-hermes-devbox.yml`, `publish-ai-esp32-devbox.yml`,
  `publish-ai-openhands-devbox.yml`). Publication requires its own
  `src/<id>/**` changes on `push` to `main`, or `workflow_dispatch`. It
  bumps its own `<id>-vX.Y.Z` git tag (minor by
  default; `[major]`/`[minor]`/`[patch]` in the commit message overrides),
  stamps that version into `src/<id>/devcontainer-template.json`, publishes
  the `<id>` OCI template, and builds/pushes `<id>-image` from
  `src/<id>/.devcontainer/Dockerfile`. The workflows share nothing and
  run in parallel. Hermes uses its own pinned official base; variants derived
  from `ai-devbox-image` are **not** retriggered by a base rebuild.
- `.github/workflows/publish-ai-hermes-devbox.yml` is the sole Hermes CI owner:
  preflight (`npm test`, `npm run check`, Python `test_*hermes*.py`, syntax) →
  one runtime validation → conditional deployment. Relevant pull requests and
  main updates validate; only main pushes changing `src/ai-hermes-devbox/**`
  or manual dispatch publish. Share the Buildx GHA layer cache; keep deployment
  gated by validation rather than adding a second validation workflow.
- `scripts/validate-hermes-runtime.sh build|all|A|B|C|D|E|G` — Docker-host
  validation: A raw shell/tools/no listeners; B default gateway/Webapp and
  dashboard opt-in; C isolated parallel projects with shared synthetic auth;
  D real disposable `devcontainer up` via `scripts/validate-hermes-devcontainer.sh`
  (CLI 0.90.0, actual features, frozen lockfile); E existing-volume migration;
  G Webapp HTTP auth. Keep credentials synthetic. VS Code browser opening is
  manual; SSH checkpoint F and external Desktop integration are removed.
- `scripts/setup_github_publishing.py` — one-time GitHub-side setup helper
  (workflow token permissions, package visibility check). Requires `gh`
  authenticated with `packages` scope.
- `scripts/sync-template-agents.sh` — maintainer-only: mirrors the canonical
  root `.agents/` into `src/ai-devbox/.agents/` and
  `src/ai-esp32-devbox/.agents/`. Run
  it (`--check` to only report) after any change under `.agents/`. It only
  mirrors files between the maintainer repo and template payloads.
- `scripts/setup-devcontainer-client.ps1` — one-time client-side setup for
  someone *consuming* a published template/image: installs Git/GitHub
  CLI/VS Code + the Dev Containers/Remote-WSL extensions via winget, Docker
  Engine inside WSL (never Docker Desktop), and the `devcontainer` CLI, then
  authenticates `gh` with `read:packages` and logs Docker in to ghcr.io.
  Idempotent; safe to re-run. Windows-only install automation; Linux prints
  manual install instructions.

The `ai-devbox`, `ai-esp32-devbox` and `ai-hermes-devbox`
templates and matching images under
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
are maintained alongside ai-devbox's. Bake GitHub CLI into the image; retain
the common-utils and Azure Bicep Dev Container features and their lockfile.

The Hermes consumer payload is exactly seven `.devcontainer/` files:
`.env.example`, `.gitignore`, `Dockerfile`, `devcontainer-lock.json`,
`devcontainer.json`, `docker-compose.yml` and `hermes_devbox.py`. Retain the
Dockerfile. The standard-library-only Python helper owns preparation, service
startup, CLI wrapping and Webapp opening; the image installs it at
`/usr/local/lib/hermes_devbox.py` with command symlinks. Public commands remain
`hermes`, `hermes-start-services` and `hermes-webapp-open`.

The custom entrypoint prepares data and optionally starts services, then execs
the image's `CMD ["sleep", "infinity"]`. This keeps a development shell alive;
it is not a daemon supervisor. Retain Compose `init: true`. Compose defaults to
`HERMES_AUTOSTART_SERVICES=1`: gateway/Webapp on `127.0.0.1:9120`, dashboard
off unless `HERMES_AUTOSTART_DASHBOARD=1`. The master switch
`HERMES_AUTOSTART_SERVICES=0` is shell-only, even with dashboard opt-in. Bare
`docker run` without the master flag is shell-only. Publish no host ports by
default; VS Code uses `hermes-webapp-open` and local forwarding. Keep
`shutdownAction: stopCompose` so closing VS Code stops the project. There is
no custom sshd, SSH host-key volume, port 2222, SSH overlay or Desktop SSH backend.
For existing installations, follow the migration in `docs/ai-hermes-devbox.md`:
back up settings, remove obsolete SSH configuration, pull/recreate with the same
project and named volumes. The old SSH host-key volume is not auto-deleted.

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

Create reusable project skills in `.agents/skills/<skill-name>/`. AI Devbox and
AI ESP32 Devbox include this tree; fresh AI Hermes Devbox templates include
neither bundled `.agents/` skills nor a project-skills configuration hook.
Container startup does not download, update, or install project skills. For
optional manual use, ask the agent to read the desired `SKILL.md`.

Reapplying the Hermes template does not automatically clean existing projects.
Follow the migration in `docs/ai-hermes-devbox.md`: compare obsolete helpers,
the old hook and bundled `.agents/` files with their previous template versions;
remove only unmodified copies and preserve user-created or edited files.
