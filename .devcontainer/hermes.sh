#!/bin/sh
# Bridge the official runtime to the devbox's established user/data layout.
set -eu

if [ "$(id -u)" = "0" ]; then
    exec /usr/sbin/runuser -u hermes -- /usr/local/bin/hermes "$@"
fi

export HOME="${HOME:-/home/hermes}"
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_WRITE_SAFE_ROOT="${HERMES_WRITE_SAFE_ROOT:-$HERMES_HOME}"
export HERMES_PYTHON=/opt/hermes/.venv/bin/python
export HERMES_RUNTIME_DIR=/opt/hermes/tools
export PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/tools
export HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
export HERMES_TUI_DIR=/opt/hermes/ui-tui
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/hermes-runtime}"
export PATH="/usr/local/bin:/home/hermes/.local/bin:${PATH:-/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"

exec /opt/hermes/.venv/bin/hermes "$@"
