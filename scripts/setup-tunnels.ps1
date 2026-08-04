# setup-tunnels.ps1
# One-time (elevated) preparation so the Big Picture app can switch between
# AmneziaWG tunnels without ever raising a UAC prompt.
#
# By default this is NON-DESTRUCTIVE: it only configures tunnels that already
# have a service (start type + access rights) and reports configs that have no
# service yet. Creating a service is opt-in via -Activate, because a config
# that fails to connect makes AmneziaWG delete the service again -- and while
# a broken tunnel is starting it can fight the working one for 0.0.0.0/0.
#
# Usage:
#   setup-tunnels.ps1                          configure existing tunnels
#   setup-tunnels.ps1 -Activate 'MyConfig'     also create a service for MyConfig
#   setup-tunnels.ps1 -Revoke                  restore original descriptors
#
# Idempotent. ASCII-only: PowerShell 5.1 reads .ps1 as ANSI without a BOM.

[CmdletBinding()]
param(
    # Config names (without .conf/.conf.dpapi) to create a service for.
    [string[]]$Activate = @(),

    # Tunnel that keeps Automatic start, so VPN is up even before the app runs.
    [string]$AutoTunnel = '-PC',

    # SID to grant access to. Defaults to the user running the script;
    # under UAC elevation that is still the same account.
    [string]$UserSid,

    # Restore the security descriptors and start types saved on the first run.
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'

$ExePath   = 'C:\Program Files\AmneziaWG\amneziawg.exe'
$ConfigDir = 'C:\Program Files\AmneziaWG\Data\Configurations'
$BackupDir = Join-Path $PSScriptRoot 'backup'
$LogPath   = Join-Path $PSScriptRoot 'setup-output.txt'

# RP = SERVICE_START, WP = SERVICE_STOP, LC = SERVICE_QUERY_STATUS, RC = READ_CONTROL
$GrantMask = 'RPWPLCRC'

Set-Content -Path $LogPath -Value '' -Encoding ASCII
function Info([string]$m) { Write-Host $m; Add-Content -Path $LogPath -Value $m -Encoding ASCII }
function Fail([string]$m) { Info "FAIL: $m"; exit 1 }

# Service names contain '$' and config names may start with '-'.
function Backup-PathFor([string]$serviceName) {
    $safe = $serviceName -replace '[^A-Za-z0-9_.-]','_'
    return Join-Path $BackupDir "$safe.json"
}

# Strip our own ACE so a backup taken after a previous run still represents
# the original descriptor.
function Remove-OurAce([string]$sddl, [string]$sid) {
    return ($sddl -replace ('\(A;;[A-Z]*;;;' + [regex]::Escape($sid) + '\)'), '')
}

function Split-Sddl([string]$sddl) {
    if ($sddl -match '^(D:.*?)(S:.*)$') { return @{ Dacl = $Matches[1]; Sacl = $Matches[2] } }
    return @{ Dacl = $sddl; Sacl = '' }
}

function Get-Sddl([string]$serviceName) {
    $s = ((& sc.exe sdshow $serviceName | Where-Object { $_.Trim() }) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $s) { throw "sdshow failed for $serviceName (exit $LASTEXITCODE)" }
    return $s
}

# Wait until the service leaves a transitional state (StartPending/StopPending).
# Checking Status too early is what let a broken tunnel slip through before.
function Wait-Settled([string]$name, [int]$timeoutSec = 25) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $s) { return 'GONE' }          # AmneziaWG removed a failed tunnel
        if ($s.Status -eq 'Running' -or $s.Status -eq 'Stopped') { return $s.Status.ToString() }
        Start-Sleep -Milliseconds 400
    }
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return 'GONE' }
    return $s.Status.ToString()
}

# --- elevation guard -------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'not elevated. Re-run as Administrator.'
}
if (-not $UserSid) { $UserSid = $id.User.Value }
if (-not (Test-Path $BackupDir)) { [void](New-Item -ItemType Directory -Path $BackupDir) }

