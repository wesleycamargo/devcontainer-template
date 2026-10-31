#!/usr/bin/env bash
set -euo pipefail

# A reused Docker volume can retain root ownership even after an image update.
# Only touch the separate Linux runtime mount, never the shared Hermes home.
runtime=/home/vscode/.hermes/installs
if [ "$(id -un)" = vscode ] && mountpoint -q "$runtime"; then
    uid=$(id -u)
    gid=$(id -g)
    # Do not follow symlinks or cross into other mounted filesystems.
    sudo -n find "$runtime" -xdev \
        \( ! -uid "$uid" -o ! -gid "$gid" \) \
        -exec chown -h "$uid:$gid" {} +
fi

exec "$@"
