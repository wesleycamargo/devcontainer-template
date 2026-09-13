# Devcontainer notes

## The image

This devcontainer has no Dockerfile. `docker-compose.yml` pulls
`ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image`, the
prebuilt base devbox plus Hermes Agent, browser/computer-use dependencies, and
an image-owned SSH gateway. Authenticate to the private package first with
`docker login ghcr.io`.

The recipe is split across `src/ai-devbox/.devcontainer/Dockerfile` for the
base image and `src/ai-hermes-devbox/.devcontainer/Dockerfile` for the Hermes
layer. Anything worth baking in goes there and needs a push to `main`. For a
throwaway local tweak, swap this directory's `image:` line for a `build:` block
with a tiny Dockerfile that does `FROM` the image.

## Hermes

`hermes`, `hermes-agent`, and `hermes-acp` are on `PATH`. Hermes' code and
runtime live in the image under `/usr/local/lib/hermes-agent` and `/opt/hermes`;
`~/.hermes` is user data only: `.env`, `config.yaml`, credentials, sessions,
logs, memories, and skills. That directory is backed by the `hermes-data` named
volume, so normal rebuilds keep your state. Do not run `docker compose down -v`
or remove the named volume if you need to retain it.

Run `hermes` inside the container once to set up API keys and connectors. On
container start, the image entrypoint creates the user-data directories, warns
about old runtime leftovers such as `~/.hermes/hermes-agent` or `~/.hermes/node`,
and then starts the OpenSSH daemon as PID 1. Those leftovers are no longer used;
remove them by hand only after confirming you do not need anything inside them.

This local development container does not publish the SSH port or collect host
public keys. It still starts the daemon internally because the same image is used
by the published template; the daily-driver root `.devcontainer/` keeps it
unreachable from the host.

## Hermes services and Open WebUI

Compose sets `HERMES_AUTOSTART_SERVICES=1`, so the entrypoint runs
`hermes-start-services` as `vscode` after SSH setup. That helper is safe to run
again by hand and never creates duplicate gateway or dashboard processes.

The helper first performs the one-time Codex seed: if `~/.codex/auth.json` has a
currently-valid ChatGPT/Codex OAuth token, it copies those tokens into Hermes'
auth store and sets `model.provider: openai-codex` / `model.default:
gpt-5.6-terra`. It is guarded by `~/.hermes/.codex-default-seeded`; delete that
marker plus `hermes auth logout openai-codex` to re-seed. A stale Codex token
just defers the seed to the next start.

It then creates `.devcontainer/.openwebui.env` on first run. The file is ignored
by Git and holds generated Hermes API and Open WebUI session keys. The Hermes
gateway listens on `127.0.0.1:8642`, the dashboard on `127.0.0.1:9119`, and logs
go to `~/.hermes/logs/gateway.out` and `~/.hermes/logs/dashboard.out`.

Open WebUI runs as a companion service sharing the devcontainer's network
namespace, so it reaches Hermes at `http://127.0.0.1:8642/v1` without publishing
the API to the host. VS Code forwards the dashboard on `9119` and Open WebUI on
`8080`. Open the forwarded `8080` address, create the first account, then select
`hermes-agent` in the model picker.

To rotate the generated API key, delete `.devcontainer/.openwebui.env` before
rebuilding. Open WebUI stores its connection on first launch, so also update the
connection in Admin Settings or reset the `open-webui-data` volume before using
the replacement key.

## Persisting Claude Code / Codex credentials

`docker-compose.yml` uses named Docker volumes for `~/.claude` and `~/.codex`,
so it starts on a host that has neither directory and keeps logins made inside
the container across normal rebuilds. Docker initializes each volume from the
image on first use, preserving Linux-native CLI configuration rather than
inheriting Windows desktop-app state.

The container intentionally does not read host credentials or Git settings. Run
`claude`, `codex`, and `git config --global ...` inside the container to
configure them. Do not remove the `claude-data` or `codex-data` volumes if you
need to retain those settings.