Info "sid        : $UserSid"
Info "auto tunnel: $AutoTunnel"
if ($Activate.Count) { Info "activate   : $($Activate -join ', ')" }

# --- revoke path -----------------------------------------------------------
if ($Revoke) {
    $backups = Get-ChildItem $BackupDir -Filter '*.json' -ErrorAction SilentlyContinue
    if (-not $backups) { Fail "no backups in $BackupDir" }
    foreach ($b in $backups) {
        $data = Get-Content $b.FullName -Raw | ConvertFrom-Json
        $name = $data.ServiceName
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
            Info "skip $name (service no longer exists)"
            continue
        }
        Info "restoring $name"
        & sc.exe sdset $name $data.Sddl | Out-Null
        if ($LASTEXITCODE -ne 0) { Info "  WARN: sdset failed (exit $LASTEXITCODE)" }
        if ($data.StartMode) {
            $st = switch ($data.StartMode) {
                'Auto'     { 'Automatic' }
                'Manual'   { 'Manual' }
                'Disabled' { 'Disabled' }
                default    { $null }
            }
            if ($st) { Set-Service -Name $name -StartupType $st; Info "  start type -> $st" }
        }
        if ($data.CreatedByUs -eq $true) {
            Info "  NOTE: this service was created by setup-tunnels.ps1. To remove it:"
            Info "        `"$ExePath`" /uninstalltunnelservice $($data.TunnelName)"
        }
    }
    Info 'REVOKE DONE.'
    exit 0
}

# --- discover configs ------------------------------------------------------
if (-not (Test-Path $ExePath))   { Fail "amneziawg.exe not found at $ExePath" }
if (-not (Test-Path $ConfigDir)) { Fail "config dir not found: $ConfigDir" }

$configs = Get-ChildItem $ConfigDir -Force -File |
           Where-Object { $_.Name -match '\.conf(\.dpapi)?$' }
if (-not $configs) { Fail 'no tunnel configs found.' }

Info ''
Info '=== CONFIGS ON DISK ==='
foreach ($c in $configs) {
    $tunnel  = $c.Name -replace '\.conf(\.dpapi)?$',''
    $svcName = "AmneziaWGTunnel`$$tunnel"
    $has     = [bool](Get-Service -Name $svcName -ErrorAction SilentlyContinue)
    $mark    = if ($has) { 'service: yes' } else { 'service: NO  (use -Activate to create)' }
    Info ("  {0,-24} {1}" -f $tunnel, $mark)
}

# --- optional: create services for explicitly requested configs -------------
foreach ($tunnel in $Activate) {
    $svcName = "AmneziaWGTunnel`$$tunnel"
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        Info ''
        Info "[$tunnel] service already exists, skipping activation."
        continue
    }
    $cfg = $configs | Where-Object { ($_.Name -replace '\.conf(\.dpapi)?$','') -eq $tunnel } | Select-Object -First 1
    if (-not $cfg) { Info ''; Info "[$tunnel] WARN: no config file with this name, skipping."; continue }

    Info ''
    Info "[$tunnel] activating ..."

    # A new tunnel starts immediately and would race the running one for the
    # default route, so park the current tunnel first and restore it after.
    $running = @(Get-Service -Name 'AmneziaWGTunnel$*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Running' })
    foreach ($r in $running) {
        Info "[$tunnel] temporarily stopping $($r.Name)"
        Stop-Service -Name $r.Name
        [void](Wait-Settled $r.Name)
    }

    & $ExePath /installtunnelservice $cfg.FullName | Out-Null
    Start-Sleep -Milliseconds 800
    $state = Wait-Settled $svcName

    if ($state -eq 'GONE') {
        # AmneziaWG removes a tunnel service that cannot establish a connection.
        Info "[$tunnel] FAILED: service disappeared -- this config does not connect."
        Info "[$tunnel] fix the config in the AmneziaWG UI, then re-run with -Activate '$tunnel'."
    } else {
        Info "[$tunnel] service created (state=$state)"
        $bp = Backup-PathFor $svcName
        if (-not (Test-Path $bp)) {
            $sddl = Remove-OurAce (Get-Sddl $svcName) $UserSid
            @{ ServiceName = $svcName; TunnelName = $tunnel; Sddl = $sddl
               StartMode = 'Manual'; CreatedByUs = $true } |
                ConvertTo-Json | Set-Content -Path $bp -Encoding ASCII
        }
        if ($tunnel -ne $AutoTunnel) {
            Info "[$tunnel] stopping it -- only one tunnel may be active at a time"
            Stop-Service -Name $svcName -ErrorAction SilentlyContinue
            $after = Wait-Settled $svcName
            if ($after -eq 'GONE') {
                Info "[$tunnel] NOTE: service was removed on stop; it cannot be pre-created."
            }
        }
    }

    foreach ($r in $running) {
        if (Get-Service -Name $r.Name -ErrorAction SilentlyContinue) {
            Info "[$tunnel] restoring $($r.Name)"
            Start-Service -Name $r.Name
            [void](Wait-Settled $r.Name)
        }
    }
}

