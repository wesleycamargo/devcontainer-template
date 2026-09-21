#!/usr/bin/env bash
# PID 1 for the Hermes devbox. Installed as /usr/local/bin/hermes-entrypoint.
#
# Everything the SSH gateway needs happens here, in the image, so `docker run`,
# `docker compose` and VS Code Dev Containers all get identical behaviour. No
# Dev Container feature or lifecycle hook is involved.
#
# Runs as root, then execs "$@" (default: sshd -D -e), so the container's main
# process is sshd rather than a `sleep infinity` placeholder.
set -uo pipefail

log() { printf 'hermes-entrypoint: %s\n' "$*"; }

# --- sshd runtime dir ------------------------------------------------------
# /run is tmpfs in many setups, so this cannot be a build-time-only mkdir.
mkdir -p /run/sshd

# --- host keys -------------------------------------------------------------
# Generated on first start into a directory that Compose backs with a named
# volume, so the container keeps one SSH identity per project across restarts,
# recreates and rebuilds. Hermes uses StrictHostKeyChecking=accept-new, which
# refuses a key that changed, so a fresh key each build would break saved
# connections. Not baked into the image: every project would otherwise share
# one identity.
host_key_dir=/var/lib/hermes-ssh/host_keys
mkdir -p "$host_key_dir"
if [ ! -f "$host_key_dir/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$host_key_dir/ssh_host_ed25519_key" \
    && log "generated ed25519 host key"
fi
if [ ! -f "$host_key_dir/ssh_host_rsa_key" ]; then
  ssh-keygen -q -t rsa -b 4096 -N '' -f "$host_key_dir/ssh_host_rsa_key" \
    && log "generated rsa host key"
fi
chmod 700 "$host_key_dir"
chmod 600 "$host_key_dir"/ssh_host_*_key 2>/dev/null

# Now that the keys the config references exist, check the whole config. A
# mistake here would otherwise show up as a container that exits on start.
if ! sshd -t; then
  log "ERROR: sshd configuration is invalid (see above); refusing to start"
  exit 1
fi

# --- authorized keys -------------------------------------------------------
# Contract input: /run/hermes-ssh/authorized_keys, mounted read-only by
# whoever starts the container. Copied rather than used in place because sshd
# rejects an authorized_keys file it does not consider safely owned, and a bind
# mount carries the host's uid/gid. Only ever public keys.
authorized_src=/run/hermes-ssh/authorized_keys
ssh_dir=/home/hermes/.ssh
mkdir -p /run/hermes-ssh
install -d -o hermes -g hermes -m 700 "$ssh_dir"
if [ -s "$authorized_src" ]; then
  # tr strips CR so a key authored on Windows still parses.
  tr -d '\r' <"$authorized_src" >"$ssh_dir/authorized_keys"
  chown hermes:hermes "$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys"
  log "authorized $(grep -c . "$ssh_dir/authorized_keys" 2>/dev/null || echo 0) public key(s) for hermes"
else
  rm -f "$ssh_dir/authorized_keys"
  log "WARNING: no keys at $authorized_src -- SSH logins will be refused."
  log "         mount a public key there, e.g."
  log "         -v \$HOME/.ssh/id_ed25519.pub:$authorized_src:ro"
fi

# --- Hermes data directory -------------------------------------------------
# The image installs Hermes' code and runtime under /usr/local/lib and /opt,
# so ~/.hermes holds user data only and an image upgrade actually takes effect.
# The install-time data dirs were created under the build user's home, so make
# sure hermes's own copy exists (the volume mounts in empty and root-owned).
install -d -o hermes -g hermes /home/hermes/.hermes
for d in cron sessions logs pairing hooks image_cache audio_cache memories skills; do
  install -d -o hermes -g hermes "/home/hermes/.hermes/$d"
done
if [ ! -f /home/hermes/.hermes/.env ] && [ -f /usr/local/lib/hermes-agent/.env.example ]; then
  install -o hermes -g hermes -m 600 \
    /usr/local/lib/hermes-agent/.env.example /home/hermes/.hermes/.env
  log "seeded ~/.hermes/.env from the installed template"
fi

# Volumes created by an older image still contain the Hermes code and Node
# runtime that used to live here. They are inert now -- /usr/local/bin/hermes
# runs the image's copy -- but they waste space and confuse `hermes --version`
# archaeology. Never removed automatically: this directory also holds
# credentials, sessions, memories and skills.
for legacy in hermes-agent node; do
  if [ -e "/home/hermes/.hermes/$legacy" ]; then
    log "legacy Hermes data notice: found leftover from an older image at ~/.hermes/$legacy"
    log "note: ~/.hermes/$legacy is a leftover from an older image and is no longer used."
    log "      the active runtime is /usr/local/lib/hermes-agent. to reclaim the space:"
    log "      rm -rf ~/.hermes/$legacy"
  fi
done

# --- project skills sync ----------------------------------------------------
# Keeps .agents/skills current with upstream and exposes it to every
# configured agent (SYNC_SKILLS_USER/_AGENTS/_UPSTREAM, set in
# docker-compose.yml) at both project and global scope. Runs here rather
# than a Dev Container hook so it also covers a bare `docker run`/`docker
# compose up` and a pure SSH/Hermes Desktop session that never attaches VS
# Code. Best-effort: must never block sshd from starting.
if command -v sync-project-skills >/dev/null 2>&1; then
  sync-project-skills || log "sync-project-skills reported a problem; continuing"
fi

# --- optional Hermes services ---------------------------------------------
# Off unless asked for. With terminal.backend=ssh the agent runs on the
# operator's machine and only shells in here, so a gateway/dashboard pair would
# be two extra processes writing the same ~/.hermes as the incoming SSH
# session. Compose sets HERMES_AUTOSTART_SERVICES=1 to run them anyway.
if [ "${HERMES_AUTOSTART_SERVICES:-0}" = "1" ]; then
  # -s /bin/bash: `su` would otherwise use hermes's LOGIN shell, and the base
  # image sets that to pwsh, which cannot parse `VAR=value cmd` and fails with
  # a confusing "not recognized as a cmdlet" error. The Dockerfile chsh's this
  # user to bash anyway; forcing the shell here keeps start-up working
  # regardless of what the login shell happens to be.
  # HOME is passed explicitly: `su` rewrites it and PAM may prune the rest,
  # so it cannot be assumed to survive the switch.
  ( cd / && su hermes -s /bin/bash -c "HOME=/home/hermes /usr/local/bin/hermes-start-services" ) \
    || log "hermes-start-services reported a problem; SSH is unaffected"
else
  log "HERMES_AUTOSTART_SERVICES is not 1; starting sshd only"
fi

# --- connection details ----------------------------------------------------
# Printed once so `docker compose logs` / `docker logs` shows how to connect.
/usr/local/bin/hermes-ssh-info || true

log "starting: $*"
exec "$@"
