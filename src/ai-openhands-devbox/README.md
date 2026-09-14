# AI OpenHands Devbox (PowerShell)

A PowerShell-first development container with Claude Code, Codex, Azure tooling,
and [OpenHands Agent Canvas](https://www.openhands.dev/). It is a separate
product from `ai-hermes-devbox`: this template does not install Hermes, start a
Hermes gateway, or share Hermes credentials.

## What's included

- The published `ai-devbox` toolchain: PowerShell, Oh My Posh, Terminal-Icons,
  Node.js, Azure Bicep, GitHub CLI, Claude Code, and Codex.
- OpenHands Agent Canvas in a companion container at the VS Code-forwarded port
  `8000`. Open `/canvas` in the forwarded address.
- Persistent Docker named volumes for Claude, Codex, and Agent Canvas state.

## Prerequisites

1. Docker Desktop (or another Docker Engine) running. Windows users need WSL 2
   integration enabled for their Linux distribution.
2. VS Code with the Dev Containers extension, or the devcontainer CLI.
3. GitHub CLI authenticated with `read:packages`, because this template and its
   development-shell image are private.

```powershell
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
```

Apply the template and reopen the project in the devcontainer:

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox
```

## First run: ChatGPT OAuth through Codex ACP

This template supports a ChatGPT subscription login; an OpenAI Platform API key
is not required.

1. Open Agent Canvas at the forwarded port `8000`, path `/canvas`.
2. Open **Settings → Agent** and choose **ACP** with the **Codex** preset.
3. During onboarding, leave `OPENAI_API_KEY` blank. For the subscription login,
   enter `CODEX_AUTH_JSON`: the complete JSON content of the Codex CLI
   `~/.codex/auth.json` file.
4. Select **Open Workspace** and choose `/projects` before starting a
   conversation.

Agent Canvas stores this value in its persistent state volume and materializes
it only when starting the Codex ACP process. Do not commit `auth.json`, paste it
into `docker-compose.yml`, or place it in a repository `.env` file. Treat it as
a password-equivalent credential.

The OAuth login wins over an API key. If you later add `OPENAI_API_KEY`, Codex
continues using the ChatGPT subscription while the OAuth login remains valid.

## Security and limitations

Agent Canvas and Codex ACP can read, edit, and execute commands in the mounted
project at `/projects`. Use this template only for
repositories and prompts you trust.

The template does not mount `/var/run/docker.sock` and does not run privileged.
Consequently, agents cannot build or run Docker containers from inside Agent
Canvas. This is deliberate: enabling nested Docker substantially weakens the
isolation boundary.

## Persistence

- `claude-data` persists `~/.claude`.
- `codex-data` persists `~/.codex` for the VS Code development shell.
- `agent-canvas-data` persists Agent Canvas settings, conversations, and
  onboarding secrets.

Do not use `docker compose down -v` or remove these named volumes if you need
to retain their state.

## Image

The development shell is published as
`ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox-image`. Its
Dockerfile is a small `FROM ai-devbox-image` layer; OpenHands itself remains a
separate Compose service so its lifecycle and persisted state are independent
of the shell image.
