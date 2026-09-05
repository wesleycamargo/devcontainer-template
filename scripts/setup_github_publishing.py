#!/usr/bin/env python3
"""One-time GitHub-side setup for the "Publish Dev Container Templates" workflow:
grants the workflow write access, pushes main, watches the first run, then
confirms the published ghcr.io package stayed private.

Requires: gh CLI, authenticated (`gh auth login`), run from inside the repo.
"""
import argparse
import json
import shutil
import subprocess
import sys
import time
import urllib.parse


def run(cmd, **kwargs):
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, **kwargs)


def capture(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="wesleycamargo/devcontainer-template")
    parser.add_argument("--template-id", default="powershell")
    args = parser.parse_args()

    owner = args.repo.split("/")[0]
    package_name = f"devcontainer-template/{args.template_id}"

    if not shutil.which("gh"):
        sys.exit("gh CLI not found: https://cli.github.com/")
    run(["gh", "auth", "status"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(f"==> Granting the workflow read/write permissions on {args.repo}")
    run([
        "gh", "api", "-X", "PUT", f"repos/{args.repo}/actions/permissions/workflow",
        "-f", "default_workflow_permissions=write",
        "-F", "can_approve_pull_request_reviews=false",
    ])

    print("==> Pushing current branch")
    run(["git", "push"])

    head_sha = capture(["git", "rev-parse", "HEAD"])
    print(f"==> Waiting for the publish.yml run for commit {head_sha}")
    run_id = None
    for _ in range(15):
        out = capture([
            "gh", "run", "list", "--repo", args.repo, "--workflow", "publish.yml",
            "--json", "databaseId,headSha",
        ])
        matches = [r["databaseId"] for r in json.loads(out) if r["headSha"] == head_sha]
        if matches:
            run_id = matches[0]
            break
        time.sleep(2)
    if run_id is None:
        sys.exit(f"Run never showed up for {head_sha}; check the Actions tab.")

    print(f"==> Watching run {run_id}")
    run(["gh", "run", "watch", str(run_id), "--repo", args.repo, "--exit-status"])

    print(f"==> Confirming package visibility: {package_name}")
    encoded_name = urllib.parse.quote(package_name, safe="")
    run([
        "gh", "api", "-X", "PATCH", f"user/packages/container/{encoded_name}",
        "-f", "visibility=private",
    ])

    print(f"Done. Package: https://github.com/users/{owner}/packages/container/package/{encoded_name}")


if __name__ == "__main__":
    main()
