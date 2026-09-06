# OpenHands evaluation and possible Open WebUI replacement

## Goal

Determine whether OpenHands should replace the Open WebUI companion service, and—only if the security and workflow gates pass—ship a pinned, documented OpenHands integration without weakening the devcontainer's safety guarantees.

## Recommendation

Do **not** replace Open WebUI by default.

Open WebUI is a lightweight chat frontend to the Hermes OpenAI-compatible gateway: it shares the devcontainer network namespace, calls `http://127.0.0.1:8642/v1`, and persists only its UI data. OpenHands is a separate autonomous coding-agent product. Its normal local deployment launches an additional sandbox container per agent run and requires access to the Docker daemon. It has its own LLM/provider configuration and agent loop; it is not a drop-in OpenAI-chat frontend for Hermes.

It is worth adding only as an opt-in experimental companion when the desired outcome is: “give an autonomous agent write access to this repository in an isolated sandbox.” It is not worth replacing Open WebUI when the desired outcome is: “keep a browser UI for Hermes chats and tools.” For the latter, retain Open WebUI (or use the existing Hermes dashboard) and avoid the Docker-socket exposure.

Sources consulted during planning:

- OpenHands local setup: <https://docs.openhands.dev/openhands/usage/run-openhands/local-setup>
- OpenHands custom sandbox (V1): <https://docs.openhands.dev/openhands/usage/advanced/custom-sandbox-guide>
- OpenHands Docker runtime security/mount guidance: <https://docs.openhands.dev/openhands/usage/v0/runtimes/V0_docker> (explicitly marked legacy by OpenHands; use it only for its mount-risk background)

## Current context / assumptions

- The root `.devcontainer/` is the personal devcontainer. `src/ai-hermes-devbox/.devcontainer/` is the published template; `AGENTS.md` requires their relevant Compose, devcontainer JSON, and startup-script changes to be mirrored.
- Both current Compose files run `open-webui` as a companion service with `network_mode: service:devcontainer`. It reads an API key from `.devcontainer/.openwebui.env`, calls Hermes at `127.0.0.1:8642/v1`, and persists state in `open-webui-data`.
- `.devcontainer/start-hermes.sh` and its published-template counterpart generate the Open WebUI/Hermes shared credentials. `devcontainer.json` forwards ports 9119 (Hermes dashboard) and 8080 (Open WebUI).
- Hermes itself is already installed in the image and its full state persists in the `hermes-data` named volume.
- OpenHands V1 uses an `agent-server` sandbox image, not an arbitrary shell container. Custom tooling requires building an agent-server image on top of a Debian-based base image.
- A Docker socket mounted into a container effectively grants control of the Docker host. In this setup it can also allow OpenHands to launch containers that access the checked-out repository. Treat this as a high-risk, single-user development-only capability.
- Docker was unavailable in the planning environment. The implementation must run all Docker/Dev Container checks on a host with Docker Desktop (WSL integration enabled) or a Linux Docker Engine.

## Architecture / proposed approach

Use a decision-gated, opt-in OpenHands experiment first; do not alter the published default template until it proves useful. Run the OpenHands UI as an isolated Compose profile or explicit override, give it a dedicated named state volume, and mount the Docker socket only after the user knowingly accepts that trust boundary. Keep Hermes and Open WebUI unchanged during the prototype so the fallback path is one command away.

If the prototype is accepted, choose one of two deliberate products: (1) keep Open WebUI plus an opt-in OpenHands profile (recommended), or (2) remove Open WebUI and document that the template now provides an autonomous coding-agent UI rather than a Hermes chat UI. Do not attempt to route OpenHands through Hermes's gateway until a compatibility spike proves that OpenHands can use it as its LLM provider without losing its sandbox/tool behavior.

## Step-by-step tasks

### 1. Record the product decision and security approval before changing Compose

1. Confirm the intended workflow with the repository owner:
   - Is OpenHands intended to be an autonomous code editor for the current workspace, or only a chat UI for Hermes?
   - Is Docker socket access acceptable for this single-user development container?
   - Must OpenHands retain its own provider credentials, or must it use the existing Hermes/Codex model configuration?