# --- start types + access rights for every existing tunnel ------------------
Info ''
Info '=== CONFIGURING SERVICES ==='
$services = @(Get-Service -Name 'AmneziaWGTunnel$*' -ErrorAction SilentlyContinue)
if (-not $services) { Fail 'no tunnel services present.' }

foreach ($s in $services) {
    $name   = $s.Name
    $tunnel = $name -replace '^AmneziaWGTunnel\$',''
    $wmi    = Get-CimInstance Win32_Service -Filter "Name='$($name -replace "'","''")'"

    $bp = Backup-PathFor $name
    if (-not (Test-Path $bp)) {
        $orig = Remove-OurAce (Get-Sddl $name) $UserSid
        @{ ServiceName = $name; TunnelName = $tunnel; Sddl = $orig
           StartMode = $wmi.StartMode; CreatedByUs = $false } |
            ConvertTo-Json | Set-Content -Path $bp -Encoding ASCII
        Info "[$tunnel] backed up to $(Split-Path $bp -Leaf)"
    }

    $want    = if ($tunnel -eq $AutoTunnel) { 'Automatic' } else { 'Manual' }
    $current = if ($wmi.StartMode -eq 'Auto') { 'Automatic' } else { $wmi.StartMode }
    if ($current -ne $want) {
        Set-Service -Name $name -StartupType $want
        Info "[$tunnel] start type: $current -> $want"
    } else {
        Info "[$tunnel] start type: $want (unchanged)"
    }

    $sddl = Get-Sddl $name
    if ($sddl -match [regex]::Escape(";;;$UserSid)")) {
        Info "[$tunnel] access: already granted"
    } else {
        $parts = Split-Sddl $sddl
        $new   = "$($parts.Dacl)(A;;$GrantMask;;;$UserSid)$($parts.Sacl)"
        & sc.exe sdset $name $new | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "[$tunnel] sdset failed (exit $LASTEXITCODE)" }
        if ((Get-Sddl $name) -match [regex]::Escape(";;;$UserSid)")) {
            Info "[$tunnel] access: GRANTED"
        } else {
            Fail "[$tunnel] ACE missing after sdset"
        }
    }
}

# --- make sure the auto tunnel is actually up ------------------------------
Info ''
$autoName = "AmneziaWGTunnel`$$AutoTunnel"
if (Get-Service -Name $autoName -ErrorAction SilentlyContinue) {
    if ((Get-Service -Name $autoName).Status -ne 'Running') {
        Info "restoring $AutoTunnel to Running ..."
        Start-Service -Name $autoName
        [void](Wait-Settled $autoName)
    }
    Info "$AutoTunnel is $((Get-Service -Name $autoName).Status)"
} else {
    Info "WARN: auto tunnel '$AutoTunnel' has no service."
}

Info ''
Info '=== FINAL STATE ==='
Get-CimInstance Win32_Service -Filter "Name LIKE 'AmneziaWGTunnel%'" | ForEach-Object {
    Info ("{0,-36} state={1,-8} start={2}" -f $_.Name, $_.State, $_.StartMode)
}
Info 'SETUP DONE.'
