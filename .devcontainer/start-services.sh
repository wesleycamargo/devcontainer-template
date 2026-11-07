#!/usr/bin/env bash
# Start the Hermes gateway (including Webapp) and optional dashboard. Installed as
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
# Codex auth.json is mounted from the host. Import it into this project's
# Hermes auth store, preserving an existing Hermes login and model choice.
#
# We deliberately do NOT call `hermes auth add openai-codex`: that jumps
# straight to an interactive device-code login and never looks at the Codex CLI
# file, so it would just hang. Instead we call the same internal helpers
# `hermes model` -> "ChatGPT or Codex Subscription" uses:
#   _import_codex_cli_tokens()    -- initial import only, when Hermes has no grant
#   _save_codex_tokens()          -- save under the native auth lock
#   _update_config_for_provider() -- model.provider=openai-codex + base_url
#   set_config_value()            -- pin model.default
# All local: no network, no prompts. Explicit provider/model choices are kept.
# Codex CLI and Hermes remain separate OAuth clients with independent refreshes.
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
        _auth_store_lock, _load_auth_store, _load_provider_state,
        _import_codex_cli_tokens, _save_codex_tokens, _update_config_for_provider)
    from hermes_cli.auth_codex import _codex_base_url
    from hermes_cli.config import get_config_path, require_readable_config_before_write, set_config_value
except Exception as exc:
    print("import error:", exc); sys.exit(3)
config = require_readable_config_before_write(get_config_path())
model = config.get("model", {})
if not isinstance(model, dict) or model.get("provider") not in (None, "", "openai-codex"):
    print("existing model provider preserved")
    sys.exit(0)
with _auth_store_lock():
    state = _load_provider_state(_load_auth_store(), "openai-codex") or {}
    tokens = state.get("tokens") or {}
    if not (tokens.get("access_token") and tokens.get("refresh_token")):
        tokens = _import_codex_cli_tokens()
        if not tokens:
            print("no usable Codex CLI login; authenticate with Codex CLI on the host")
            sys.exit(2)
        _save_codex_tokens(tokens)
_update_config_for_provider("openai-codex", _codex_base_url())
if not model.get("default"):
    set_config_value("model.default", "gpt-5.6-terra")
print("configured openai-codex; existing login and model choice preserved")
PY
  ) >"$HOME/.hermes/logs/codex-seed.out" 2>&1; then
    touch "$codex_seed_marker"
    echo "hermes-start-services: Codex login setup complete (existing model choices preserved)"
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

# The local terminal backend uses the gateway process's current directory.
# Dev Containers mount the opened project as the sole child of /workspaces, so
# start the gateway from that exact project rather than from the image runtime.
workspace_dirs=()
for candidate in /workspaces/*; do
  [ -d "$candidate" ] && workspace_dirs+=("$candidate")
done
if [ "${#workspace_dirs[@]}" -eq 1 ]; then
  cd "${workspace_dirs[0]}" || exit 1
  echo "hermes-start-services: using Dev Container workspace $PWD"
else
  echo "hermes-start-services: expected one Dev Container workspace under /workspaces; keeping $PWD"
fi

# The official launcher execs Python with an inline hermes_cli.main import,
# not a literal `hermes gateway` argv. Match both official and legacy launchers.
if pgrep -f "[h]ermes gateway([[:space:]]|$)|[h]ermes_cli[.]main.* gateway([[:space:]]|$)" >/dev/null 2>&1; then
  echo "hermes-start-services: gateway already running"
else
  echo "hermes-start-services: starting gateway (Webapp address comes from config.yaml)"
  nohup hermes gateway >"$HOME/.hermes/logs/gateway.out" 2>&1 &
fi

if [ "${HERMES_AUTOSTART_DASHBOARD:-0}" != "1" ]; then
  echo "hermes-start-services: dashboard autostart disabled (set HERMES_AUTOSTART_DASHBOARD=1 to enable)"
elif pgrep -f "[h]ermes dashboard([[:space:]]|$)|[h]ermes_cli[.]main.* dashboard([[:space:]]|$)" >/dev/null 2>&1; then
  echo "hermes-start-services: dashboard already running"
else
  echo "hermes-start-services: starting dashboard on 127.0.0.1:9119"
  nohup hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build \
    >"$HOME/.hermes/logs/dashboard.out" 2>&1 &
fi

exit 0
