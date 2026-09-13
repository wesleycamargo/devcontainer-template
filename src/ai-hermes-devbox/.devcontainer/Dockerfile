# AI Hermes Devbox -- the published ai-devbox image plus the Hermes Agent
# (Nous Research, https://hermes-agent.nousresearch.com/). CI builds this and
# publishes it as ai-hermes-devbox-image; ai-devbox-image itself is unchanged.
#
# Unlike the ai-devbox Dockerfile, this one is NOT the full build recipe --
# it layers on the already-published base so the build is just the Hermes
# step instead of re-running the whole PowerShell/Oh My Posh/Node/agent-CLI
# install. publish-ai-hermes-devbox.yml pulls ai-devbox-image:latest as
# published by the ai-devbox workflow; a base rebuild does not retrigger
# this one, so :latest is whatever ai-devbox last published.
FROM ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest

# Full install: Playwright/Chromium and the computer-use driver are included
# (no --skip-browser / --skip-computer-use). Run as vscode so Hermes installs
# into that user's home with hermes/hermes-agent/hermes-acp symlinked into
# ~/.local/bin -- already on PATH in the base image -- mirroring how the
# ai-devbox Dockerfile runs `claude install`. Piping the script to bash selects
# the installer's non-interactive defaults; --skip-setup skips the API-key
# wizard so the build doesn't block on it. Chromium's system libraries are
# pulled in by the installer through the vscode user's passwordless sudo
# (provided by the devcontainers base image).
RUN su vscode -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-setup'

# The base image makes pwsh vscode's login shell. Hermes' SSH terminal backend
# runs its one-shot commands (sudo, stdin) through the SSH user's login shell
# and expects POSIX sh, so switch it back to bash. VS Code terminals still open
# pwsh via terminal.integrated.defaultProfile.linux in devcontainer.json, and
# bash login shells get ~/.local/bin on PATH from ~/.profile.
RUN chsh -s /bin/bash vscode
