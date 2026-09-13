#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-time client-side setup for using this repo's devcontainer templates
  and their published ghcr.io images. Safe to re-run.

.DESCRIPTION
  Verifies/installs Git, GitHub CLI, Docker, VS Code, and the VS Code Dev
  Containers extension, then authenticates `gh` with the `read:packages`
  scope and logs Docker in to ghcr.io so the private
  ghcr.io/wesleycamargo/devcontainer-template/* packages can be pulled.

  Windows: installs missing tools via winget.
  macOS: installs missing tools via Homebrew.
  Linux: checks for tools and prints install instructions for anything
  missing (package managers vary too much to automate safely here).
#>

$ErrorActionPreference = 'Stop'

function Write-Step  ([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok    ([string]$Message) { Write-Host "    ok: $Message" -ForegroundColor Green }
function Write-Warn2 ([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$OS =
    if (-not (Test-Path variable:IsWindows)) {
        'windows'  # Windows PowerShell 5.1 has no $IsWindows/$IsMacOS/$IsLinux; it only runs on Windows
    } elseif ($IsWindows) {
        'windows'
    } elseif ($IsMacOS) {
        'macos'
    } else {
        'linux'
    }

$manualInstallNeeded = New-Object System.Collections.Generic.List[string]

function Install-Tool {
    param(
        [string]$Name,
        [string]$Command,
        [string]$WingetId,
        [string]$BrewFormula,
        [switch]$BrewCask,
        [string]$LinuxHint
    )
    Write-Step $Name
    if (Test-Command $Command) {
        Write-Ok "$Name already installed"
        return
    }
    switch ($OS) {
        'windows' {
            if (-not (Test-Command 'winget')) {
                Write-Warn2 "winget not found; install $Name manually"
                $manualInstallNeeded.Add($Name)
                return
            }
            winget install --id $WingetId -e --accept-source-agreements --accept-package-agreements
        }
        'macos' {
            if (-not (Test-Command 'brew')) {
                Write-Warn2 "Homebrew not found; install $Name manually (https://brew.sh)"
                $manualInstallNeeded.Add($Name)
                return
            }
            if ($BrewCask) { brew install --cask $BrewFormula } else { brew install $BrewFormula }
        }
        'linux' {
            Write-Warn2 "$Name not found. $LinuxHint"
            $manualInstallNeeded.Add($Name)
        }
    }
}

Install-Tool -Name 'Git' -Command 'git' -WingetId 'Git.Git' -BrewFormula 'git' `
    -LinuxHint 'Install via your distro package manager, e.g. `sudo apt install git`.'

Install-Tool -Name 'GitHub CLI' -Command 'gh' -WingetId 'GitHub.cli' -BrewFormula 'gh' `
    -LinuxHint 'See https://github.com/cli/cli/blob/trunk/docs/install_linux.md'

Install-Tool -Name 'Docker' -Command 'docker' -WingetId 'Docker.DockerDesktop' -BrewFormula 'docker' -BrewCask `
    -LinuxHint 'See https://docs.docker.com/engine/install/'

Install-Tool -Name 'Visual Studio Code' -Command 'code' -WingetId 'Microsoft.VisualStudioCode' -BrewFormula 'visual-studio-code' -BrewCask `
    -LinuxHint 'See https://code.visualstudio.com/docs/setup/linux'

Write-Step 'VS Code Dev Containers extension'
if (Test-Command 'code') {
    $extensions = code --list-extensions 2>$null
    if ($extensions -contains 'ms-vscode-remote.remote-containers') {
        Write-Ok 'Dev Containers extension already installed'
    } else {
        code --install-extension ms-vscode-remote.remote-containers
    }
} else {
    Write-Warn2 'VS Code CLI (code) not on PATH yet; install the Dev Containers extension after restarting your terminal, or manually: https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers'
    $manualInstallNeeded.Add('Dev Containers extension')
}

Write-Step 'GitHub authentication (read:packages scope)'
$ghAvailable = Test-Command 'gh'
if (-not $ghAvailable) {
    Write-Warn2 'gh CLI unavailable; skipping GitHub auth and ghcr.io login'
} else {
    $authStatus = gh auth status 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host '    logging in to GitHub...'
        gh auth login --hostname github.com --git-protocol https --web --scopes 'read:packages'
    } elseif ($authStatus -notmatch 'read:packages') {
        Write-Host '    refreshing token scope...'
        gh auth refresh -h github.com -s read:packages
    } else {
        Write-Ok 'gh already authenticated with read:packages'
    }
}

Write-Step 'Docker login to ghcr.io'
if (-not $ghAvailable) {
    Write-Warn2 'gh CLI unavailable; cannot obtain a token for ghcr.io login'
} elseif (-not (Test-Command 'docker')) {
    Write-Warn2 'docker CLI unavailable; skipping ghcr.io login'
} else {
    $ghcrUser = (gh api user -q .login 2>$null)
    if (-not $ghcrUser) {
        Write-Warn2 'Not logged in to gh; skipping ghcr.io login'
    } else {
        gh auth token | docker login ghcr.io -u $ghcrUser --password-stdin
    }
}

Write-Step 'Summary'
if ($manualInstallNeeded.Count -gt 0) {
    Write-Warn2 "Install these manually, then re-run this script: $($manualInstallNeeded -join ', ')"
} else {
    Write-Ok 'All tools installed and authenticated.'
}
Write-Host "`nNext: open this repo (or any project) in VS Code and run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
