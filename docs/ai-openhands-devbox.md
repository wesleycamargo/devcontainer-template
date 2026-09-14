# AI OpenHands Devbox

`ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox`

[AI Devbox](ai-devbox.md) plus
[OpenHands Agent Canvas](https://www.openhands.dev/) as a companion service. No
Hermes: separate product, separate credentials, no Hermes gateway.

## Command line

```powershell
# 1. log in — the packages are private
gh auth refresh -h github.com -s read:packages
gh auth token | docker login ghcr.io -u wesleycamargo --password-stdin

# 2. apply into your project
devcontainer templates apply -w . -t ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox
```

Then **Reopen in Container** and open forwarded port **8000**, path
**`/canvas`**. Windows needs WSL 2 integration enabled for your distro.

## VS Code UI

1. Do the `docker login` above — it must exist where VS Code runs the
   devcontainer CLI: WSL for a WSL folder, Windows for a Windows folder.
2. Command palette (`Ctrl+Shift+P` / `F1`) → **Dev Containers: Add Dev Container
   Configuration Files**.
3. Paste this into the search box — the `ghcr.io/` prefix is required, or the
   template isn't found ("Failed to fetch template manifest"):

   ```
   ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox
   ```

4. Follow the prompts, then **Reopen in Container** and open port **8000**,
   path **`/canvas`**.

## First run: ChatGPT login, no API key

1. In Canvas: **Settings → Agent** → **ACP** with the **Codex** preset.
2. During onboarding leave `OPENAI_API_KEY` blank; set `CODEX_AUTH_JSON` to the
   full contents of the Codex CLI's `~/.codex/auth.json`.
3. **Open Workspace** → `/projects/devcontainer-template`, then start a
   conversation.

`CODEX_AUTH_JSON` is password-equivalent. Canvas keeps it in its state volume
and materializes it only when starting Codex ACP — never commit it, put it in
`docker-compose.yml`, or drop it in a repo `.env`. A valid OAuth login wins over
an `OPENAI_API_KEY` added later.

## Fix after applying

`/workspaces/devcontainer-template` in `devcontainer.json` (`workspaceFolder`)
and both project mounts in `docker-compose.yml` — `/workspaces/…` for the shell,
`/projects/…` for Canvas — need your folder name.

## Notes

- **Blast radius**: Canvas and Codex ACP can read, edit and run commands in the
  mounted project. Use it only on repos and prompts you trust.
- **No nested Docker**: `/var/run/docker.sock` is deliberately not mounted and
  nothing runs privileged, so agents can't build or run containers — that would
  substantially weaken the isolation boundary.
- **Persistence**: `claude-data`, `codex-data`, and `agent-canvas-data`
  (settings, conversations, the stored `CODEX_AUTH_JSON`).
  `docker compose down -v` destroys all three.
- **The image**: the dev shell is `ai-openhands-devbox-image`, a thin
  `FROM ai-devbox-image` layer; Canvas stays a separate service pulling
  `ghcr.io/openhands/agent-canvas`, so their lifecycles are independent.

Source: [`src/ai-openhands-devbox/`](../src/ai-openhands-devbox/) ·
[`Dockerfile`](../src/ai-openhands-devbox/.devcontainer/Dockerfile) ·
[`publish-ai-openhands-devbox.yml`](../.github/workflows/publish-ai-openhands-devbox.yml) ·
[config checks](../scripts/test_ai_openhands_devbox.sh) ·
[in-template README](../src/ai-openhands-devbox/README.md)
