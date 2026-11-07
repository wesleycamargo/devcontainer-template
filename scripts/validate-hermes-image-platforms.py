#!/usr/bin/env python3
"""Require AMD64 and ARM64 in a registry image index supplied on stdin."""

import json
import sys


def main():
    index = json.load(sys.stdin)
    platforms = {
        (manifest.get("platform", {}).get("os"),
         manifest.get("platform", {}).get("architecture"))
        for manifest in index.get("manifests", [])
    }
    required = {("linux", "amd64"), ("linux", "arm64")}
    missing = sorted("/".join(platform) for platform in required - platforms)
    if missing:
        print("missing platforms: " + ", ".join(missing), file=sys.stderr)
        return 1
    print("verified image platforms: linux/amd64, linux/arm64")
    return 0


if __name__ == "__main__":
    sys.exit(main())
