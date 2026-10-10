# Debian bookworm base (GLIBC 2.36) -- avoids the minimum-GLIBC check VS Code
# Server enforces (older bases like Ubuntu 20.04 fail it).
FROM mcr.microsoft.com/devcontainers/python:3.12-bookworm

# PowerShell, installed directly (not via the devcontainer feature) so later
# RUN steps in this Dockerfile can invoke `pwsh` at build time -- features are
# layered on after the Dockerfile builds, so a feature-provided pwsh wouldn't
# exist yet when this file runs.
RUN apt-get update && apt-get install -y wget \
    && wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update && apt-get install -y powershell \
    && rm -rf /var/lib/apt/lists/*

# Oh My Posh + theme, baked into the image instead of fetched by
# postCreateCommand on every container creation.
RUN curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin \
    && mkdir -p /etc/oh-my-posh \
    && curl -fsSL 'https://gist.githubusercontent.com/wesleycamargo/06b58b472fe0cded2e6d6451ea0778bd/raw/1c952297121a50826ef6f849bb7ee8c11d8e09a6/oh-my-posh-az-cli-az-pwsh.json' \
       -o /etc/oh-my-posh/theme.omp.json

# Terminal-Icons + an all-users PowerShell profile wiring both of the above in.
# Also prepends ~/.local/bin to PATH here (pwsh is vscode's login shell --
# chsh below -- so bash's rc files never run; without this, `claude install`'s
# native build in ~/.local/bin is invisible and the CLI nags that itself is
# "missing or broken").
# Note: a here-string (@' ... '@) won't survive Dockerfile line-continuation
# (Docker joins continued lines by stripping the newline, so the closing '@
# would no longer be alone on its own line) -- `n inside a normal quoted
# string sidesteps that since it doesn't depend on real newlines surviving.
RUN pwsh -NoProfile -Command ' \
    Install-Module -Name Terminal-Icons -Force -Scope AllUsers; \
    Set-Content -Path $PROFILE.AllUsersAllHosts -Value "if (Test-Path `$HOME/.local/bin) { `$env:PATH = `"`$HOME/.local/bin`$([IO.Path]::PathSeparator)`$env:PATH`" }`nif (Get-Module -ListAvailable -Name Terminal-Icons) { Import-Module Terminal-Icons }`noh-my-posh init pwsh --config /etc/oh-my-posh/theme.omp.json | Invoke-Expression" \
'

# Same prompt for bash, and make pwsh the vscode user's default shell (both
# previously done at container-create time via postCreateCommand).
RUN echo 'eval "$(oh-my-posh init bash --config /etc/oh-my-posh/theme.omp.json)"' >> /etc/bash.bashrc \
    && echo "$(command -v pwsh)" >> /etc/shells \
    && chsh -s "$(command -v pwsh)" vscode

# Node.js/npm (apt's default is too old for the packages below)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs

# Agent CLIs
RUN npm install -g @anthropic-ai/claude-code @openai/codex
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc

# Skills CLI, plus the shared startup script (both templates' docker-compose.yml
# run this on every container start) that pulls .agents/skills from upstream and
# exposes it to every configured agent via the CLI, at project and global scope.
RUN npm install -g skills
COPY scripts/sync-project-skills.sh /usr/local/bin/sync-project-skills
RUN chmod +x /usr/local/bin/sync-project-skills

# Pre-install Claude Code's self-managed native build into vscode's home.
# The CLI's own self-check expects ~/.local/bin/claude to exist alongside the
# npm-installed copy; without this it nags "missing or broken" on every start.
RUN su vscode -c 'claude install'

# Hermes Agent CLI (Nous Research, https://hermes-agent.nousresearch.com/) --
# lean install: no browser/computer-use, no SSH gateway, no dashboard, no user
# rename. Just the `hermes` binary so it's available like the other agent
# CLIs above; run `hermes` once to set up API keys and connectors.
#
# Installed as ROOT (not su vscode, unlike `claude install` above), which
# selects the installer's FHS layout: launchers in /usr/local/bin/{hermes,
# hermes-agent,hermes-acp}, code in /usr/local/lib/hermes-agent. That layout
# is load-bearing: src/ai-hermes-devbox/.devcontainer/Dockerfile (FROM this
# image) re-runs this same installer as root, to the same --hermes-home, to
# add the full browser/computer-use install -- it upgrades these exact paths
# in place rather than installing a second, conflicting copy. Keep
# --hermes-home in sync between the two Dockerfiles if it ever changes.
# --skip-browser --skip-computer-use keeps this layer lean (see that
# Dockerfile's own full install for what gets added back). --skip-setup skips
# the interactive API-key wizard so the build doesn't block on it.
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- \
      --non-interactive --skip-setup --skip-browser --skip-computer-use \
      --hermes-home /opt/hermes

# Make the root-owned install readable/traversable by vscode (and by `hermes`,
# after ai-hermes-devbox's own user rename). Mirrors that Dockerfile's
# identical permission fix over the same paths.
RUN for d in /opt/hermes /usr/local/lib/hermes-agent /usr/local/share/uv; do \
      if [ -e "$d" ]; then chmod -R a+rX "$d"; fi; \
    done

# Build-time proof the CLI actually works for the image's default user.
RUN timeout 180 su vscode -c 'hermes --version' </dev/null

# Codex's config dir, created here (owned by vscode) so the auth.json bind mount
# in devcontainer.json doesn't make Docker create the parent as root -- that
# would leave Codex unable to write its own session state.
#
# config.toml is written fresh instead of reusing the host's: that one is
# generated by the Codex desktop app on Windows and is full of Windows-only
# paths (a `notify` hook .exe, the `node_repl` MCP server .exe, `\\?\C:\...`
# marketplace sources) that don't resolve in a Linux container. Only the model
# settings carry over.
#
# AGENTS.md is symlinked to the same global agent guidelines Claude Code reads
# from ~/.claude/CLAUDE.md (bind-mounted from the host), so both agents start
# with identical global instructions rather than two copies that drift. Project
# context comes from the repo's own AGENTS.md, which Codex reads by default.
RUN mkdir -p /home/vscode/.codex && \
    printf 'model = "gpt-5.5"\nmodel_reasoning_effort = "medium"\n' > /home/vscode/.codex/config.toml && \
    ln -s /home/vscode/.claude/CLAUDE.md /home/vscode/.codex/AGENTS.md && \
    chown -R vscode:vscode /home/vscode/.codex
