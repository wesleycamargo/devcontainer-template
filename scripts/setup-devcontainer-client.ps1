#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-time client-side setup for using this repo's devcontainer templates
  and their published ghcr.io images. Safe to re-run.

.DESCRIPTION
  Verifies/installs Git, GitHub CLI, Docker Engine and the `devcontainer`
  CLI inside the *target* -- WSL on Windows (never Docker Desktop), or the
  local machine on Linux -- plus VS Code and its Dev Containers/Remote-WSL
  extensions on the host. Generates an ed25519 SSH key in the target if it
  doesn't have one yet (the key SSH-BACKEND.md's Hermes gateway authorizes
  has to live in `~/.ssh` of the machine that starts the container, i.e.
  the target). On Windows, also copies the Windows user's own SSH public
  key(s) into the target under a `windows-` prefix, since Hermes Desktop
  authenticates with that key, not the target's. Then authenticates `gh`
  with the `read:packages` scope and logs Docker in to ghcr.io, both inside
  the target, so the private ghcr.io/wesleycamargo/devcontainer-template/*
  packages can be pulled.

  Windows: WSL is checked and installed FIRST, before anything else --
  every other tool lives inside it, so nothing downstream can proceed
  without it. If WSL itself is missing the script asks first, then installs
  it (one UAC prompt -- only that call is elevated, so the gh/Docker
  credentials still land in your own WSL user, not the Windows
  Administrator profile). WSL's first install usually needs a reboot; the
  script says so and you re-run it afterwards. If no Linux distro is
  registered it offers to install Ubuntu, whose first-run setup asks you to
  pick a UNIX username and password interactively. Git, GitHub CLI, Docker
  Engine and the devcontainer CLI are then all installed inside that
  distro via apt; where sudo there needs a password, the script prompts
  for it once. `gh auth login` also runs inside the distro -- it prints a
  one-time code and a URL to open in a browser yourself (WSL has no way to
  launch your Windows browser automatically).
  Linux: the local machine as the target. Same apt-based installers run
  directly when `apt-get` is present; otherwise the script prints install
  instructions for anything missing (package managers vary too much to
  automate safely beyond apt).

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

# The environment everything below installs into and authenticates: a WSL
# distro on Windows, or $null meaning "the local machine" on Linux. Set once
# WSL is confirmed ready, in the main flow below.
$script:TargetDistro = $null

function Get-TargetLabel {
    if ($script:TargetDistro) { return "WSL distro '$($script:TargetDistro)'" }
    return 'this machine'
}

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

function New-TargetBashCommand([string]$Script) {
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

function Invoke-TargetRaw([string[]]$CommandArgs) {
    # The one primitive everything else in the target abstraction is built on:
    # runs an argv either inside the WSL distro or on the local machine, and
    # always returns @{ Text; ExitCode } instead of letting output or a
    # non-zero exit escape -- the same contract Get-WslOutput already offers
    # for the WSL side.
    if ($script:TargetDistro) {
        return Get-WslOutput (@('-d', $script:TargetDistro, '--') + $CommandArgs)
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $exe = $CommandArgs[0]
        $rest = @()
        if ($CommandArgs.Count -gt 1) { $rest = $CommandArgs[1..($CommandArgs.Count - 1)] }
        $raw = (& $exe @rest 2>&1 | Out-String)
        return @{ Text = $raw; ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Text = "$_"; ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-TargetCommand([string]$Command) {
    # A shell command string (may use pipes/quotes/$-expansions), run as a
    # login shell in the target so PATH matches what Test-TargetCommand sees.
    return (Invoke-TargetRaw @('bash', '-lc', $Command))
}

function Test-TargetCommand([string]$Name) {
    return ((Invoke-TargetCommand "command -v $Name").ExitCode -eq 0)
}

function Test-TargetIsRoot {
    return ((Invoke-TargetCommand '[ "$(id -u)" = "0" ]').ExitCode -eq 0)
}

function Invoke-TargetInteractive([string[]]$CommandArgs) {
    # Deliberately unredirected: an interactive gh device-code prompt, or its
    # browser-launch-failed fallback message, has to reach this console
    # directly -- the same shape as the unredirected `wsl --install -d
    # Ubuntu` call in Install-Wsl. Returns the exit code only.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        if ($script:TargetDistro) {
            & wsl.exe -d $script:TargetDistro -- @CommandArgs
        } else {
            $exe = $CommandArgs[0]
            $rest = @()
            if ($CommandArgs.Count -gt 1) { $rest = $CommandArgs[1..($CommandArgs.Count - 1)] }
            & $exe @rest
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-TargetPasswordlessSudo {
    # sudo -n never prompts: it fails immediately if a password would be
    # required, instead of hanging forever waiting for input this
    # non-interactive invocation can never deliver.
    return ((Invoke-TargetRaw @('sudo', '-n', 'true')).ExitCode -eq 0)
}

function ConvertTo-PlainText([System.Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-TargetSudoStdin([System.Security.SecureString]$Secure, [string]$Command) {
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
        if ($script:TargetDistro) {
            $raw = ($plain | & wsl.exe -d $script:TargetDistro -- sudo -S bash -c $Command 2>&1 | Out-String)
        } else {
            $raw = ($plain | & sudo -S bash -c $Command 2>&1 | Out-String)
        }
        return @{ Text = ($raw -replace "`0", ''); ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Text = "$_"; ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $prev
        $plain = $null
    }
}

$script:TargetSudoPassword = $null

function Get-TargetSudoPassword {
    if ($script:TargetSudoPassword) { return $script:TargetSudoPassword }
    if ($NonInteractive) { return $null }
    Write-Host "    sudo in $(Get-TargetLabel) needs a password to install packages."
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $secure = Read-Host "    sudo password for $(Get-TargetLabel)" -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { break }
        if ((Invoke-TargetSudoStdin $secure 'true').ExitCode -eq 0) {
            $script:TargetSudoPassword = $secure
            return $secure
        }
        Write-Warn2 'sudo rejected that password.'
    }
    return $null
}

function Invoke-TargetSudoScript([string]$Script) {
    $command = New-TargetBashCommand $Script
    if (Test-TargetIsRoot) {
        $result = Invoke-TargetRaw @('bash', '-c', $command)
    } elseif (Test-TargetPasswordlessSudo) {
        $result = Invoke-TargetRaw @('sudo', '-n', 'bash', '-c', $command)
    } else {
        $secure = Get-TargetSudoPassword
        if (-not $secure) { return $false }
        $result = Invoke-TargetSudoStdin $secure $command
    }
    if ($result.ExitCode -ne 0) {
        $text = $result.Text.Trim()
        if ($text) { Write-Host $text }
        return $false
    }
    return $true
}

function Install-TargetGit {
    Write-Step "Git (in $(Get-TargetLabel))"
    if (Test-TargetCommand 'git') {
        Write-Ok "Git already installed in $(Get-TargetLabel)"
        return
    }
    if (-not (Test-TargetCommand 'apt-get')) {
        Write-Warn2 "apt-get not found in $(Get-TargetLabel). Install Git via its package manager, e.g. ``sudo apt install git``."
        $manualInstallNeeded.Add('Git')
        return
    }
    Write-Host "    installing Git in $(Get-TargetLabel)..."
    $installScript = @'
set -e
apt-get update -y
apt-get install -y git
'@
    if (-not (Invoke-TargetSudoScript $installScript)) {
        Write-Warn2 "Git install failed in $(Get-TargetLabel). Install it manually, e.g. ``sudo apt install git``, then re-run this script."
        $manualInstallNeeded.Add('Git')
    }
}

function Install-TargetGh {
    Write-Step "GitHub CLI (in $(Get-TargetLabel))"
    if (Test-TargetCommand 'gh') {
        Write-Ok "GitHub CLI already installed in $(Get-TargetLabel)"
        return
    }
    if (-not (Test-TargetCommand 'apt-get')) {
        Write-Warn2 "apt-get not found in $(Get-TargetLabel). See https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
        $manualInstallNeeded.Add('GitHub CLI')
        return
    }
    Write-Host "    installing GitHub CLI in $(Get-TargetLabel)..."
    $installScript = @'
set -e
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update -y
apt-get install -y gh
'@
    if (-not (Invoke-TargetSudoScript $installScript)) {
        Write-Warn2 "GitHub CLI install failed in $(Get-TargetLabel). See https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
        $manualInstallNeeded.Add('GitHub CLI')
    }
}

function Install-TargetDocker {
    Write-Step "Docker Engine (in $(Get-TargetLabel) -- not Docker Desktop)"
    if (Test-TargetCommand 'docker') {
        Write-Ok "Docker already installed in $(Get-TargetLabel)"
    } else {
        if (-not (Test-TargetCommand 'apt-get')) {
            Write-Warn2 "apt-get not found in $(Get-TargetLabel). See https://docs.docker.com/engine/install/"
            $manualInstallNeeded.Add('Docker Engine')
            return
        }
        Write-Host "    installing Docker Engine in $(Get-TargetLabel)..."
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
        if (-not (Invoke-TargetSudoScript $installScript)) {
            Write-Warn2 "Docker install failed in $(Get-TargetLabel). Follow https://docs.docker.com/engine/install/ubuntu/, then re-run this script."
            $manualInstallNeeded.Add('Docker Engine')
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
    Invoke-TargetSudoScript 'service docker start' | Out-Null
}

function Install-TargetDevcontainerCli {
    Write-Step "devcontainer CLI (in $(Get-TargetLabel))"
    if (Test-TargetCommand 'devcontainer') {
        Write-Ok "devcontainer CLI already installed in $(Get-TargetLabel)"
        return
    }
    if (-not (Test-TargetCommand 'npm') -and -not (Test-TargetCommand 'apt-get')) {
        Write-Warn2 "Neither npm nor apt-get found in $(Get-TargetLabel). Install Node.js, then ``npm install -g @devcontainers/cli``."
        $manualInstallNeeded.Add('devcontainer CLI')
        return
    }
    Write-Host "    installing Node.js + @devcontainers/cli in $(Get-TargetLabel)..."
    $installScript = @'
set -e
command -v npm >/dev/null 2>&1 || { apt-get update -y; apt-get install -y nodejs npm; }
npm install -g @devcontainers/cli
'@
    if (-not (Invoke-TargetSudoScript $installScript)) {
        Write-Warn2 "devcontainer CLI install failed in $(Get-TargetLabel). Run: sudo apt-get install -y nodejs npm && sudo npm install -g @devcontainers/cli"
        $manualInstallNeeded.Add('devcontainer CLI')
    }
}

function Initialize-TargetSshKey {
    # SSH-BACKEND.md: Hermes authorizes every `*.pub` in `~/.ssh` of the
    # machine that starts the container -- which, since everything above this
    # installs Docker and the devcontainer CLI into the target, is the target,
    # not the Windows host. No sudo: the key belongs to the target user, the
    # same one Docker/devcontainer run as.
    Write-Step "SSH key (in $(Get-TargetLabel))"
    if ((Invoke-TargetCommand 'test -f "$HOME/.ssh/id_ed25519"').ExitCode -eq 0) {
        Write-Ok "SSH key already exists in $(Get-TargetLabel)"
        return
    }
    if (-not (Test-TargetCommand 'ssh-keygen')) {
        Write-Warn2 "ssh-keygen not found in $(Get-TargetLabel). Install the OpenSSH client, then run: ssh-keygen -t ed25519"
        $manualInstallNeeded.Add('SSH key')
        return
    }
    Write-Host "    generating an ed25519 SSH key in $(Get-TargetLabel)..."
    # ssh-keygen doesn't create ~/.ssh itself -- it fails with "No such file or
    # directory" if the directory isn't already there.
    $result = Invoke-TargetCommand 'mkdir -p -m 700 "$HOME/.ssh" && ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"'
    if ($result.ExitCode -ne 0) {
        Write-Warn2 "SSH key generation failed in $(Get-TargetLabel). Run: ssh-keygen -t ed25519"
        $manualInstallNeeded.Add('SSH key')
    } else {
        Write-Ok "SSH key created in $(Get-TargetLabel)"
    }
}

function Copy-HostSshPublicKeys {
    # Windows only. SSH-BACKEND.md: "Docker in WSL, Hermes on Windows: those
    # are two different ~/.ssh folders" -- Hermes Desktop and other
    # Windows-side tools authenticate with the *Windows* user's own SSH key,
    # not the one Initialize-TargetSshKey just generated in the target. Copy
    # its public key(s) in too, under a `windows-` prefix so they can never
    # collide with the target's own, so ssh-pubkeys authorizes both.
    if ($OS -ne 'windows') { return }
    $winSshDir = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Get-ChildItem -Path $winSshDir -Filter '*.pub' -ErrorAction SilentlyContinue)) { return }

    Write-Step "Windows SSH public key(s) -> $(Get-TargetLabel)"
    $pathResult = Get-WslOutput @('-d', $script:TargetDistro, '--', 'wslpath', '-u', $winSshDir)
    if ($pathResult.ExitCode -ne 0) {
        Write-Warn2 "Could not resolve '$winSshDir' as a WSL path. Copy it in manually: cp -n /mnt/c/Users/<you>/.ssh/*.pub ~/.ssh/windows-<name>.pub"
        return
    }
    $wslSshDir = $pathResult.Text.Trim()
    $copyScript = @"
set -e
mkdir -p -m 700 "`$HOME/.ssh"
for f in "$wslSshDir"/*.pub; do
    [ -f "`$f" ] || continue
    cp -n "`$f" "`$HOME/.ssh/windows-`$(basename "`$f")"
done
"@
    $result = Invoke-TargetRaw @('bash', '-c', (New-TargetBashCommand $copyScript))
    if ($result.ExitCode -ne 0) {
        Write-Warn2 "Copying Windows SSH public key(s) into $(Get-TargetLabel) failed. Copy them in manually: cp -n '$wslSshDir'/*.pub ~/.ssh/"
    } else {
        Write-Ok "Windows SSH public key(s) copied into $(Get-TargetLabel)"
    }
}

function Repair-DockerCredsStore {
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
    Invoke-TargetRaw @('bash', '-c', (New-TargetBashCommand $fixScript)) | Out-Null
}

function Connect-GitHubAuth {
    Write-Step "GitHub authentication (read:packages scope, in $(Get-TargetLabel))"
    if (-not (Test-TargetCommand 'gh')) {
        Write-Warn2 "gh CLI unavailable in $(Get-TargetLabel); skipping GitHub auth"
        return
    }
    $status = Invoke-TargetCommand 'gh auth status'
    if ($status.ExitCode -ne 0) {
        if ($NonInteractive) {
            Write-Warn2 "gh is not authenticated in $(Get-TargetLabel) and -NonInteractive was passed; skipping login."
            $manualInstallNeeded.Add("gh auth login --scopes read:packages (in $(Get-TargetLabel))")
        } else {
            Write-Host "    logging in to GitHub in $(Get-TargetLabel)..."
            Write-Host '    gh will print a one-time code and a URL if it cannot open a browser itself -- open that URL yourself to continue.'
            Invoke-TargetInteractive @('gh', 'auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web', '--scopes', 'read:packages') | Out-Null
        }
    } elseif ($status.Text -notmatch 'read:packages') {
        Write-Host '    refreshing token scope...'
        Invoke-TargetInteractive @('gh', 'auth', 'refresh', '-h', 'github.com', '-s', 'read:packages') | Out-Null
    } else {
        Write-Ok "gh already authenticated with read:packages in $(Get-TargetLabel)"
    }
}

function Connect-Ghcr {
    Write-Step "Docker login to ghcr.io (in $(Get-TargetLabel))"
    if (-not (Test-TargetCommand 'gh')) {
        Write-Warn2 "gh CLI unavailable in $(Get-TargetLabel); cannot obtain a token for ghcr.io login"
        return
    }
    if (-not (Test-TargetCommand 'docker')) {
        Write-Warn2 "docker unavailable in $(Get-TargetLabel); skipping ghcr.io login"
        return
    }
    if ((Invoke-TargetCommand 'gh auth status').ExitCode -ne 0) {
        Write-Warn2 "Not logged in to gh in $(Get-TargetLabel); skipping ghcr.io login"
        return
    }
    Repair-DockerCredsStore
    $result = Invoke-TargetCommand 'gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin'
    if ($result.ExitCode -ne 0) {
        Write-Warn2 "docker login failed in $(Get-TargetLabel); see output above."
        $text = $result.Text.Trim()
        if ($text) { Write-Host $text }
    } else {
        Write-Ok "docker logged in to ghcr.io in $(Get-TargetLabel)"
    }
}

# --- Main flow --------------------------------------------------------------
# WSL is checked FIRST on Windows: every other tool below installs and
# authenticates inside it, so nothing downstream can proceed without it.
if ($OS -eq 'windows') {
    $targetReady = Install-Wsl
    if ($targetReady) { $script:TargetDistro = Get-WslDistro }
} else {
    $targetReady = $true  # the target is this machine
}

if ($targetReady) {
    Install-TargetGit
    Install-TargetGh
    Install-TargetDocker
    Install-TargetDevcontainerCli
    Initialize-TargetSshKey
    Copy-HostSshPublicKeys
} else {
    Write-Warn2 'No usable WSL distro; skipping Git, GitHub CLI, Docker Engine, the devcontainer CLI and SSH key setup.'
    foreach ($tool in @('Git', 'GitHub CLI', 'Docker Engine', 'devcontainer CLI', 'SSH key')) {
        $manualInstallNeeded.Add($tool)
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

if ($targetReady) {
    Connect-GitHubAuth
    Connect-Ghcr
} else {
    Write-Warn2 'No usable target; skipping GitHub authentication and the ghcr.io login.'
}

Write-Step 'Summary'
if ($manualInstallNeeded.Count -gt 0) {
    Write-Warn2 "Install these manually, then re-run this script: $($manualInstallNeeded -join ', ')"
} else {
    Write-Ok 'All tools installed and authenticated.'
}
if ($OS -eq 'windows') {
    Write-Host "`nGit, GitHub CLI, Docker and the devcontainer CLI all live inside WSL now, not on Windows -- use them from a WSL terminal (``wsl -d $($script:TargetDistro)``)."
    Write-Host "`nDocker's service isn't enabled at WSL boot (see the comment in Install-TargetDocker for why), and a freshly-added docker group membership only takes effect in a new WSL session; run 'wsl --shutdown' once after the first install, then re-run this script (or 'sudo service docker start') after every later 'wsl --shutdown' or reboot."
    Write-Host "`nNext: open this repo from inside WSL (e.g. run 'wsl' then 'code .' from the repo's WSL path, or use 'Remote-WSL: Reopen Folder in WSL' from the command palette) so VS Code's Dev Containers extension talks to the Docker daemon running in WSL. Then run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
} else {
    Write-Host "`nNext: open this repo (or any project) in VS Code and run 'Dev Containers: Add Dev Container Configuration Files', or see README.md for the devcontainer CLI / raw devcontainer.json options."
}
