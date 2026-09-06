# Devcontainer notes

## The image

This devcontainer has no Dockerfile. `docker-compose.yml` sets `image:` to
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`, the
prebuilt image with the full build recipe (PowerShell, Oh My Posh,
Terminal-Icons, Node, the agent CLIs) plus the Hermes Agent (Nous
Research) with the full browser + computer-use install — so opening it
pulls the image instead of reinstalling everything. `docker login
ghcr.io` first (private package).

The recipe is split across two files:
`src/ai-devbox/.devcontainer/Dockerfile` (the base) and
`src/ai-hermes-devbox/.devcontainer/Dockerfile` (`FROM ai-devbox-image` +
the Hermes install), published by `publish-ai-devbox.yml` and
`publish-ai-hermes-devbox.yml`. Anything worth baking in goes there and
needs a push to `main`. For a throwaway local tweak, swap the `image:`
line for a `build:` block with a `Dockerfile` that does `FROM` the image.

## Hermes

`hermes`, `hermes-agent`, and `hermes-acp` are on `PATH`. Hermes is
installed but not configured — run `hermes` inside the container to set up
API keys (writes `~/.hermes/.env` and `~/.hermes/config.yaml`). That
directory is backed by the `hermes-data` Docker named volume, which persists
Hermes credentials, sessions, memory, skills, and logs across normal
devcontainer rebuilds. Do not run `docker compose down -v` or remove the
named volume if you need to retain it.
After completing setup, restart the devcontainer or run
`bash .devcontainer/start-hermes.sh` to start the gateway and dashboard.

`postStartCommand` runs `.devcontainer/start-hermes.sh` on every container
start. It first does a one-time Codex seed: if `~/.codex/auth.json` is
bind-mounted (a ChatGPT OAuth login) with a currently-valid access token,
it copies those tokens into Hermes' auth store and sets `model.provider:
openai-codex` / `model.default: gpt-5.6-terra` in `config.yaml` — the same
import `hermes model` → "ChatGPT or Codex Subscription" performs (it calls
Hermes' internal helpers directly; `hermes auth add openai-codex` is not
used, as that only starts a fresh device-code login). It runs once, guarded
by `~/.hermes/.codex-default-seeded` (delete that marker plus `hermes auth
logout openai-codex` to re-seed); a lapsed token — Codex refresh tokens are
single-use — just defers it to the next start; picking another provider
with `hermes model` is safe, the marker stops the seed from overriding it.

The script creates `.devcontainer/.openwebui.env` on its first run. It is
ignored by Git and contains generated API and Open WebUI session keys. The
same file enables Hermes' OpenAI-compatible API and configures Open WebUI,
without adding secrets to either image or `~/.hermes/.env`.

It then starts the Hermes gateway on `127.0.0.1:8642` and the dashboard on
`127.0.0.1:9119`, logging to `~/.hermes/logs/gateway.out` and
`~/.hermes/logs/dashboard.out`. Neither loopback service is exposed directly
to the host.

## Open WebUI

`docker-compose.yml` runs Open WebUI as a companion service with the same
network namespace as the devcontainer. It connects to Hermes at
`http://127.0.0.1:8642/v1`, so tool calls run in this devcontainer while port
`8642` remains inaccessible outside it. Open WebUI data is kept in the named
`open-webui-data` volume and survives normal Compose stops and rebuilds.

VS Code forwards the dashboard on port `9119` and Open WebUI on port `8080`.
Open the forwarded `8080` address, create the first account (it becomes the
local admin), then choose `hermes-agent` in the model picker. The first Open
WebUI launch can take a little longer while its application data initializes.

To rotate the generated API key, delete `.devcontainer/.openwebui.env` before
rebuilding. Open WebUI stores its connection on first launch, so also update
the connection in its Admin Settings or reset its named data volume before
using the replacement key.

## Persisting Claude Code / Codex credentials

`docker-compose.yml` uses named Docker volumes for `~/.claude` and
`~/.codex`, so it starts on a host that has neither directory and keeps
logins made inside the container across normal rebuilds. Docker initializes
each volume from the image on first use, so Codex keeps its Linux-native
configuration rather than inheriting Windows desktop-app state.

The container intentionally does not read host credentials or Git settings.
Run `claude`, `codex`, and `git config --global ...` inside the container to
configure them. Do not remove the `claude-data` or `codex-data` volumes if
you need to retain those settings.
