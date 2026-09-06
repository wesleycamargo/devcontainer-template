#!/usr/bin/env bash
# Auto-start the Hermes gateway and web dashboard when the container starts.
# Both bind loopback addresses only. The Open WebUI companion service shares
# this container's network namespace, while VS Code forwards the dashboard
# and Open WebUI ports to the host.
#
# It backgrounds each service and returns immediately (never blocks the start
# phase), skips services already running, and no-ops cleanly until Hermes has
# been configured -- `hermes` first-run writes ~/.hermes/config.yaml. Output
# goes to ~/.hermes/logs/<service>.out.
#
# Before the dashboard, a one-time step seeds the default model from a
# existing ~/.codex/auth.json (a ChatGPT OAuth login written by Codex CLI):
# it imports those tokens into Hermes' own auth store and sets openai-codex /
# gpt-5.6-terra as the default provider + model (which also writes
# ~/.hermes/config.yaml). Guarded by ~/.hermes/.codex-default-seeded so it
# runs once and never overrides a provider you later pick with `hermes model`.
#
set -u

command -v hermes >/dev/null 2>&1 || exit 0

# Keep the key shared by Hermes and Open WebUI outside both images and out of
# Git. Open WebUI waits for this file before its first start, when it persists
# the configured OpenAI-compatible connection in its database.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
openwebui_env="$script_dir/.openwebui.env"
if [ ! -s "$openwebui_env" ]; then
  umask 077
  temp_env="$(mktemp "${openwebui_env}.XXXXXX")"
  api_server_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  webui_secret_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  printf 'API_SERVER_ENABLED=true\nAPI_SERVER_KEY=%s\nOPENAI_API_KEY=%s\nWEBUI_SECRET_KEY=%s\n' \
    "$api_server_key" "$api_server_key" "$webui_secret_key" >"$temp_env"
  mv "$temp_env" "$openwebui_env"
  chmod 600 "$openwebui_env"
  echo "start-hermes: created .devcontainer/.openwebui.env"
fi

set -a
. "$openwebui_env"
set +a

# One-time: point Hermes' default model at the persisted Codex / ChatGPT login.
# `~/.codex` is backed by a named volume (see docker-compose.yml), so this
# also works after signing in to Codex inside the container.
#
# We deliberately do NOT call `hermes auth add openai-codex`: that command
# jumps straight to an interactive device-code login and never looks at the
# Codex CLI file, so it just hangs this hook. Instead we call the same
# internal helpers `hermes model` -> "ChatGPT or Codex Subscription" uses to
# adopt an existing Codex CLI session:
#   _import_codex_cli_tokens()   -- returns nothing if the file is missing or
#                                   its access token has already expired
#                                   (Codex refresh tokens are single-use, so
#                                   Hermes won't adopt a stale pair)
#   _save_codex_tokens()         -- copy them into Hermes' own auth store
#   _update_config_for_provider()-- write model.provider=openai-codex + base_url
#   set_config_value()           -- pin model.default
# All local: no network, no prompts. A marker file makes it run once, so it
# never overrides a provider you later pick with `hermes model`; delete
# ~/.hermes/.codex-default-seeded to re-seed. Log: ~/.hermes/logs/codex-seed.out.
codex_seed_marker="$HOME/.hermes/.codex-default-seeded"
hermes_src="$HOME/.hermes/hermes-agent"
if [ ! -f "$codex_seed_marker" ] && [ -s "$HOME/.codex/auth.json" ] \
   && [ -x "$hermes_src/venv/bin/python" ]; then
  mkdir -p "$HOME/.hermes/logs"
  echo "start-hermes: seeding default model from ~/.codex/auth.json (openai-codex / gpt-5.6-terra)"
  if ( cd "$hermes_src" && timeout 30 ./venv/bin/python - <<'PY'
import sys
try:
    from hermes_cli.auth import (
        _import_codex_cli_tokens, _save_codex_tokens, _update_config_for_provider)
    from hermes_cli.auth_codex import _codex_base_url
    from hermes_cli.config import set_config_value
except Exception as exc:
    print("import error:", exc); sys.exit(3)
tokens = _import_codex_cli_tokens()
if not tokens:
    print("no usable Codex CLI tokens (file missing or access token expired)")
    sys.exit(2)
_save_codex_tokens(tokens)
_update_config_for_provider("openai-codex", _codex_base_url())
set_config_value("model.default", "gpt-5.6-terra")
print("seeded provider=openai-codex, model.default=gpt-5.6-terra")
PY
  ) >"$HOME/.hermes/logs/codex-seed.out" 2>&1; then
    touch "$codex_seed_marker"
    echo "start-hermes: seeded provider=openai-codex, model.default=gpt-5.6-terra"
  else
    echo "start-hermes: codex seed skipped/failed; will retry next start (see ~/.hermes/logs/codex-seed.out)"
  fi
fi

if [ ! -f "$HOME/.hermes/config.yaml" ]; then
  echo "start-hermes: Hermes not configured yet (run 'hermes'); skipping auto-start"
  exit 0
fi

mkdir -p "$HOME/.hermes/logs"

if pgrep -f "hermes gateway" >/dev/null 2>&1; then
  echo "start-hermes: gateway already running"
else
  echo "start-hermes: starting gateway on 127.0.0.1:8642"
  nohup hermes gateway >"$HOME/.hermes/logs/gateway.out" 2>&1 &
fi

if pgrep -f "hermes dashboard" >/dev/null 2>&1; then
  echo "start-hermes: dashboard already running"
else
  echo "start-hermes: starting dashboard on 127.0.0.1:9119"
  nohup hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build \
    >"$HOME/.hermes/logs/dashboard.out" 2>&1 &
fi

exit 0
