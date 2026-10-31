#!/usr/bin/env bash
# Print everything needed to reach this container over SSH. Installed as
# /usr/local/bin/hermes-ssh-info; also printed once by hermes-entrypoint, so
# `docker compose logs` carries it.
#
# The container cannot discover its own published host port, so Compose/`docker
# run` pass it in as HERMES_SSH_HOST_PORT. Without it we fall back to the
# internal port, which is correct for a 1:1 mapping and clearly wrong (rather
# than silently misleading) otherwise.
set -u

host="${HERMES_SSH_HOST:-127.0.0.1}"
port="${HERMES_SSH_HOST_PORT:-2222}"
user="hermes"
hermes_path="/usr/local/bin/hermes"
# Name the alias after the project folder. Compose cannot pass the folder name
# in, but a terminal opened by VS Code starts in /workspaces/<folder>. At
# container start (no such cwd) fall back to the hostname.
project="${HERMES_PROJECT_NAME:-}"
if [ -z "$project" ]; then
  case "$PWD" in
    /workspaces/*) project="${PWD#/workspaces/}"; project="${project%%/*}" ;;
    *) project="$(hostname)" ;;
  esac
fi
alias_name="hermes-${project}"
# Suggest the workspace as the remote working directory when there is one --
# this script also runs from / at container start, which would be a poor
# suggestion to copy into a config file.
if [ -n "${HERMES_SSH_CWD:-}" ]; then
  cwd="$HERMES_SSH_CWD"
else
  cwd="${HOME:-/home/hermes}"
  for candidate in /workspaces/*/; do
    [ -d "$candidate" ] && cwd="${candidate%/}" && break
  done
fi

cat <<EOF

  Hermes SSH gateway
  ------------------
  Alias       ${alias_name}
  Host        ${host}
  Port        ${port}
  User        ${user}
  Hermes      ${hermes_path}

  Add to ~/.ssh/config on the machine running Hermes:

    Host ${alias_name}
        HostName ${host}
        Port ${port}
        User ${user}
        StrictHostKeyChecking accept-new

    # Add IdentityFile only when the matching private key is not one SSH
    # discovers normally or offers through ssh-agent.

  Test it:

    ssh ${alias_name} "hermes --version"

  Hermes client settings (reference -- confirm against your Hermes version):

    config.yaml     terminal.backend: ssh
                    terminal.cwd: ${cwd}
    .env            TERMINAL_SSH_HOST=${host}
                    TERMINAL_SSH_USER=${user}
                    TERMINAL_SSH_PORT=${port}
                    # TERMINAL_SSH_KEY=<path to the matching private key>

  The private key stays on your machine. Only public keys are ever mounted
  into this container, at /run/hermes-ssh/authorized_keys.

EOF
