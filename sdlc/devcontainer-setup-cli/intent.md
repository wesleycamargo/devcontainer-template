# Intent: Interactive Devcontainer Setup CLI

## Problem

Setting up a machine to use this repository's published devcontainer images currently requires users to interpret platform-specific documentation and run a PowerShell helper manually. A new user must separately install the Dev Container CLI and a Docker Engine, select a supported template image, and handle Windows through WSL. This is high-friction and makes the published templates harder to adopt.

## Desired Outcome

Provide a publicly installable npm command-line package with an approachable, interactive setup flow built with `@clack/prompts`. It should prepare the supported host environment, let a user select among the available devcontainer images, and leave them with a usable devcontainer configuration and clear next steps.

## Scope

- Create a publishable npm package in this repository for the interactive setup command.
- Use `@clack/prompts` for platform-appropriate status, confirmation, selection, progress, and error interaction.
- Detect the host platform and provide a Linux setup path that installs or verifies Docker Engine and the Dev Container CLI.
- Provide a Windows path that detects or helps install WSL, then performs the Docker and Dev Container CLI setup inside the selected WSL distribution rather than using Docker Desktop.
- Offer the currently published images/templates: `ai-devbox`, `ai-hermes-devbox`, and `ai-openhands-devbox`.
- Produce the selected devcontainer configuration in the user-selected target project without overwriting files without explicit confirmation.
- Document installation, supported platforms, prerequisites, image choices, security expectations, and npm publication/release procedure.
- Add automated tests for platform detection, command planning, template selection/configuration generation, and safe file behavior.
- Add an npm-ready publication workflow, using GitHub Actions trusted publishing rather than a long-lived npm write token.

## Non-Goals

- Replacing the existing published devcontainer templates or their GitHub Container Registry publishing workflows.
- Supporting Docker Desktop as the Windows Docker backend.
- Guaranteeing unattended operating-system package installation when elevated privileges, package-manager interaction, a reboot, or WSL distro initialization requires user action.
- Publishing the package or modifying the owner's npm or GitHub account settings without the owner's authorization and credentials.
- Changing the behavior of existing `setup-devcontainer-client.ps1` beyond integration or documentation needed by the new tool.

## Constraints

- Windows must use a Docker Engine inside WSL, consistent with repository guidance.
- The npm package must be public and consumable from npmjs.com.
- The selected image references must track the repository's private GHCR package model and clearly guide users through required `gh`/Docker authentication.
- The current user working-tree changes, including `.vscode/settings.json`, are unrelated and must be preserved.
- The public unscoped package name is `devcontainer-setup-cli`. The CLI writes a raw, image-based `devcontainer.json`; a user who needs a template's complete multi-file configuration can still apply the published template separately.
- `.github/workflows/publish.yml` publishes a scoped GitHub Packages copy on `main` and `feature/*` pushes when the version is new. Its manual dispatch can target GitHub Packages, npm, or both; the npm path uses trusted publishing with OIDC and provenance.

## Success Criteria

- A user can install and invoke the npm CLI using the documented command.
- On Linux, the interactive flow verifies or installs Docker Engine and `@devcontainers/cli`, reports any required privilege/manual action, and verifies the resulting tools before continuing.
- On Windows, the flow targets WSL and never installs or requires Docker Desktop; it clearly handles absent WSL, absent distro, reboot, and elevation states.
- The flow presents all three published devcontainer choices with understandable descriptions and writes a valid, non-destructive configuration for the selected option.
- The package has automated tests covering its platform-specific decisions and generated output.
- A release workflow can publish the package from the designated GitHub repository through npm trusted publishing, with provenance.
- Documentation gives an owner enough exact npmjs.com configuration to enable the first release securely.

## Open Questions

- Which Linux distributions/package managers must be supported in the first release beyond Debian/Ubuntu?
