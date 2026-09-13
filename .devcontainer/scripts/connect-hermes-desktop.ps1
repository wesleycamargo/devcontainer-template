#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Wires Hermes Desktop (running on this Windows machine) to this project's
  devcontainer SSH gateway. Safe to re-run.

.DESCRIPTION
  Reads the real host/port/user from `hermes-ssh-info` inside the running
  devcontainer (Docker runs in WSL for this template), then updates
  ~/.ssh/config (a Host block keyed by alias) and Hermes'
  config.yaml (terminal.backend / terminal.cwd) and .env
  (TERMINAL_SSH_HOST/USER/PORT) to match. Existing files are backed up
  alongside themselves before being edited. Finishes with a live SSH check.

  NOTE: Hermes Desktop has been observed resetting terminal.cwd back to '.'
  on its own startup, demoting whatever this script wrote to a comment. If
  your terminal actions still land in the SSH login's home directory after
  running this script, set the working directory from Hermes Desktop's own
  Settings -> Terminal/SSH Backend UI instead -- that write sticks.

  Requires the devcontainer to already be up (`docker compose ... up -d` /
  VS Code "Reopen in Container").

.PARAMETER ProjectPath
  Root of the project containing `.devcontainer/docker-compose.yml`.
  Defaults to two levels up from this script's folder
  (<project>/.devcontainer/scripts/).

.PARAMETER HermesHome
  Hermes Desktop's config directory. Defaults to `$env:HERMES_HOME` when set
  (Hermes itself respects this override), otherwise `$env:USERPROFILE\.hermes`.

.PARAMETER SshConfigPath
  Path to the Windows OpenSSH client config to update. Defaults to
  `$env:USERPROFILE\.ssh\config`.

.PARAMETER IdentityFile
  Path to a private key to set as TERMINAL_SSH_KEY and, in ~/.ssh/config, as
  IdentityFile on the managed Host block. Only needed when SSH would not
  offer the right key by default.

.PARAMETER SkipConnectionTest
  Skip the final `ssh ... "echo $SHELL"` check.
#>

param(
    [string]$ProjectPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')),
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:USERPROFILE '.hermes' }),
    [string]$SshConfigPath = (Join-Path $env:USERPROFILE '.ssh\config'),
    [string]$IdentityFile,
    [switch]$SkipConnectionTest
)

$ErrorActionPreference = 'Stop'

