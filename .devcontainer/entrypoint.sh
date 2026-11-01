#!/usr/bin/env bash
# PID 1 for the Hermes devbox. Installed as /usr/local/bin/hermes-entrypoint.
#
# Prepare persistent data and the runtime environment in the image so Docker,
# Compose and VS Code Dev Containers use the same bootstrap. No Dev Container
# feature or lifecycle hook is required.
#
# Runs setup as root, then starts the default keepalive as hermes. Explicit
# commands keep their existing exec behaviour; the Hermes wrapper drops root.
set -uo pipefail

log() { printf 'hermes-entrypoint: %s\n' "$*"; }

# /tmp can also be mounted fresh at runtime. .NET/PSReadLine need a private,
# writable runtime directory owned by the development user, not root.
install -d -o hermes -g hermes -m 700 /tmp/hermes-runtime

# --- Hermes data directory -------------------------------------------------
# The official image provides Hermes source and dependencies under /opt/hermes.
# ~/.hermes keeps user data at the same path as older devbox images.
# The install-time data dirs were created under the build user's home, so make
# sure hermes's own copy exists (the volume mounts in empty and root-owned).
install -d -o hermes -g hermes /home/hermes/.hermes
for d in cron sessions logs pairing hooks image_cache audio_cache memories skills; do
  install -d -o hermes -g hermes "/home/hermes/.hermes/$d"
done
if [ ! -f /home/hermes/.hermes/.env ] && [ -f /opt/hermes/.env.example ]; then
  install -o hermes -g hermes -m 600 \
    /opt/hermes/.env.example /home/hermes/.hermes/.env
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
    log "      the active source is /opt/hermes. to reclaim the space:"
    log "      rm -rf ~/.hermes/$legacy"
  fi
done

# The official runtime is outside the data volume. A broken image needs to be
# replaced; startup must not reinstall Hermes or compile browser assets.
if ! timeout 30 runuser -u hermes -- env HOME=/home/hermes /usr/local/bin/hermes --version >/dev/null 2>&1; then
  log "WARNING: Hermes runtime check failed; pull/recreate the image. Development shell remains available"
fi

# --- optional Hermes services ---------------------------------------------
# A bare docker run starts only the development shell. Compose opts into the
# gateway/Webapp with HERMES_AUTOSTART_SERVICES=1; dashboard opt-in is separate.
if [ "${HERMES_AUTOSTART_SERVICES:-0}" = "1" ]; then
  # -s /bin/bash: `su` would otherwise use hermes's LOGIN shell, and the base
  # image sets that to pwsh, which cannot parse `VAR=value cmd` and fails with
  # a confusing "not recognized as a cmdlet" error. The Dockerfile chsh's this
  # user to bash anyway; forcing the shell here keeps start-up working
  # regardless of what the login shell happens to be.
  # HOME is passed explicitly: `su` rewrites it and PAM may prune the rest,
  # so it cannot be assumed to survive the switch.
  ( cd / && su hermes -s /bin/bash -c "HOME=/home/hermes /usr/local/bin/hermes-start-services" ) \
    || log "hermes-start-services reported a problem; development shell is unaffected"
else
  log "HERMES_AUTOSTART_SERVICES is not 1; development shell only"
fi

log "starting: $*"
# Keep the devcontainer alive without a root-owned default process. Explicit
# commands still exec as requested, including root maintenance commands.
if [ "$#" -eq 2 ] && [ "$1" = "sleep" ] && [ "$2" = "infinity" ]; then
  exec runuser -u hermes -- "$@"
fi
exec "$@"
