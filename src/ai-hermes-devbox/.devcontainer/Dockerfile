# syntax=docker/dockerfile:1
# Reuse the official, prebuilt Hermes runtime, Webapp and computer-use stack.
# Multi-arch digest for main-desktop at c419cf7c864ac0ee511dbd9f7091a8bba0b567ee.
# Only development tools and our SSH lifecycle are layered on top.
FROM nousresearch/hermes-agent:main-desktop@sha256:cef6ca13cc35452215c5774c0563b0940b0a6ebaebad0d87174b27ca3d5c93d5

USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV HOME=/home/hermes \
    HERMES_HOME=/home/hermes/.hermes \
    HERMES_WRITE_SAFE_ROOT=/home/hermes/.hermes \
    PATH="/usr/local/bin:/home/hermes/.local/bin:/opt/hermes/.venv/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin" \
    DISABLE_AUTOUPDATER=1
WORKDIR /home/hermes

# Retain the existing template's UID/GID and volume paths. Do not move /opt/data:
# it is an inherited VOLUME, and the official runtime under /opt/hermes is sealed.
RUN groupmod -g 1000 hermes \
    && usermod -u 1000 -g 1000 -d /home/hermes -s /bin/bash hermes \
    && install -d -o hermes -g hermes /home/hermes /home/hermes/.hermes \
       /home/hermes/.claude /home/hermes/.codex /home/hermes/.cache \
    && install -d -o hermes -g hermes -m 700 /tmp/hermes-runtime

# Node, Python, Chromium and the browser bundles already come from upstream.
# Keep the development-tool versions aligned with ai-devbox.
RUN curl -fsSL https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb \
        -o /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell openssh-server sudo less unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && printf 'hermes ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/hermes \
    && chmod 440 /etc/sudoers.d/hermes \
    && rm -f /usr/share/doc/libxmlsec1-dev/examples/rsakey.pem

ARG OH_MY_POSH_VERSION=31.9.1
RUN <<'BASH'
artifact="posh-linux-$(dpkg --print-architecture)"
release="https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v${OH_MY_POSH_VERSION}"
cd /tmp
curl -fsSL "$release/$artifact" -o "$artifact"
curl -fsSL "$release/checksums.txt" | grep -F " $artifact" | sha256sum --check --strict
install -m 0755 "$artifact" /usr/local/bin/oh-my-posh
rm "$artifact"
mkdir -p /etc/oh-my-posh
curl -fsSL 'https://gist.githubusercontent.com/wesleycamargo/06b58b472fe0cded2e6d6451ea0778bd/raw/1c952297121a50826ef6f849bb7ee8c11d8e09a6/oh-my-posh-az-cli-az-pwsh.json' \
    -o /etc/oh-my-posh/theme.omp.json
BASH

ARG TERMINAL_ICONS_VERSION=0.11.0
# PowerShell creates ~/.local/share even with -NoProfile. Keep root's setup
# files out of the development user's home so Claude can install there later.
RUN HOME=/root pwsh -NoLogo -NoProfile -NonInteractive -File /dev/stdin <<'PWSH'
$ErrorActionPreference = 'Stop'
Install-Module -Name Terminal-Icons -RequiredVersion $env:TERMINAL_ICONS_VERSION -Force -Scope AllUsers
@'
if (-not [Console]::IsInputRedirected) {
    Import-Module Terminal-Icons
    oh-my-posh init pwsh --config /etc/oh-my-posh/theme.omp.json | Invoke-Expression
}
'@ | Set-Content -Path $PROFILE.AllUsersAllHosts
PWSH

RUN echo 'eval "$(oh-my-posh init bash --config /etc/oh-my-posh/theme.omp.json)"' >> /etc/bash.bashrc \
    && echo "$(command -v pwsh)" >> /etc/shells \
    && printf 'export PATH="/usr/local/bin:/home/hermes/.local/bin:$PATH"\n' > /etc/profile.d/hermes.sh

ARG GITHUB_CLI_VERSION=2.103.3
RUN <<'BASH'
artifact="gh_${GITHUB_CLI_VERSION}_linux_$(dpkg --print-architecture).deb"
release="https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}"
cd /tmp
curl -fsSL "$release/$artifact" -o "$artifact"
curl -fsSL "$release/gh_${GITHUB_CLI_VERSION}_checksums.txt" | grep -F " $artifact" | sha256sum --check --strict
dpkg -i "$artifact"
rm "$artifact"
BASH

ARG CODEX_VERSION=0.166.0
RUN --mount=type=cache,target=/root/.npm \
    npm install --prefix /usr/local -g --no-audit --no-fund "@openai/codex@${CODEX_VERSION}"

ARG CLAUDE_VERSION=2.1.314
RUN install -d -o hermes -g hermes /home/hermes/.local \
       /home/hermes/.local/bin /home/hermes/.local/share \
    && curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && runuser -u hermes -- bash /tmp/claude-install.sh "$CLAUDE_VERSION" \
    && rm /tmp/claude-install.sh \
    && ln -s /home/hermes/.local/bin/claude /usr/local/bin/claude \
    && printf 'model_reasoning_effort = "medium"\n' > /home/hermes/.codex/config.toml \
    && ln -s /home/hermes/.claude/CLAUDE.md /home/hermes/.codex/AGENTS.md \
    && chown -h hermes:hermes /home/hermes/.codex/AGENTS.md /home/hermes/.codex/config.toml

# The wrapper supplies the same runtime environment to Docker exec and SSH,
# including env -i; root invocations drop to hermes before touching user data.
COPY --chmod=755 hermes.sh /usr/local/bin/hermes
COPY sshd-hermes-gateway.conf /etc/ssh/sshd_config.d/10-hermes-gateway.conf
RUN chmod 644 /etc/ssh/sshd_config.d/10-hermes-gateway.conf \
    && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    && ln -s /opt/hermes/.venv/bin/hermes-acp /usr/local/bin/hermes-acp \
    && ln -s /opt/hermes/.venv/bin/hermes-agent /usr/local/bin/hermes-agent

# Reuse checks only: no installer, dependency repair or frontend compilation.
RUN --network=none timeout 60 runuser -u hermes -- hermes --version </dev/null \
    && timeout 60 runuser -u hermes -- hermes webapp --build-only </dev/null \
    && timeout 30 runuser -u hermes -- claude --version </dev/null \
    && timeout 30 runuser -u hermes -- codex --version </dev/null \
    && runuser -u hermes -- gh --version \
    && HOME=/root pwsh -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = "Stop"; Import-Module Terminal-Icons' \
    && node --version

# Keep the existing SSH contract and Compose init, not the upstream s6 entrypoint.
COPY --chmod=755 entrypoint.sh /usr/local/bin/hermes-entrypoint
COPY --chmod=755 start-services.sh /usr/local/bin/hermes-start-services
COPY --chmod=755 hermes-ssh-info.sh /usr/local/bin/hermes-ssh-info
COPY --chmod=755 webapp-open.py /usr/local/bin/hermes-webapp-open
RUN bash -n /usr/local/bin/hermes-entrypoint \
    && bash -n /usr/local/bin/hermes-start-services \
    && bash -n /usr/local/bin/hermes-ssh-info \
    && sh -n /usr/local/bin/hermes

ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
