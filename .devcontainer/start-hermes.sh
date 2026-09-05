#!/usr/bin/env bash
# Auto-start the Hermes dashboard and gateway when the container starts, both
# bound to 0.0.0.0 so the ports published in docker-compose.yml (9119, 8642)
# are reachable from the host. Wired in via `postStartCommand` in
# devcontainer.json, so it runs on every container start.
#
# It backgrounds each service and returns immediately (never blocks the
# start phase), skips a service that's already running, and no-ops cleanly
# until Hermes has been configured -- `hermes` first-run writes
# ~/.hermes/.env and ~/.hermes/config.yaml. Output goes to
# ~/.hermes/logs/<service>.out.
#
# Notes:
#   - The dashboard refuses to start on a non-loopback host until an auth
#     provider is set under `dashboard:` in ~/.hermes/config.yaml -- until
#     then it just exits and logs the error.
#   - The gateway needs API_SERVER_KEY in ~/.hermes/.env; API_SERVER_HOST is
#     passed here so config.yaml doesn't have to be edited.
set -u

command -v hermes >/dev/null 2>&1 || exit 0
if [ ! -f "$HOME/.hermes/config.yaml" ]; then
  echo "start-hermes: Hermes not configured yet (run 'hermes'); skipping auto-start"
  exit 0
fi

mkdir -p "$HOME/.hermes/logs"

start() {
  local name="$1"; shift
  if pgrep -f "hermes $name" >/dev/null 2>&1; then
    echo "start-hermes: '$name' already running"
    return
  fi
  echo "start-hermes: starting '$name'"
  nohup "$@" >"$HOME/.hermes/logs/$name.out" 2>&1 &
}

start dashboard hermes dashboard --host 0.0.0.0
start gateway env API_SERVER_HOST=0.0.0.0 hermes gateway

exit 0
