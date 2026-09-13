#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-time client-side setup for using this repo's devcontainer templates
  and their published ghcr.io images. Safe to re-run.

.DESCRIPTION
  Verifies/installs Git, GitHub CLI, VS Code, the VS Code Dev Containers and
  Remote-WSL extensions, and Docker Engine running inside WSL (never Docker
  Desktop). Then authenticates `gh` with the `read:packages` scope and logs
  Docker in to ghcr.io so the private
  ghcr.io/wesleycamargo/devcontainer-template/* packages can be pulled.

  Windows: installs missing tools via winget; installs Docker Engine inside
  your default WSL distro.
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
        'windows'  # Windows PowerShell 5.1 has no $IsWindows; it only runs on Windows
    } elseif ($IsWindows) {
        'windows'
    } else {
        'linux'
    }

$manualInstallNeeded = New-Object System.Collections.Generic.List[string]

function Install-Tool {
    param(
        [string]$Name,
        [string]$Command,
        [string]$WingetId,
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
        'linux' {
            Write-Warn2 "$Name not found. $LinuxHint"
            $manualInstallNeeded.Add($Name)
        }
    }
}

function Get-WslDistro {
    if (-not (Test-Command 'wsl')) { return $null }
    $names = @((wsl -l -q 2>$null) -replace "`0", '' | Where-Object { $_.Trim() -ne '' })
    if ($names.Count -gt 0) { return $names[0].Trim() }
    return $null
}

function Test-DockerInWsl([string]$Distro) {
    if (-not $Distro) { return $false }
    wsl -d $Distro -- bash -lc "command -v docker" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Install-DockerOnWsl {
    Write-Step 'Docker Engine (inside WSL — not Docker Desktop)'
    if (-not (Test-Command 'wsl')) {
        Write-Warn2 'WSL not found. Run `wsl --install`, reboot, then re-run this script.'
        $manualInstallNeeded.Add('WSL + Docker')
        return
    }
    $distro = Get-WslDistro
    if (-not $distro) {
        Write-Warn2 'No WSL distro found. Run `wsl --install -d Ubuntu`, reboot, then re-run this script.'
        $manualInstallNeeded.Add('WSL distro + Docker')
        return
    }
    if (Test-DockerInWsl $distro) {
        Write-Ok "Docker already installed in WSL distro '$distro'"
    } else {
        Write-Host "    installing Docker Engine in WSL distro '$distro'..."
        $installScript = @'
set -e
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
'@
        wsl -d $distro -- bash -c $installScript
    }

    $hasSystemd = wsl -d $distro -- bash -lc "grep -qx 'systemd=true' /etc/wsl.conf 2>/dev/null && echo yes || echo no"
    if ($hasSystemd -notmatch 'yes') {
        wsl -d $distro -- bash -c "printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf > /dev/null"
        Write-Warn2 "Enabled systemd in WSL distro '$distro' so Docker starts automatically. Run 'wsl --shutdown' yourself, then reopen a WSL terminal for it to take effect."
    } else {
        wsl -d $distro -- bash -lc "sudo service docker start" *> $null
    }
}

function Test-DockerAvailable {
    if ($OS -eq 'windows') { return (Test-DockerInWsl (Get-WslDistro)) }
    return (Test-Command 'docker')
}

Install-Tool -Name 'Git' -Command 'git' -WingetId 'Git.Git' `
    -LinuxHint 'Install via your distro package manager, e.g. `sudo apt install git`.'

Install-Tool -Name 'GitHub CLI' -Command 'gh' -WingetId 'GitHub.cli' `
    -LinuxHint 'See https://github.com/cli/cli/blob/trunk/docs/install_linux.md'

if ($OS -eq 'windows') {
    Install-DockerOnWsl
} else {
    Install-Tool -Name 'Docker' -Command 'docker' -WingetId 'n/a' `
        -LinuxHint 'See https://docs.docker.com/engine/install/'
}

Install-Tool -Name 'Visual Studio Code' -Command 'code' -WingetId 'Microsoft.VisualStudioCode' `
    -LinuxHint 'See https://code.visualstudio.com/docs/setup/linux'

Write-Step 'VS Code extensions (Dev Containers, Remote-WSL)'
if (Test-Command 'code') {
    $extensions = code --list-extensions 2>$null
    foreach ($ext in @('ms-vscode-remote.remote-containers', 'ms-vscode-remote.remote-wsl')) {
        if ($extensions -contains $ext) {
            Write-Ok "$ext already installed"
        } else {
            code --install-extension $ext
        }
    }
} else {
    Write-Warn2 'VS Code CLI (code) not on PATH yet; install the Dev Containers and Remote-WSL extensions after restarting your terminal, or manually from the Marketplace.'
    $manualInstallNeeded.Add('Dev Containers / Remote-WSL extensions')
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
} elseif (-not (Test-DockerAvailable)) {
    Write-Warn2 'docker unavailable; skipping ghcr.io login'
} else {
    $ghcrUser = (gh api user -q .login 2>$null)
    if (-not $ghcrUser) {
        Write-Warn2 'Not logged in to gh; skipping ghcr.io login'
    } elseif ($OS -eq 'windows') {
        gh auth token | wsl -d (Get-WslDistro) -- docker login ghcr.io -u $ghcrUser --password-stdin
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
if ($OS -eq 'windows') {
    Write-Host "`nNext: open this repo from inside WSL (e.g. run 'wsl' then 'code .' from the repo's WSL path, or use 'Remote-WSL: Reopen Folder in WSL' from the command palette) so VS Code's Dev Containers extension talks to the Docker daemon running in WSL. Then run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
} else {
    Write-Host "`nNext: open this repo (or any project) in VS Code and run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
}
