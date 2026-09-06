#!/usr/bin/env bash
set -euo pipefail

root="src/ai-openhands-devbox"
compose="$root/.devcontainer/docker-compose.yml"
config="$root/.devcontainer/devcontainer.json"
metadata="$root/devcontainer-template.json"
workflow=".github/workflows/publish-ai-openhands-devbox.yml"

for file in "$compose" "$config" "$metadata" "$workflow" "$root/README.md"; do
  test -f "$file"
done

grep -Fq 'ghcr.io/openhands/agent-canvas:' "$compose"
grep -Fq 'network_mode: service:devcontainer' "$compose"
grep -Fq 'agent-canvas-data:/home/openhands/.openhands' "$compose"
grep -Fq '..:/projects/devcontainer-template:rw' "$compose"
! grep -Fq '/var/run/docker.sock' "$compose"
! grep -Fq 'privileged:' "$compose"
grep -Fq '"forwardPorts": [8000]' "$config"
grep -Fq '"id": "ai-openhands-devbox"' "$metadata"
grep -Fq "TEMPLATE_ID: ai-openhands-devbox" "$workflow"
grep -Fq 'CODEX_AUTH_JSON' "$root/README.md"

echo 'ai-openhands-devbox static configuration checks passed'