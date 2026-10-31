#!/usr/bin/env bash
# Start the Hermes gateway (including Webapp) and web dashboard. Installed as
# /usr/local/bin/hermes-start-services and run as hermes by hermes-entrypoint
# when HERMES_AUTOSTART_SERVICES=1. Safe to re-run by hand: every service is
# guarded, so a second run never produces a duplicate process.
#
# Defaults bind loopback only; VS Code forwards ports 9119 and 9120.
# Compose publishes neither. Image users may explicitly configure remote Webapp
# access with authentication. Output goes to ~/.hermes/logs/<service>.out.
#
# This used to be a Dev Container lifecycle helper, which meant `docker run`
# and `docker compose` never started Hermes at all.
set -u

command -v hermes >/dev/null 2>&1 || exit 0

mkdir -p "$HOME/.hermes/logs"

# --- one-time Codex/ChatGPT seed -------------------------------------------
# Point Hermes' default model at a persisted Codex login. ~/.codex is backed by
# a named volume, so this also works after signing in to Codex in the
# container.
#
# We deliberately do NOT call `hermes auth add openai-codex`: that jumps
# straight to an interactive device-code login and never looks at the Codex CLI
# file, so it would just hang. Instead we call the same internal helpers
# `hermes model` -> "ChatGPT or Codex Subscription" uses:
#   _import_codex_cli_tokens()    -- nothing if the file is missing or its
#                                    access token already expired (Codex
#                                    refresh tokens are single-use)
#   _save_codex_tokens()          -- copy into Hermes' own auth store
#   _update_config_for_provider() -- model.provider=openai-codex + base_url
#   set_config_value()            -- pin model.default
# All local: no network, no prompts. The marker makes it run once, so it never
# overrides a provider picked later with `hermes model`; delete
# ~/.hermes/.codex-default-seeded to re-seed.
codex_seed_marker="$HOME/.hermes/.codex-default-seeded"
# The runtime now lives in the image, not under ~/.hermes.
hermes_src="/opt/hermes"
hermes_python="/opt/hermes/.venv/bin/python"
if [ ! -f "$codex_seed_marker" ] && [ -s "$HOME/.codex/auth.json" ] \
   && [ -x "$hermes_python" ]; then
  echo "hermes-start-services: seeding default model from ~/.codex/auth.json (openai-codex / gpt-5.6-terra)"
  if ( cd "$hermes_src" && timeout 30 "$hermes_python" - <<'PY'
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
    echo "hermes-start-services: seeded provider=openai-codex, model.default=gpt-5.6-terra"
  else
    echo "hermes-start-services: codex seed skipped/failed; will retry next start (see ~/.hermes/logs/codex-seed.out)"
  fi
fi

# --- gateway + dashboard ---------------------------------------------------
# Read the raw config: merged defaults would hide whether the user explicitly
# disabled Webapp. Hermes' atomic writer preserves other settings and comments.
# Never replace a malformed config/section with a working but unintended one.
# A missing config reads as an empty mapping, so first boot needs no CLI setup.
if ! ( cd "$hermes_src" && timeout 30 "$hermes_python" - <<'PY'
from hermes_cli.config import (
    atomic_config_write, get_config_path, require_readable_config_before_write,
)

path = get_config_path()
config = require_readable_config_before_write(path)
webapp = config.get("webapp", {})
if not isinstance(webapp, dict):
    raise ValueError("webapp must be a mapping; configuration left unchanged")
missing = {key: value for key, value in
           {"enabled": True, "host": "127.0.0.1", "port": 9120}.items()
           if key not in webapp}
if missing:
    config["webapp"] = {**webapp, **missing}
    atomic_config_write(path, config)
    print("hermes-start-services: filled missing local Webapp defaults")
PY
); then
  echo "hermes-start-services: could not configure Webapp; check config.yaml and Hermes dependencies"
  exit 1
fi

if pgrep -f "hermes gateway" >/dev/null 2>&1; then
  echo "hermes-start-services: gateway already running"
else
  echo "hermes-start-services: starting gateway (Webapp address comes from config.yaml)"
  nohup hermes gateway >"$HOME/.hermes/logs/gateway.out" 2>&1 &
fi

if pgrep -f "hermes dashboard" >/dev/null 2>&1; then
  echo "hermes-start-services: dashboard already running"
else
  echo "hermes-start-services: starting dashboard on 127.0.0.1:9119"
  nohup hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build \
    >"$HOME/.hermes/logs/dashboard.out" 2>&1 &
fi

exit 0
