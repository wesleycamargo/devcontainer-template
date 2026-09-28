# AI Hermes Devbox v1

`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-v1`

[AI Devbox](ai-devbox.md) plus the
[Hermes Agent](https://hermes-agent.nousresearch.com/) — the **pre-gateway**
generation of [AI Hermes Devbox](ai-hermes-devbox.md), frozen from
`ai-hermes-devbox-v0.12.0`.

Compared with `ai-hermes-devbox` it drops, deliberately:

- the image-owned **SSH gateway** (`entrypoint.sh`, `start-services.sh`,
  `sshd-hermes-gateway.conf`, `hermes-ssh-info.sh`) and the Hermes Desktop
  connection flow,
- **sshd entirely** — no `sshd` feature, no published `2222`, no host
  public-key collection,
- the **Open WebUI** companion service and its generated `.openwebui.env`.

What's left is Hermes' own gateway and dashboard on container loopback, plus
the same agent CLIs and SDLC skills as the base. Pick this one when you want
Hermes inside the container and nothing listening outside it; pick
`ai-hermes-devbox` when you want to drive it from Hermes Desktop on the host.

## Command line

```powershell
# 1. log in — the packages are private
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin

# 2. apply into your project
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-v1
```

Then **Reopen in Container**. Windows needs WSL 2 integration enabled for your
distro.

## VS Code UI

1. Do the `docker login` above — it must exist where VS Code runs the
   devcontainer CLI: WSL for a WSL folder, Windows for a Windows folder.
2. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
3. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-v1
   ```

4. Follow the prompts, then **Reopen in Container**.

## First run

Hermes ships installed but unconfigured — the image build passes
`--skip-setup`. Run `hermes` in the container to set up keys and connectors; it
writes `~/.hermes/.env` and `~/.hermes/config.yaml`. Then restart the container
or run `bash .devcontainer/start-hermes.sh`, which brings up the gateway on
`127.0.0.1:8642` and the dashboard on `127.0.0.1:9119`. `devcontainer.json`
forwards **9119**; nothing is published to the host by Docker.

**Codex / ChatGPT shortcut**: if `~/.codex/auth.json` holds a valid ChatGPT
OAuth login, `start-hermes.sh` seeds `model.provider: openai-codex` /
`model.default: gpt-5.6-terra` once, guarded by
`~/.hermes/.codex-default-seeded`. Delete that marker to re-seed; `hermes model`
overrides it and the marker keeps the seed from overriding your choice back.

## Notes

- **Nothing listens outside the container.** Both Hermes services bind
  container loopback and reach you through VS Code port forwarding, which a
  Docker published port can't do for a loopback listener.
- **Persistence**: `claude-data`, `codex-data`, `hermes-data` — the last one
  holds credentials, sessions, memory, skills and logs, and is initialized from
  the image so the installed Hermes runtime survives a rebuild.
  `docker compose down -v` destroys all three.
- **Workspace folder**: `workspaceFolder` is
  `/workspaces/${localWorkspaceFolderBasename}` and the bind mount maps the
  project's parent into `/workspaces`, so no post-apply edit is needed.
- **Project skills**: compose runs `sync-project-skills` on every start with
  `SYNC_SKILLS_AGENTS: "*"`, installing `.agents/skills/` for every agent CLI
  present.
- **The image**: `ai-hermes-devbox-v1-image`, a thin `FROM ai-devbox-image`
  layer plus the full Hermes install (Playwright/Chromium and computer-use
  included). A base rebuild does not retrigger it.

Source: [`src/ai-hermes-devbox-v1/`](../src/ai-hermes-devbox-v1/) ·
[`Dockerfile`](../src/ai-hermes-devbox-v1/.devcontainer/Dockerfile) ·
[`publish-ai-hermes-devbox-v1.yml`](../.github/workflows/publish-ai-hermes-devbox-v1.yml) ·
[in-template README](../src/ai-hermes-devbox-v1/README.md)
