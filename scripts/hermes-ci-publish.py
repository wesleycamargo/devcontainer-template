#!/usr/bin/env python3
"""Decide whether the current event may publish the Hermes template."""

import json
from pathlib import Path
import re
import subprocess
import sys


def should_publish(event_name, event):
    if event_name == "workflow_dispatch":
        return True
    if event_name != "push" or event.get("deleted"):
        return False
    before = event.get("before", "")
    after = event.get("after", "")
    if not all(re.fullmatch(r"[0-9a-fA-F]{40}", value) for value in (before, after)):
        raise ValueError("Push event must contain complete before/after commit SHAs")
    if before == "0" * 40:
        command = ["git", "ls-tree", "-r", "--name-only", "-z", after]
    else:
        command = ["git", "diff", "--name-only", "-z", before, after]
    changed = subprocess.check_output(command + ["--", "src/ai-hermes-devbox/"])
    return any(path.startswith(b"src/ai-hermes-devbox/") for path in changed.split(b"\0"))


if __name__ == "__main__":
    event_name, event_path = sys.argv[1:]
    event = json.loads(Path(event_path).read_text())
    print("true" if should_publish(event_name, event) else "false")