2. Do not proceed with a replacement if any answer is “chat UI,” “no Docker socket,” or “must use Hermes gateway” without a successful compatibility spike.
3. Record the explicit outcome in `src/ai-hermes-devbox/README.md` under a new `## OpenHands (optional)` section only after approval.
4. Commit the decision/documentation-only change separately:

   ```bash
   git add src/ai-hermes-devbox/README.md
   git commit -m "docs: document OpenHands integration decision"
   ```

   Expected output: one commit with only the README staged and no credentials, `.env` files, or generated keys.

### 2. Establish host prerequisites and baseline behavior (no configuration edits)

Run these commands on the actual Docker-capable host from the repository root:

```bash
docker version
docker context show
docker info --format '{{.OperatingSystem}}'
docker compose version
devcontainer --version
```

Expected output: Docker client and server versions, a selected Docker context, Docker Desktop/Linux engine information, Compose v2, and a Dev Containers CLI version. On WSL, Docker Desktop must have WSL integration enabled for this distribution.

Then capture the current working baseline:

```bash
docker compose -f .devcontainer/docker-compose.yml config >/tmp/ai-hermes-devbox-current-compose.yml
devcontainer read-configuration --workspace-folder .
```

Expected output: exit status 0. Save the first command’s rendered Compose file only in `/tmp`; do not commit it.

### 3. Run a disposable OpenHands compatibility spike outside the template

Do not edit either checked-in Compose file for this task. Use a throwaway directory outside the repository and the current OpenHands local-setup instructions.

1. Install or invoke OpenHands using its documented `uv` launcher on the Docker host:

   ```bash
   uv tool install openhands --python 3.12
   openhands serve --mount-cwd
   ```

   Expected output: OpenHands reports a local GUI URL and successfully pulls/starts its required images. Stop it after the test.
2. In the browser, create a test conversation that only lists the workspace root and creates then deletes a uniquely named scratch file. Verify the file appears and disappears from the host checkout.
3. Inspect the Docker objects created by the test:

   ```bash
   docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
   docker image ls --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}' | grep -i openhands
   ```

   Expected output: an OpenHands application and one or more agent-server/sandbox containers/images. Record image names, image tags/digests, ports, and the exact workspace mount behavior in the implementation issue.
4. Delete only the disposable test containers and scratch artifacts. Do not run `docker system prune` and do not delete project volumes.
5. Decision gate: stop and retain Open WebUI if the OpenHands launcher cannot reliably access the Docker daemon, cannot mount the workspace with the intended UID, or requires broader mounts/privilege than the owner accepts.

### 4. Prove or reject Hermes gateway compatibility before designing an integration

This is a spike, not a production configuration.

1. Start the existing devcontainer and confirm Hermes’s gateway is reachable from the devcontainer namespace:

   ```bash
   curl --fail --silent --show-error http://127.0.0.1:8642/v1/models \
     -H "Authorization: Bearer $API_SERVER_KEY"
   ```

   Expected output: JSON containing the configured Hermes model. If `API_SERVER_KEY` is unavailable, stop; do not print or add it to a command history or repository file.
2. Read the currently installed OpenHands provider configuration documentation and identify whether its current release supports an OpenAI-compatible base URL plus the required authorization header for this endpoint. Capture the exact documented configuration keys and release version in the implementation issue.
3. Configure the disposable OpenHands instance only with an ephemeral environment file outside the repository. Ask it to perform a harmless task (`pwd` and list files only).
4. Accept the compatibility path only if the OpenHands UI completes the task through Hermes without sending requests to an unintended provider and without attempting to use Hermes tools as a substitute for its sandbox.
5. If any of these conditions fail, configure OpenHands with its own supported model provider instead. Do not add a fragile Hermes-gateway bridge merely to avoid a second provider configuration.

### 5. Add OpenHands as an opt-in profile, not a replacement

Only after Steps 1–4 pass, add an opt-in service to both:

- `.devcontainer/docker-compose.yml`
- `src/ai-hermes-devbox/.devcontainer/docker-compose.yml`

Use a Compose profile named `openhands`, a distinct `openhands-data` named volume, and an explicit pinned image digest discovered in Step 3. Do not use a floating `latest` or `main` tag. Keep the existing `open-webui` service unchanged during this phase.

The service must satisfy all of these acceptance requirements before it is committed:

