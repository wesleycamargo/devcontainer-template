# AI Devbox — Dev Container Template

A PowerShell-based dev container with Claude Code / Codex agent CLIs, Azure
tooling, and MicroPython/ESP flashing support preconfigured.

## Usage

This package is private — Docker needs to be logged in to `ghcr.io` first:

```powershell
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin
```

### Via VS Code

1. Copy the image URL:

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-devbox:latest
   ```

2. Open the command palette (`Ctrl+Shift+P` / `Cmd+Shift+P` / `F1`)
3. Run **Dev Containers: Add Dev Container Configuration Files**
4. Paste the image URL into the search box
5. Select it and follow the prompts to create the dev container configuration files
6. Reopen the folder in the dev container when prompted

### Via `devcontainer.json`

```json
{
  "image": "ghcr.io/wesleycamargo/devcontainer-template/ai-devbox:latest"
}
```

### Via devcontainer CLI

```powershell
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-devbox
```

## Image

Applying the template gives you a `docker-compose.yml` that pulls
`ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image` — a prebuilt
image (published by `.github/workflows/publish-ai-devbox.yml` from
`src/ai-devbox/.devcontainer/Dockerfile`) with all the tools below already
installed. There's no local build; rebuilds just re-pull the image. For a
local customization layer, swap the `image:` line for a `build:` block with
a `Dockerfile` that does `FROM` the image.

## Included tools

| Tool                        | Purpose                                |
| ---------------------------- | --------------------------------------- |
| PowerShell 7                 | Primary shell                           |
| Azure Bicep                  | IaC authoring and deployment            |
| GitHub CLI                   | Repository and PR workflows             |
| Claude Code CLI               | AI-assisted development                 |
| Codex CLI                    | AI-assisted development                 |
| esptool / mpremote            | MicroPython/ESP board flashing and REPL |

See [`src/ai-devbox/README.md`](src/ai-devbox/README.md) for full setup
details, prerequisites, and configuration notes.

## Hermes variant

[`ai-hermes-devbox`](src/ai-hermes-devbox/README.md) is a second published
template: everything above plus the [Hermes Agent](https://hermes-agent.nousresearch.com/)
from Nous Research (full browser + computer-use install). Apply it with
`-t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox`.

[github.com/wesleycamargo/devcontainer-template](https://github.com/wesleycamargo/devcontainer-template)
