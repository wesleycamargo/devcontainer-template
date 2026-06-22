# Engineering Tools — Dev Container Template

A PowerShell-based dev container for Azure and Infrastructure-as-Code engineering. Provides a fully configured environment for cloud development, governance, and AI-assisted workflows.

## Usage

### Via VS Code

1. Copy the image URL:

```
ghcr.io/wesleycamargo/devcontainer-template/engineering-tools:latest
```

2. Open the command palette (`Ctrl+Shift+P` / `Cmd+Shift+P` / `F1`)
3. Run **Dev Containers: Add Dev Container Configuration Files**
   ![alt text](docs/images/add-devcontainer.png)
4. In the search box, type the URL of the dev container image: `ghcr.io/wesleycamargo/devcontainer-template/engineering-tools:latest`
   ![alt text](docs/images/devcontainer-url.png)
5. Select the image and follow the prompts to create the dev container configuration files.
6. Reopen the folder in the dev container when prompted.

### Via `devcontainer.json`

```json
{
  "image": "ghcr.io/wesleycamargo/devcontainer-template/engineering-tools:latest"
}
```

## Platform

Optimised for Azure-hosted development environments (GitHub Codespaces, Azure Container Instances, Azure Dev Box).

## Repository

## Included tools

| Tool                  | Purpose                                    |
| --------------------- | ------------------------------------------ |
| PowerShell 7          | Primary shell                              |
| Azure CLI             | Azure resource management                  |
| Bicep                 | IaC authoring and deployment               |
| GitHub CLI            | Repository and PR workflows                |
| Claude Code CLI       | AI-assisted development                    |
| Pi Coding Agent CLI   | AI-assisted development with Azure Foundry |
| draw.io               | Architecture diagramming                   |
| Az PowerShell modules | Azure automation and scripting             |
| PSRule.Rules.Azure    | Azure governance and compliance validation |

## Pi Azure Foundry authentication

This dev container includes a project-local Pi configuration for Azure Foundry:

- `.pi/agent/models.json` defines the `azure-foundry-user` provider and gets bearer tokens from the already-authenticated Azure CLI.
- `.pi/extensions/azure-foundry-responses.ts` routes that provider through Pi's `openai-responses` API because the `gpt-5.3-codex` deployment uses `/openai/v1/responses`.

After signing in with `az login`, run:

```bash
pi --provider azure-foundry-user --model gpt-5.3-codex
```

See [docs/pi-azure-foundry-auth.md](docs/pi-azure-foundry-auth.md) for verification and troubleshooting details.

## VS Code extensions

| Extension             | Purpose                  |
| --------------------- | ------------------------ |
| Bicep                 | Bicep language support   |
| Azure Resource Groups | Azure portal integration |
| Prettier              | Code formatting          |
| Live Share            | Collaborative editing    |
| Claude Dev            | AI code assistant        |

[github.com/wesleycamargo/devcontainer-template](https://github.com/wesleycamargo/devcontainer-template)
