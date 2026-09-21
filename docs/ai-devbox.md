# AI Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-devbox`

The base template: PowerShell 7, the Claude Code and Codex CLIs, Azure Bicep,
GitHub CLI, Node.js 20, esptool/mpremote. The other two templates build on it.

## Command line

```powershell
# 1. log in — the package is private
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin

# 2. apply into your project
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-devbox
```

Then **Reopen in Container** in VS Code.

## VS Code UI

1. Do the `docker login` above — it must exist where VS Code runs the
   devcontainer CLI: WSL for a WSL folder, Windows for a Windows folder.
2. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
3. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-devbox
   ```

4. Follow the prompts, then **Reopen in Container**.

## Fix two things after applying

| What | Where |
| --- | --- |
| `/workspaces/devcontainer-template` → your folder name | `devcontainer.json` `workspaceFolder` + the bind mount in `docker-compose.yml` |
| Credential mounts pointing at `/mnt/c/Users/Wesle/...` (`.claude`, `.codex/auth.json`, `.gitconfig`, `.git-credentials`) | `docker-compose.yml` — repoint at your host paths or delete them |

Dead credential paths are the usual reason the agent CLIs ask you to log in
again after a rebuild. (Hermes and OpenHands use named volumes and need no such
edit.)

## Notes

- **Prerequisites**: Docker running, plus VS Code + Dev Containers or the
  [devcontainer CLI](https://github.com/devcontainers/cli)
  (`npm install -g @devcontainers/cli`).
- **The image**: `docker-compose.yml` pulls the prebuilt `ai-devbox-image` and
  builds nothing; the `Dockerfile` beside it is the recipe CI builds from. Docker
  caches `:latest`, so `docker pull` when a new `ai-devbox-v*` tag lands.
- **Your own layers**: a `Dockerfile.local` that does `FROM …/ai-devbox-image`,
  pointed at by a `build:` block instead of `image:`.
- **Shared agent config**: Codex's `AGENTS.md` is symlinked to
  `~/.claude/CLAUDE.md`, so both CLIs read one set of global instructions.
- **Just the image**, no Compose wiring:
  `{ "image": "ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest" }`

Source: [`src/ai-devbox/`](../src/ai-devbox/) ·
[`Dockerfile`](../src/ai-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-devbox.yml`](../.github/workflows/publish-ai-devbox.yml) ·
[in-template README](../src/ai-devbox/README.md)

## AI-native SDLC framework

AI Devbox includes the portable .agents/ SDLC skills. They guide an agent from intent through specification, planning, implementation, and independent validation while storing real work items only in sdlc/<work-item>/. Read the [AI-native SDLC framework guide](ai-native-sdlc.md) for the workflow and invocation examples.

## Skills stay in sync automatically

`.agents/skills` is the single source of truth. On every container start,
`sync-project-skills` pulls the latest skills from the upstream template repo
into your project (custom skills you've added under `.agents/skills` are
preserved), then installs the merged set for Claude Code and Codex — both
inside the project and, so they work from any directory, at each agent's
global/home-directory level too. It's driven by `SYNC_SKILLS_USER` /
`SYNC_SKILLS_AGENTS` / `SYNC_SKILLS_UPSTREAM` in `docker-compose.yml`; run
`sync-project-skills` by hand inside the container to force a refresh
mid-session.