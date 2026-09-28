# AI Hermes Devbox v1 -- the published ai-devbox image plus the Hermes Agent
# (Nous Research, https://hermes-agent.nousresearch.com/). CI builds this and
# publishes it as ai-hermes-devbox-v1-image; ai-devbox-image itself is
# unchanged.
#
# This is the pre-gateway generation of the Hermes template: the gateway,
# sshd and their supporting scripts live in ai-hermes-devbox instead. Here
# Hermes runs its own gateway and dashboard on loopback and nothing else
# listens.
#
# Unlike the ai-devbox Dockerfile, this one is NOT the full build recipe --
# it layers on the already-published base so the build is just the Hermes
# step instead of re-running the whole PowerShell/Oh My Posh/Node/agent-CLI
# install. publish-ai-hermes-devbox-v1.yml pulls ai-devbox-image:latest as
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
