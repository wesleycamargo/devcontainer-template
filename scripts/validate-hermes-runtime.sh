#!/usr/bin/env bash
# Run on the Docker host. Unit tests run separately, before build, in CI.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${HERMES_TEST_IMAGE:-hermes-devbox:test}"

# Keep the CLI lifecycle mandatory: no silent skip when devcontainer is missing.
do_D() {
  bash "$REPO_ROOT/scripts/validate-hermes-devcontainer.sh" "$IMAGE"
}

do_G() {
  python3 "$REPO_ROOT/scripts/validate-hermes-webapp.py" "$IMAGE"
}

checkpoint="${1:-all}"
case "$checkpoint" in
  build|all|A|B|C|D|E|G) ;;
  *) echo "usage: $0 [build|all|A|B|C|D|E|G]" >&2; exit 2 ;;
esac
command -v docker >/dev/null || { echo 'Docker is required; run on the Docker host.' >&2; exit 1; }
docker info >/dev/null
if [ "$checkpoint" = build ]; then
  docker build -t "$IMAGE" "$REPO_ROOT/src/ai-hermes-devbox/.devcontainer"
  exit
fi
steps=("$checkpoint")
if [ "$checkpoint" = all ]; then
  steps=(A B C D E G)
fi
for step in "${steps[@]}"; do
  printf '\n== %s: Hermes runtime ==\n' "$step"
  case "$step" in
    D) do_D ;;
    G) do_G ;;
    *) python3 "$REPO_ROOT/scripts/validate-hermes-runtime.py" "$IMAGE" "$step" ;;
  esac
done
printf '\nPASS: requested Hermes runtime checkpoints completed\n'
