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

function Test-PasswordlessSudo([string]$Distro) {
    wsl -d $Distro -- sudo -n true *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-WslSudoScript([string]$Distro, [string]$Script) {
    # sudo -n never prompts: it fails immediately if a password would be
    # required, instead of hanging forever waiting for input this
    # non-interactive `wsl.exe` invocation can never deliver.
    wsl -d $Distro -- sudo -n bash -c $Script *> $null
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

    $canSudo = Test-PasswordlessSudo $distro
    if (-not $canSudo) {
        Write-Warn2 "sudo in WSL distro '$distro' needs a password, so it can't be automated here. Open a WSL terminal (``wsl -d $distro``) and, if 'docker' isn't already on PATH there, follow https://docs.docker.com/engine/install/ubuntu/ to install it, then re-run this script."
        $manualInstallNeeded.Add('Docker Engine in WSL (sudo password required)')
        return
    }

    if (Test-DockerInWsl $distro) {
        Write-Ok "Docker already installed in WSL distro '$distro'"
    } else {
        Write-Host "    installing Docker Engine in WSL distro '$distro'..."
        $installScript = @'
set -e
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$SUDO_USER"
'@
        if (-not (Invoke-WslSudoScript $distro $installScript)) {
            Write-Warn2 "Docker install failed in WSL distro '$distro'; see output above."
            $manualInstallNeeded.Add('Docker Engine in WSL')
            return
        }
    }

    $hasSystemd = wsl -d $distro -- bash -lc "grep -qx 'systemd=true' /etc/wsl.conf 2>/dev/null && echo yes || echo no"
    if ($hasSystemd -notmatch 'yes') {
        Invoke-WslSudoScript $distro "printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf" | Out-Null
        Write-Warn2 "Enabled systemd in WSL distro '$distro' so Docker starts automatically. Run 'wsl --shutdown' yourself, then reopen a WSL terminal for it to take effect."
    } else {
        Invoke-WslSudoScript $distro 'service docker start' | Out-Null
    }
}

function Test-DockerAvailable {
    if ($OS -eq 'windows') { return (Test-DockerInWsl (Get-WslDistro)) }
    return (Test-Command 'docker')
}

function Repair-DockerCredsStore([string]$Distro) {
    # A stale/inherited ~/.docker/config.json can point `credsStore` at a
    # credential helper (e.g. secretservice, from a desktop keyring) that
    # isn't installed in a headless WSL/Linux shell. When that helper is
    # missing, `docker login` fails to persist the token, and every later
    # pull gets a silent 401 with no obvious cause. Drop the reference so
    # docker falls back to storing the token directly in config.json.
    $fixScript = @'
set -e
CONFIG="$HOME/.docker/config.json"
[ -f "$CONFIG" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
python3 - "$CONFIG" <<'PY'
import json, sys, shutil
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
store = cfg.get("credsStore")
if store and shutil.which("docker-credential-" + store) is None:
    cfg.pop("credsStore", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
PY
'@
    if ($Distro) {
        wsl -d $Distro -- bash -c $fixScript *> $null
    } else {
        bash -c $fixScript *> $null
    }
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
        $distro = Get-WslDistro
        Repair-DockerCredsStore $distro
        gh auth token | wsl -d $distro -- docker login ghcr.io -u $ghcrUser --password-stdin
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 "docker login failed in WSL distro '$distro'; see output above."
        }
    } else {
        Repair-DockerCredsStore $null
        gh auth token | docker login ghcr.io -u $ghcrUser --password-stdin
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 'docker login failed; see output above.'
        }
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
