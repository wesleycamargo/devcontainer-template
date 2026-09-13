# AI Hermes Devbox -- the published ai-devbox image plus the Hermes Agent
# (Nous Research, https://hermes-agent.nousresearch.com/) and an SSH gateway.
# CI builds this and publishes it as ai-hermes-devbox-image; ai-devbox-image
# itself is unchanged.
#
# Unlike the ai-devbox Dockerfile, this one is NOT the full build recipe -- it
# layers on the already-published base so the build is just the Hermes and SSH
# steps instead of re-running the whole PowerShell/Oh My Posh/Node/agent-CLI
# install. publish-ai-hermes-devbox.yml pulls ai-devbox-image:latest as
# published by the ai-devbox workflow; a base rebuild does not retrigger this
# one, so :latest is whatever ai-devbox last published.
#
# The container contract this image implements (see SSH-BACKEND.md):
#   SSH user              hermes, public key only
#   Internal SSH port     2222
#   Hermes executable     /usr/local/bin/hermes
#   Authorized keys in    /run/hermes-ssh/authorized_keys
# It holds for `docker run`, `docker compose` and VS Code Dev Containers alike,
# because it is implemented here rather than in devcontainer.json.
FROM ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest

# --- rename the base image's default user -----------------------------------
# ai-devbox-image (built FROM a Microsoft devcontainers base) ships a
# pre-created `vscode` user/group. Only this image renames it to `hermes` --
# ai-devbox and any other consumer of ai-devbox-image (e.g. ai-openhands-devbox)
# is untouched and still uses vscode. Every step below this point uses hermes;
# if you add a new step that shells out as the container's user, use hermes
# too, not vscode.
RUN usermod -l hermes -d /home/hermes -m vscode \
    && groupmod -n hermes vscode \
    && if [ -f /etc/sudoers.d/vscode ]; then \
         mv /etc/sudoers.d/vscode /etc/sudoers.d/hermes \
         && sed -i 's/\bvscode\b/hermes/g' /etc/sudoers.d/hermes; \
       fi

# --- SSH server ------------------------------------------------------------
# Installed here, not via the devcontainer `sshd` feature: features are applied
# by the Dev Containers tooling, so a feature-provided sshd does not exist
# under plain `docker run`.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd

COPY sshd-hermes-gateway.conf /etc/ssh/sshd_config.d/10-hermes-gateway.conf
# Debian's stock sshd_config pulls in the drop-in directory. Fail the build
# loudly if that ever stops being true, rather than shipping an image whose
# hardening is silently ignored.
# (The config is syntax-checked at runtime by hermes-entrypoint, once the host
# keys it references actually exist.)
RUN chmod 644 /etc/ssh/sshd_config.d/10-hermes-gateway.conf \
    && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config

# --- Hermes ----------------------------------------------------------------
# Playwright keys its browser download location off this variable. Without it a
# root install would put Chromium under /root/.cache (mode 700) where the
# hermes user cannot read it, breaking browser and computer-use support.
#
# ENV alone is not enough: sshd builds a fresh environment for each session and
# does not inherit the container's, so anything Hermes needs over SSH must also
# be in /etc/environment, which pam_env applies to SSH logins.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN printf 'PLAYWRIGHT_BROWSERS_PATH=/opt/playwright\n' >> /etc/environment

# Installed as ROOT, which selects the installer's FHS layout:
#   code + venv   /usr/local/lib/hermes-agent
#   launchers     /usr/local/bin/{hermes,hermes-agent,hermes-acp}
#   uv python     /usr/local/share/uv/python
#   node runtime  $HERMES_HOME/node
# That last one is why --hermes-home is passed: the default would be
# /root/.hermes/node, unreadable by hermes. Everything above lives in image
# layers, so ~/.hermes holds user data only and pulling a newer image actually
# upgrades Hermes -- previously the whole runtime sat inside the hermes-data
# volume, which Docker seeds once and never refreshes.
#
# Full install: Playwright/Chromium and the computer-use driver are included
# (no --skip-browser / --skip-computer-use). --skip-setup skips the API-key
# wizard so the build does not block on it.
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- \
      --non-interactive --skip-setup --hermes-home /opt/hermes

# Make the root-owned install readable and traversable by hermes. Each path is
# optional (layout varies by installer version), but the install itself above
# is not allowed to fail silently.
RUN for d in /opt/hermes /usr/local/lib/hermes-agent /usr/local/share/uv /opt/playwright; do \
      if [ -e "$d" ]; then chmod -R a+rX "$d"; fi; \
    done

# libxmlsec's development package ships this private key solely for a
# documentation example. It is not needed at runtime and must not be present
# in an image that accepts SSH connections.
RUN rm -f /usr/share/doc/libxmlsec1-dev/examples/rsakey.pem

# The base image makes pwsh hermes's login shell. Hermes' SSH backend keeps a
# persistent `bash` session and drops to one-shot commands for stdin/sudo, both
# of which expect POSIX sh. VS Code terminals still open pwsh via
# terminal.integrated.defaultProfile.linux in devcontainer.json.
RUN chsh -s /bin/bash hermes

# Build-time proof of the contract: the hermes user must be able to run the
# root-installed Hermes from the contract path with no shell initialisation and
# no write access to the install tree. If the app/data split regresses, the
# build fails here instead of at someone's first SSH attempt.
# </dev/null and timeout guard against an unexpected interactive prompt.
RUN timeout 180 su hermes -c '/usr/local/bin/hermes --version' </dev/null \
    && timeout 60 su hermes -c 'node --version' </dev/null
# Diagnostics only: surfaces whether Hermes' Node shadows the base image's
# Node 20 for the agent CLIs. Never fails the build.
RUN su hermes -c 'command -v node npm hermes claude codex; claude --version; codex --version' </dev/null 2>&1 | sed 's/^/build-check: /' || true

# --- container-owned runtime ----------------------------------------------
COPY entrypoint.sh     /usr/local/bin/hermes-entrypoint
COPY start-services.sh /usr/local/bin/hermes-start-services
COPY hermes-ssh-info.sh /usr/local/bin/hermes-ssh-info
RUN chmod 755 /usr/local/bin/hermes-entrypoint \
              /usr/local/bin/hermes-start-services \
              /usr/local/bin/hermes-ssh-info \
    && bash -n /usr/local/bin/hermes-entrypoint \
    && bash -n /usr/local/bin/hermes-start-services \
    && bash -n /usr/local/bin/hermes-ssh-info

# sshd in the foreground is the main process, so the container stays up on its
# own. Compose no longer needs `command: sleep infinity`, and the Dev Container
# attaches to a container that is already a working gateway.
# The entrypoint ends in `exec "$@"`, so `docker run <image> bash` still works.
ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