- It does not publish a host port; add its UI port to the matching `forwardPorts` arrays only after confirming its actual listening port from the pinned OpenHands release.
- It has a persistent application-state mount at `/.openhands` using `openhands-data`.
- It uses the Docker socket only through an explicit, prominent `# SECURITY:` comment immediately above the mount explaining that it grants Docker-host control and is suitable only for a trusted single user.
- Its workspace sandbox mount uses an explicitly configured absolute host path, never a guessed `/mnt/c/...` path and never an implicit path that differs between WSL, Linux, and macOS.
- The host workspace path is supplied through a Git-ignored local environment file with a checked-in `.example` file containing no secrets. The example must fail closed: if the variable is unset, `docker compose --profile openhands config` must error rather than silently mounting an unintended directory.
- It pins both the OpenHands application image and the agent-server image/tag or digest.
- It does not share `network_mode: service:devcontainer` unless Step 4 proves that is required for an intentional Hermes integration. Prefer its own default Compose network to reduce coupling.

Before implementing, write an integration test script at `scripts/test_openhands_compose.sh` that expects the local environment file path as its only argument. Write the failing test first. Its required assertions are:

```bash
#!/usr/bin/env bash
set -euo pipefail

env_file="${1:?usage: $0 PATH_TO_OPENHANDS_ENV}"
compose_files=(-f .devcontainer/docker-compose.yml --env-file "$env_file")

rendered="$(docker compose "${compose_files[@]}" --profile openhands config)"
printf '%s\n' "$rendered" | grep -F 'openhands-data:'
printf '%s\n' "$rendered" | grep -F '/var/run/docker.sock:/var/run/docker.sock'
printf '%s\n' "$rendered" | grep -F 'OPENHANDS_WORKSPACE'
printf '%s\n' "$rendered" | grep -F 'profiles:'
```

The implementer must replace the `OPENHANDS_WORKSPACE` assertion with an assertion against the rendered absolute path after confirming Compose variable interpolation behavior on the target Docker host. This prevents a false pass caused by inspecting unrendered Compose input.

Run the failing test before service implementation:

```bash
chmod +x scripts/test_openhands_compose.sh
scripts/test_openhands_compose.sh .devcontainer/.openhands.env
```

Expected output before implementation: non-zero, because the profile/service and test fixture do not exist. After the minimal Compose change and a real, ignored `.devcontainer/.openhands.env` fixture, expected output: exit status 0 and no secret values printed.

Commit this isolated addition:

```bash
git add .devcontainer/docker-compose.yml src/ai-hermes-devbox/.devcontainer/docker-compose.yml \
  .devcontainer/devcontainer.json src/ai-hermes-devbox/.devcontainer/devcontainer.json \
  .devcontainer/.gitignore src/ai-hermes-devbox/.devcontainer/.gitignore \
  scripts/test_openhands_compose.sh

git commit -m "feat: add opt-in OpenHands devcontainer profile"
```

### 6. Perform a full runtime validation before considering a replacement

On the Docker-capable host, run:

```bash
docker compose -f .devcontainer/docker-compose.yml --env-file .devcontainer/.openhands.env --profile openhands config
docker compose -f .devcontainer/docker-compose.yml --env-file .devcontainer/.openhands.env --profile openhands up -d
docker compose -f .devcontainer/docker-compose.yml --profile openhands ps
devcontainer up --workspace-folder .
```

Expected output:

- Compose config exits 0 and renders only the intended OpenHands workspace mount.
- All services report running/healthy where the image supports health checks.
- Dev Containers opens successfully and continues to forward Hermes/Open WebUI ports exactly as before; OpenHands’s confirmed UI port is also forwarded only when its profile is enabled.

In OpenHands, run these acceptance scenarios against a disposable test repository, not this configuration repository:

1. Read a file and explain it; verify no file changes.
2. Create a file, inspect `git diff`, then revert it; verify changes appear in the intended workspace only.
3. Run a test command; verify execution occurs in the OpenHands sandbox, not by using the Hermes gateway’s terminal tool.
4. Stop and start Compose; verify OpenHands session/app state persists in `openhands-data` and Hermes state still persists in `hermes-data`.
5. With the OpenHands profile disabled, verify Open WebUI and Hermes still work exactly as before.

Collect logs without exposing keys:

```bash
docker compose -f .devcontainer/docker-compose.yml --profile openhands logs --tail=200 openhands
```

Expected output: normal startup and sandbox creation logs, with no API key values. If secrets appear, stop and fix log redaction/configuration before proceeding.

### 7. Decide whether to retain both products or make the breaking replacement

Default decision: retain both and document OpenHands as optional. This is the lowest-risk outcome and preserves a direct GUI to Hermes.

Only if the owner explicitly chooses a breaking replacement after Step 6:

1. Remove the `open-webui` service and `open-webui-data` volume from both Compose files.
2. Remove port 8080 and replace it with the confirmed OpenHands UI port in both devcontainer JSON files.
3. Remove only the Open WebUI-specific key generation from both `start-hermes.sh` files. Preserve Hermes gateway/dashboard startup and Codex seeding.
4. Remove `.openwebui.env` from both `.devcontainer/.gitignore` files; add the ignored OpenHands local environment filename instead.
5. Update `.devcontainer/README.md` and `src/ai-hermes-devbox/README.md` to state precisely that OpenHands is an autonomous code-agent UI, requires a Docker daemon/socket, runs sandbox containers, and is not a Hermes chat frontend.
6. Re-run all commands in Step 6 and add a regression check that no `open-webui` or `OPENAI_API_BASE_URL` references remain:

   ```bash
   git grep -n -E 'open-webui|openwebui|OPENAI_API_BASE_URL' -- \
     .devcontainer src/ai-hermes-devbox
   ```

   Expected output: no matches after a complete replacement, except deliberately retained migration notes explicitly reviewed by the owner.
7. Commit the removal separately:

   ```bash
   git add .devcontainer src/ai-hermes-devbox
   git commit -m "feat!: replace Open WebUI with OpenHands"
   ```

## Tests / validation

- Follow red-green-refactor for each script or Compose-validation addition: write the failing assertion, run it and confirm a non-zero exit, make the smallest configuration change, then rerun until it exits 0.
- Run `bash -n .devcontainer/start-hermes.sh src/ai-hermes-devbox/.devcontainer/start-hermes.sh` after every startup-script change; expected output is empty with exit status 0.
- Run `git diff --check` before every commit; expected output is empty with exit status 0.
- Render and start both root and published-template Compose files. They must remain equivalent in behavior; do not validate only the root copy.
- Test profile-off and profile-on paths. The default profile must work without any OpenHands-specific local files, host paths, provider credentials, or Docker-socket use.
- Never commit `.openhands.env`, API keys, OAuth tokens, generated session secrets, rendered Compose output, Docker logs containing secrets, or Docker socket paths disguised as credentials.

## Risks, tradeoffs, and open questions

- **High security risk:** Docker socket access is effectively Docker-host root control. An LLM-directed OpenHands sandbox must be treated as trusted-code execution, not as the containment boundary offered by Hermes/Open WebUI.
- **Not a product-equivalent replacement:** OpenHands emphasizes autonomous coding and sandbox execution; Open WebUI is a model/chat frontend. Removing Open WebUI removes the simple Hermes chat workflow and direct gateway UI configuration.
- **Workspace path portability:** OpenHands sandbox mounts are host-Docker paths. WSL, Docker Desktop, Linux, and remote Docker contexts may resolve paths differently. This requires a tested, explicit local configuration rather than a checked-in hardcoded path.
- **Resource cost:** OpenHands needs its UI plus agent-server/sandbox images and recommends at least 4 GB RAM. It will consume materially more disk, CPU, and memory than Open WebUI.
- **Provider compatibility is unproven:** The current Hermes gateway is OpenAI-compatible, but OpenHands’s exact provider settings, authentication behavior, and tool-loop expectations must be proven with the version pinned at implementation time. Do not assume `OPENAI_API_BASE_URL` is sufficient.
- **Lifecycle complexity:** OpenHands may create short-lived sandbox containers outside the Compose service graph. Cleanup, logs, network access, image updates, and UID ownership require explicit operational documentation.
- **Image/version drift:** OpenHands documentation and image tags change independently. Resolve and pin current image digests during the spike; do not copy the provisional versions shown in online examples blindly.
- **Published-template impact:** Any default integration affects all users of `ai-hermes-devbox`; keep it optional unless the security and usability tradeoffs are acceptable for every consumer.