function Write-Step ([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   ([string]$Message) { Write-Host "    ok: $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message) { Write-Host "    ! $Message" -ForegroundColor Yellow }

function Get-WslDistro {
    $names = @((wsl -l -q 2>$null) -replace "`0", '' | Where-Object { $_.Trim() -ne '' })
    if ($names.Count -gt 0) { return $names[0].Trim() }
    return $null
}

function ConvertTo-WslPath([string]$WindowsPath) {
    $resolved = (Resolve-Path $WindowsPath).ProviderPath
    $drive = $resolved.Substring(0, 1).ToLower()
    $rest = $resolved.Substring(2) -replace '\\', '/'
    return "/mnt/$drive$rest"
}

function Backup-IfExists([string]$Path) {
    if (Test-Path $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item $Path "$Path.bak-$stamp"
        Write-Ok "backed up $(Split-Path -Leaf $Path) -> $(Split-Path -Leaf $Path).bak-$stamp"
    }
}

function Set-SshConfigHost {
    param(
        [string]$Path,
        [string]$Alias,
        [string]$HostName,
        [string]$Port,
        [string]$User,
        [string]$IdentityFile
    )

    $sshDir = Split-Path -Parent $Path
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $lines = if (Test-Path $Path) { @(Get-Content $Path) } else { @() }
    Backup-IfExists $Path

    $beginMarker = "# BEGIN hermes-devcontainer $Alias"
    $endMarker = "# END hermes-devcontainer $Alias"

    $block = [System.Collections.Generic.List[string]]::new()
    $block.Add($beginMarker)
    $block.Add("Host $Alias")
    $block.Add("    HostName $HostName")
    $block.Add("    Port $Port")
    $block.Add("    User $User")
    $block.Add("    StrictHostKeyChecking accept-new")
    if ($IdentityFile) { $block.Add("    IdentityFile $IdentityFile") }
    $block.Add($endMarker)

    $startIdx = ($lines | Select-String -SimpleMatch $beginMarker).LineNumber
    if ($startIdx) {
        $start = $startIdx - 1  # 1-based match -> 0-based index
        $endIdx = ($lines | Select-String -SimpleMatch $endMarker).LineNumber
        $end = $endIdx - 1

        $newLines = @()
        if ($start -gt 0) { $newLines += $lines[0..($start - 1)] }
        $newLines += $block
        if ($end + 1 -lt $lines.Count) { $newLines += $lines[($end + 1)..($lines.Count - 1)] }
    } else {
        $newLines = $lines
        if ($newLines.Count -gt 0 -and $newLines[-1].Trim() -ne '') { $newLines += '' }
        $newLines += $block
    }

    Set-Content -Path $Path -Value $newLines
}

Write-Step 'Hermes config directory'
if ($env:HERMES_HOME) {
    Write-Ok "using `$env:HERMES_HOME override: $HermesHome"
} else {
    Write-Ok "using default: $HermesHome (set `$env:HERMES_HOME to override)"
}

# --- 1. Get connection details from the running container -----------------

Write-Step 'Reading connection details from the devcontainer'

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw 'wsl not found. This template runs Docker inside WSL; install/enable WSL first.'
}
$distro = Get-WslDistro
if (-not $distro) { throw 'No WSL distro found.' }

$wslProjectPath = ConvertTo-WslPath $ProjectPath

# find-devcontainer.sh looks the container up by its Compose working-dir
# label instead of running `docker compose exec`: a bare
# `docker compose -f ... exec` resolves its own default project name from
# the compose file's directory, which does NOT match the project name VS
# Code's "Reopen in Container" / `devcontainer up` assign (e.g.
# `devcontainer-template_devcontainer`), so it always reports "service is
# not running" against a container started that way even while it's up.
$lookupScript = "$wslProjectPath/.devcontainer/scripts/find-devcontainer.sh"
$remoteCommand = "bash '$lookupScript' '$wslProjectPath' hermes-ssh-info"
$info = wsl -d $distro -- bash -lc $remoteCommand 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host $info
    throw 'hermes-ssh-info failed. Is the devcontainer running (docker compose up -d / Reopen in Container / devcontainer up)?'
}

function Get-InfoField([string]$Pattern) {
    $m = [regex]::Match($info, $Pattern)
    if (-not $m.Success) { throw "Could not parse '$Pattern' from hermes-ssh-info output:`n$info" }
    return $m.Groups[1].Value.Trim()
}

$sshHost = Get-InfoField 'TERMINAL_SSH_HOST=(\S+)'
$sshUser = Get-InfoField 'TERMINAL_SSH_USER=(\S+)'
$sshPort = Get-InfoField 'TERMINAL_SSH_PORT=(\S+)'
$cwd     = Get-InfoField 'terminal\.cwd:\s*(\S+)'
$alias   = Get-InfoField 'Alias\s+(\S+)'

Write-Ok "host=$sshHost port=$sshPort user=$sshUser cwd=$cwd alias=$alias"

# --- 2. Update ~/.ssh/config (Host block keyed by alias) -------------------

Write-Step 'Updating ~/.ssh/config'

Set-SshConfigHost -Path $SshConfigPath -Alias $alias -HostName $sshHost -Port $sshPort -User $sshUser -IdentityFile $IdentityFile
Write-Ok "wrote $SshConfigPath (Host $alias)"

# --- 3. Update config.yaml (terminal.backend / terminal.cwd) ---------------

Write-Step 'Updating Hermes config.yaml'

$configPath = Join-Path $HermesHome 'config.yaml'
if (-not (Test-Path $HermesHome)) {
    New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null
}

$lines = if (Test-Path $configPath) { Get-Content $configPath } else { @() }
Backup-IfExists $configPath

$terminalIdx = ($lines | Select-String -Pattern '^terminal:\s*$').LineNumber
if ($terminalIdx) {
    $start = $terminalIdx  # 1-based match line -> 0-based index of next line
    $end = $start
    while ($end -lt $lines.Count -and ($lines[$end] -match '^\s+\S' -or $lines[$end] -match '^\s*$')) { $end++ }

    $block = [System.Collections.Generic.List[string]]::new()
    $sawBackend = $false; $sawCwd = $false
    for ($i = $start; $i -lt $end; $i++) {
        if ($lines[$i] -match '^\s*backend:') { $block.Add("  backend: ssh"); $sawBackend = $true }
        elseif ($lines[$i] -match '^\s*cwd:') { $block.Add("  cwd: $cwd"); $sawCwd = $true }
        else { $block.Add($lines[$i]) }
    }
    if (-not $sawBackend) { $block.Insert(0, "  backend: ssh") }
    if (-not $sawCwd) { $block.Insert(1, "  cwd: $cwd") }

    $newLines = @($lines[0..($start - 1)]) + $block + @($lines[$end..($lines.Count - 1)])
} else {
    $newLines = $lines + @('', 'terminal:', '  backend: ssh', "  cwd: $cwd")
}

Set-Content -Path $configPath -Value $newLines
Write-Ok "wrote $configPath"
Write-Warn2 "Hermes Desktop's own Settings UI can silently reset terminal.cwd back to '.' on next launch (it demotes this script's value to a comment rather than keeping it). If that happens, set the working directory to '$cwd' from Settings -> Terminal/SSH Backend in the app instead of re-running this script."

# --- 4. Update .env (TERMINAL_SSH_HOST/USER/PORT[/KEY]) --------------------

Write-Step 'Updating Hermes .env'

$envPath = Join-Path $HermesHome '.env'
$envLines = [System.Collections.Generic.List[string]]::new()
if (Test-Path $envPath) {
    $existing = Get-Content $envPath
    if ($existing) { $envLines.AddRange([string[]]@($existing)) }
}
Backup-IfExists $envPath

$values = [ordered]@{
    TERMINAL_SSH_HOST = $sshHost
    TERMINAL_SSH_USER = $sshUser
    TERMINAL_SSH_PORT = $sshPort
}
if ($IdentityFile) { $values['TERMINAL_SSH_KEY'] = $IdentityFile }

foreach ($key in $values.Keys) {
    $value = $values[$key]
    $idx = $null
    for ($i = 0; $i -lt $envLines.Count; $i++) {
        if ($envLines[$i] -match "^$key=") { $idx = $i; break }
    }
    if ($null -ne $idx) {
        $envLines[$idx] = "$key=$value"
    } else {
        $envLines.Add("$key=$value")
    }
}

Set-Content -Path $envPath -Value $envLines
Write-Ok "wrote $envPath"

# --- 5. Verify -------------------------------------------------------------

if (-not $SkipConnectionTest) {
    Write-Step 'Testing the SSH connection'
    $result = ssh -p $sshPort -o BatchMode=yes -o ConnectTimeout=5 "$sshUser@$sshHost" 'echo $SHELL' 2>&1
    if ($LASTEXITCODE -eq 0 -and $result -match '/bin/bash') {
        Write-Ok "connected, remote shell is $result"
    } else {
        Write-Warn2 "connection check failed: $result"
        Write-Warn2 'Two common causes:'
        Write-Warn2 '  1. Your public key is not in ~/.ssh on the machine running Docker (WSL), or the container has not restarted since you added it.'
        Write-Warn2 '  2. Your private key needs a passphrase, which non-interactive (BatchMode) SSH -- what Hermes Desktop uses -- cannot supply. Load it into the ssh-agent service:'
        Write-Warn2 '       Get-Service ssh-agent | Set-Service -StartupType Automatic   # run as Administrator, once'
        Write-Warn2 '       Start-Service ssh-agent                                      # run as Administrator, once'
        Write-Warn2 "       ssh-add `"$(if ($IdentityFile) { $IdentityFile } else { '<path to your private key>' })`""
    }
}

Write-Step 'Summary'
Write-Ok "~/.ssh/config, and Hermes config.yaml/.env at $HermesHome, now point at $alias ($sshHost`:$sshPort)."
Write-Host "`nRestart Hermes Desktop to pick up the change."
