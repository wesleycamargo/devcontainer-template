#!/usr/bin/env bash

set -euo pipefail

# npm detects GitHub Actions' OIDC token and performs trusted publishing. No
# long-lived NPM_TOKEN is used or accepted by this release path.
npm publish --access public --provenance
