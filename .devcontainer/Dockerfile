# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/devcontainers/python:3.12-bookworm

# Fail the build if any download or command in a pipeline fails.
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV PATH="/home/vscode/.local/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1

# Install these here so they are available during the build and with Compose.
ARG NODE_MAJOR=24
RUN curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
        -o /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell nodejs \
    && rm -rf /var/lib/apt/lists/*

# Download only the prompt binary for this architecture, without extra themes.
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
RUN pwsh -NoLogo -NoProfile -NonInteractive -File /dev/stdin <<'PWSH'
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
    && chsh -s "$(command -v pwsh)" vscode

# GitHub CLI is part of the image, including when VS Code Features are absent.
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
    npm install -g --no-audit --no-fund "@openai/codex@${CODEX_VERSION}"

# One native Claude installation, owned by the user who runs it.
ARG CLAUDE_VERSION=2.1.314
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && runuser -u vscode -- bash /tmp/claude-install.sh "$CLAUDE_VERSION" \
    && rm /tmp/claude-install.sh

# Pin both the Hermes installer and checkout to the same release commit (v0.22.5).
# Keep the installation in /opt; each user's writable state lives in ~/.hermes.
ARG HERMES_COMMIT=bf0203a794a07aac3ff764972ab9087baa4e4f4e
RUN --mount=type=cache,target=/root/.cache/uv <<'BASH'
curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
    -o /tmp/hermes-install.sh
bash /tmp/hermes-install.sh --non-interactive --skip-setup \
    --skip-browser --skip-computer-use --hermes-home /opt/hermes --commit "$HERMES_COMMIT"
rm /tmp/hermes-install.sh
# Apply permissions before committing this layer, avoiding a second copy of the tree.
for directory in /opt/hermes /usr/local/lib/hermes-agent /usr/local/share/uv; do
    if [ -e "$directory" ]; then chmod -R a+rX "$directory"; fi
done
for command in hermes hermes-acp; do
    launcher="/opt/hermes/hermes-agent/.hermes/bin/$command"
    test -x "$launcher"
    ln -sfn "$launcher" "/usr/local/bin/$command"
done
BASH

# Container-local config avoids sharing host-specific plugin paths and databases.
# The auth file alone is mounted by Compose. Global agent instructions are shared.
RUN install -d -o vscode -g vscode /home/vscode/.codex /home/vscode/.cache \
    && printf 'model_reasoning_effort = "medium"\n' > /home/vscode/.codex/config.toml \
    && ln -s /home/vscode/.claude/CLAUDE.md /home/vscode/.codex/AGENTS.md \
    && chown -R vscode:vscode /home/vscode/.codex

# Smoke checks use the development user, without loading an interactive profile.
RUN timeout 600 runuser -u vscode -- hermes pm repair </dev/null \
    && timeout 60 runuser -u vscode -- hermes --version </dev/null \
    && timeout 30 runuser -u vscode -- claude --version </dev/null \
    && timeout 30 runuser -u vscode -- codex --version </dev/null \
    && runuser -u vscode -- gh --version \
    && pwsh -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = "Stop"; Import-Module Terminal-Icons' \
    && node --version

# Repair ownership on reused runtime volumes before Compose initializes Hermes.
COPY --chmod=755 entrypoint.sh /usr/local/bin/devbox-entrypoint
ENTRYPOINT ["/usr/local/bin/devbox-entrypoint"]
CMD ["python3"]
