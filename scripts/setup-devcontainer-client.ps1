#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-time client-side setup for using this repo's devcontainer templates
  and their published ghcr.io images. Safe to re-run.

.DESCRIPTION
  Verifies/installs Git, GitHub CLI, VS Code, the VS Code Dev Containers and
  Remote-WSL extensions, Docker Engine running inside WSL (never Docker
  Desktop), and the `devcontainer` CLI (for the `devcontainer templates
  apply` / `devcontainer up` workflow). Then authenticates `gh` with the
  `read:packages` scope and logs Docker in to ghcr.io so the private
  ghcr.io/wesleycamargo/devcontainer-template/* packages can be pulled.

  Windows: installs missing tools via winget. If WSL itself is missing it
  asks first, then installs it (one UAC prompt -- only that call is
  elevated, so the gh/Docker credentials still land in your own profile,
  not the Administrator one). WSL's first install usually needs a reboot;
  the script says so and you re-run it afterwards. If no Linux distro is
  registered it offers to install Ubuntu, whose first-run setup asks you
  to pick a UNIX username and password interactively. Docker Engine and
  the `devcontainer` CLI are then installed inside that distro; where sudo
  there needs a password, the script prompts for it once.
  Linux: checks for tools and prints install instructions for anything
  missing (package managers vary too much to automate safely here).

.PARAMETER Yes
  Answer yes to every prompt (installing WSL, installing Ubuntu). Does not
  suppress the sudo password prompt -- that needs a real answer.

.PARAMETER NonInteractive
  Never prompt. Anything that would need an answer is skipped and reported
  in the summary instead, so the script is safe to run unattended.
#>

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

function Write-Step  ([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok    ([string]$Message) { Write-Host "    ok: $Message" -ForegroundColor Green }
function Write-Warn2 ([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Confirm-Action([string]$Message) {
    if ($Yes) {
        Write-Host "    $Message [-Yes]"
        return $true
    }
    if ($NonInteractive) {
        Write-Warn2 "$Message -- skipped (-NonInteractive)"
        return $false
    }
    return ((Read-Host "    $Message [y/N]") -match '^\s*(y|yes)\s*$')
}

$OS =
    if (-not (Test-Path variable:IsWindows)) {
        'windows'  # Windows PowerShell 5.1 has no $IsWindows; it only runs on Windows
    } elseif ($IsWindows) {
        'windows'
    } else {
        'linux'
    }

if ($OS -eq 'windows') {
    # wsl.exe emits UTF-16LE by default, which turns every string this script
    # tries to match on into NUL-separated garbage. WSL 0.64+ honors this and
    # emits plain UTF-8 instead; older builds ignore it, hence the NUL
    # stripping in Get-WslOutput.
    $env:WSL_UTF8 = '1'
}

$manualInstallNeeded = New-Object System.Collections.Generic.List[string]

# Docker Desktop's internal distros. They exist to back Docker Desktop and are
# never a valid target for installing anything into.
$WslDistroDenyList = @('docker-desktop', 'docker-desktop-data')

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

function Get-WslOutput([string[]]$WslArgs) {
    # Runs wsl.exe and returns @{ Text; ExitCode } instead of letting output
    # escape to the console. $ErrorActionPreference is relaxed for the call:
    # with 'Stop' in effect, `2>&1` on a native command turns its stderr into a
    # terminating NativeCommandError, which would abort the whole script on
    # something as ordinary as "no distributions installed".
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = (& wsl.exe @WslArgs 2>&1 | Out-String)
        return @{ Text = ($raw -replace "`0", ''); ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Text = "$_"; ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function New-WslBashCommand([string]$Script) {
    # Ship the script body as base64 so it survives the Windows -> WSL command
    # line intact: no quotes, newlines or $-expansions ever reach the argument
    # PowerShell hands to wsl.exe, so there is nothing for either side to
    # mis-escape.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    return "echo $b64 | base64 -d | bash"
}

function Get-WslDistroList {
    $result = Get-WslOutput @('-l', '-q')
    if ($result.ExitCode -ne 0) { return @() }
    return @(
        $result.Text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $WslDistroDenyList -notcontains $_ }
    )
}

function Test-WslInstalled {
    # wsl.exe ships in System32 on every Windows 10 2004+ machine whether or
    # not WSL is actually installed, so its presence on PATH proves nothing.
    if (-not (Test-Command 'wsl')) { return $false }
    # The Store-distributed WSL answers --version; the inbox component answers
    # --status. Either one exiting cleanly proves WSL itself is there.
    if ((Get-WslOutput @('--version')).ExitCode -eq 0) { return $true }
    if ((Get-WslOutput @('--status')).ExitCode -eq 0) { return $true }
    # Older builds have neither flag; fall back to the driver service, which
    # only exists once the optional feature is enabled.
    return (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LxssManager')
}

function Get-WslState {
    # 'missing'   - WSL itself isn't installed
    # 'no-distro' - WSL is installed, but no usable Linux distro is registered
    # 'ready'     - at least one usable distro exists
    if (-not (Test-WslInstalled)) { return 'missing' }
    if (@(Get-WslDistroList).Count -gt 0) { return 'ready' }
    return 'no-distro'
}

function Get-WslDistro {
    # `wsl -l -v` marks the default distro with a leading '*'. Prefer it, and
    # never hand back one of Docker Desktop's internal distros.
    $result = Get-WslOutput @('-l', '-v')
    if ($result.ExitCode -eq 0) {
        $default = $null
        $first = $null
        foreach ($line in ($result.Text -split "`r?`n")) {
            if ($line -notmatch '^\s*(\*?)\s*(\S+)\s+\S+\s+\d+\s*$') { continue }
            $isDefault = ($matches[1] -eq '*')
            $name = $matches[2]
            if ($WslDistroDenyList -contains $name) { continue }
            if (-not $first) { $first = $name }
            if ($isDefault) { $default = $name }
        }
        if ($default) { return $default }
        if ($first) { return $first }
    }
    # @() matters: PowerShell unrolls a single-element array on return, so a
    # bare assignment would leave $names holding the distro name as a string
    # and $names[0] would index its first *character*.
    $names = @(Get-WslDistroList)
    if ($names.Count -gt 0) { return $names[0] }
    return $null
}

function Test-RebootPending {
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path $key) { return $true }
    }
    return $false
}

function Invoke-ElevatedWsl([string[]]$WslArgs) {
    # `wsl --install` needs administrator rights. Elevate only this one call:
    # running the whole script elevated would write the gh token and Docker
    # credentials into the Administrator profile instead of the user's.
    Write-Host "    a UAC prompt will ask to run: wsl.exe $($WslArgs -join ' ')"
    try {
        $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $WslArgs -Verb RunAs -Wait -PassThru
        return ($proc.ExitCode -eq 0)
    } catch {
        Write-Warn2 "elevation was declined or failed: $($_.Exception.Message)"
        return $false
    }
}

function Install-Wsl {
    Write-Step 'WSL (Windows Subsystem for Linux)'

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Write-Warn2 "Windows build $build is older than 19041, so WSL2 isn't available. Update Windows, then re-run this script."
        $manualInstallNeeded.Add('WSL2 (Windows update required)')
        return $false
    }

    $state = Get-WslState

    if ($state -eq 'missing') {
        if (-not (Confirm-Action 'WSL is not installed. Install it now? (needs administrator rights, and usually a reboot)')) {
            Write-Warn2 'Skipping WSL install. Run `wsl --install` from an elevated terminal, reboot, then re-run this script.'
            $manualInstallNeeded.Add('WSL')
            return $false
        }
        Write-Host '    installing WSL...'
        # --no-distribution leaves the distro choice to the next step. It is
        # unrecognized on older Windows 10 builds, where plain --install both
        # enables the features and pulls Ubuntu -- hence the retry.
        if (-not (Invoke-ElevatedWsl @('--install', '--no-distribution'))) {
            Invoke-ElevatedWsl @('--install') | Out-Null
        }
        $state = Get-WslState
        if ($state -eq 'missing') {
            if (Test-RebootPending) {
                Write-Warn2 'WSL is installed but Windows needs a reboot to finish enabling it. Reboot, then re-run this script.'
                $manualInstallNeeded.Add('WSL (reboot required)')
            } else {
                Write-Warn2 'WSL install did not complete. Run `wsl --install` from an elevated terminal, reboot, then re-run this script.'
                $manualInstallNeeded.Add('WSL')
            }
            return $false
        }
        Write-Ok 'WSL installed'
    } else {
        Write-Ok 'WSL already installed'
    }

    if ($state -eq 'no-distro') {
        if (-not (Confirm-Action 'No WSL distro is installed. Install Ubuntu now?')) {
            Write-Warn2 'Skipping distro install. Run `wsl --install -d Ubuntu`, then re-run this script.'
            $manualInstallNeeded.Add('WSL distro')
            return $false
        }
        Get-WslOutput @('--set-default-version', '2') | Out-Null
        Write-Host '    installing Ubuntu. Its first-run setup asks you to choose a UNIX username'
        Write-Host '    and password -- remember the password, this script needs it for sudo. When'
        Write-Host '    it drops you into a Linux shell, type `exit` to come back here.'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Deliberately unredirected: Ubuntu's first-run setup has to be able
            # to prompt on this console.
            & wsl.exe --install -d Ubuntu
        } finally {
            $ErrorActionPreference = $prev
        }
        if ((Get-WslState) -ne 'ready') {
            Write-Warn2 'No WSL distro registered. Run `wsl --install -d Ubuntu`, finish its first-run setup, then re-run this script.'
            $manualInstallNeeded.Add('WSL distro')
            return $false
        }
        Write-Ok 'Ubuntu installed'
    } else {
        Write-Ok "distro '$(Get-WslDistro)' available"
    }

    return $true
}

function Test-DockerInWsl([string]$Distro) {
    if (-not $Distro) { return $false }
    return ((Get-WslOutput @('-d', $Distro, '--', 'bash', '-lc', 'command -v docker')).ExitCode -eq 0)
}

function Test-PasswordlessSudo([string]$Distro) {
    if (-not $Distro) { return $false }
    # sudo -n never prompts: it fails immediately if a password would be
    # required, instead of hanging forever waiting for input this
    # non-interactive `wsl.exe` invocation can never deliver.
    return ((Get-WslOutput @('-d', $Distro, '--', 'sudo', '-n', 'true')).ExitCode -eq 0)
}

function ConvertTo-PlainText([System.Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-WslSudoStdin([string]$Distro, [System.Security.SecureString]$Secure, [string]$Command) {
    # The command rides in as a `bash -c` argument, which leaves stdin free for
    # `sudo -S` to read the password from. No `-p ''` to silence sudo's prompt:
    # Windows PowerShell 5.1 drops empty-string arguments to native commands,
    # which would silently turn the next argument into the prompt text. The
    # prompt goes to stderr, which is captured here and only shown on failure.
    $plain = ConvertTo-PlainText $Secure
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = ($plain | & wsl.exe -d $Distro -- sudo -S bash -c $Command 2>&1 | Out-String)
        return @{ Text = ($raw -replace "`0", ''); ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Text = "$_"; ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $prev
        $plain = $null
    }
}

$script:WslSudoPassword = $null

function Get-WslSudoPassword([string]$Distro) {
    if ($script:WslSudoPassword) { return $script:WslSudoPassword }
    if ($NonInteractive) { return $null }
    Write-Host "    sudo in WSL distro '$Distro' needs a password to install packages."
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $secure = Read-Host "    sudo password for '$Distro'" -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { break }
        if ((Invoke-WslSudoStdin $Distro $secure 'true').ExitCode -eq 0) {
            $script:WslSudoPassword = $secure
            return $secure
        }
        Write-Warn2 'sudo rejected that password.'
    }
    return $null
}

function Invoke-WslSudoScript([string]$Distro, [string]$Script) {
    if (-not $Distro) { return $false }
    $command = New-WslBashCommand $Script
    if (Test-PasswordlessSudo $Distro) {
        $result = Get-WslOutput @('-d', $Distro, '--', 'sudo', '-n', 'bash', '-c', $command)
    } else {
        $secure = Get-WslSudoPassword $Distro
        if (-not $secure) { return $false }
        $result = Invoke-WslSudoStdin $Distro $secure $command
    }
    if ($result.ExitCode -ne 0) {
        $text = $result.Text.Trim()
        if ($text) { Write-Host $text }
        return $false
    }
    return $true
}

function Install-DockerOnWsl([string]$Distro) {
    Write-Step 'Docker Engine (inside WSL -- not Docker Desktop)'
    if (Test-DockerInWsl $Distro) {
        Write-Ok "Docker already installed in WSL distro '$Distro'"
    } else {
        Write-Host "    installing Docker Engine in WSL distro '$Distro'..."
        $installScript = @'
set -e
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "${SUDO_USER:-$(id -un)}"
'@
        if (-not (Invoke-WslSudoScript $Distro $installScript)) {
            Write-Warn2 "Docker install failed in WSL distro '$Distro'. Open a WSL terminal (``wsl -d $Distro``) and follow https://docs.docker.com/engine/install/ubuntu/, then re-run this script."
            $manualInstallNeeded.Add('Docker Engine in WSL')
            return
        }
    }

    # Deliberately does NOT enable `systemd=true` in /etc/wsl.conf: on some
    # WSL/distro combinations that leaves nss-systemd intercepting every user
    # lookup while systemd-userdbd never comes up, so getpwuid() fails for
    # every uid -- including root -- and NO process can be launched in that
    # distro any more, not even a shell to fix it. Just start the service for
    # this session instead; re-run this script (or `sudo service docker
    # start`) after every `wsl --shutdown` / reboot.
    Invoke-WslSudoScript $Distro 'service docker start' | Out-Null
}

function Test-DevcontainerCliInWsl([string]$Distro) {
    if (-not $Distro) { return $false }
    return ((Get-WslOutput @('-d', $Distro, '--', 'bash', '-lc', 'command -v devcontainer')).ExitCode -eq 0)
}

function Install-DevcontainerCliOnWsl([string]$Distro) {
    Write-Step 'devcontainer CLI (inside WSL)'
    if (Test-DevcontainerCliInWsl $Distro) {
        Write-Ok "devcontainer CLI already installed in WSL distro '$Distro'"
        return
    }
    Write-Host "    installing Node.js + @devcontainers/cli in WSL distro '$Distro'..."
    $installScript = @'
set -e
command -v npm >/dev/null 2>&1 || { apt-get update -y; apt-get install -y nodejs npm; }
npm install -g @devcontainers/cli
'@
    if (-not (Invoke-WslSudoScript $Distro $installScript)) {
        Write-Warn2 "devcontainer CLI install failed in WSL distro '$Distro'. Open a WSL terminal (``wsl -d $Distro``) and run: sudo apt-get install -y nodejs npm && sudo npm install -g @devcontainers/cli"
        $manualInstallNeeded.Add('devcontainer CLI in WSL')
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
        Get-WslOutput @('-d', $Distro, '--', 'bash', '-c', (New-WslBashCommand $fixScript)) | Out-Null
    } else {
        bash -c $fixScript *> $null
    }
}

Install-Tool -Name 'Git' -Command 'git' -WingetId 'Git.Git' `
    -LinuxHint 'Install via your distro package manager, e.g. `sudo apt install git`.'

Install-Tool -Name 'GitHub CLI' -Command 'gh' -WingetId 'GitHub.cli' `
    -LinuxHint 'See https://github.com/cli/cli/blob/trunk/docs/install_linux.md'

if ($OS -eq 'windows') {
    if (Install-Wsl) {
        $wslDistro = Get-WslDistro
        Install-DockerOnWsl $wslDistro
        Install-DevcontainerCliOnWsl $wslDistro
    } else {
        Write-Warn2 'No usable WSL distro; skipping the Docker Engine and devcontainer CLI installs.'
        $manualInstallNeeded.Add('Docker Engine in WSL')
        $manualInstallNeeded.Add('devcontainer CLI in WSL')
    }
} else {
    Install-Tool -Name 'Docker' -Command 'docker' -WingetId 'n/a' `
        -LinuxHint 'See https://docs.docker.com/engine/install/'

    Write-Step 'devcontainer CLI'
    if (Test-Command 'devcontainer') {
        Write-Ok 'devcontainer CLI already installed'
    } elseif (Test-Command 'npm') {
        npm install -g @devcontainers/cli
    } else {
        Write-Warn2 'npm not found. Install Node.js, then `npm install -g @devcontainers/cli`.'
        $manualInstallNeeded.Add('devcontainer CLI')
    }
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
        if ($NonInteractive) {
            Write-Warn2 'gh is not authenticated and -NonInteractive was passed; skipping login.'
            $manualInstallNeeded.Add('gh auth login --scopes read:packages')
        } else {
            Write-Host '    logging in to GitHub...'
            gh auth login --hostname github.com --git-protocol https --web --scopes 'read:packages'
        }
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
    Write-Host "`nDocker's service isn't enabled at WSL boot (see the comment in Install-DockerOnWsl for why); re-run this script after every 'wsl --shutdown' or reboot to start it again, or run 'sudo service docker start' yourself inside WSL."
    Write-Host "`nNext: open this repo from inside WSL (e.g. run 'wsl' then 'code .' from the repo's WSL path, or use 'Remote-WSL: Reopen Folder in WSL' from the command palette) so VS Code's Dev Containers extension talks to the Docker daemon running in WSL. Then run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
} else {
    Write-Host "`nNext: open this repo (or any project) in VS Code and run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
}
