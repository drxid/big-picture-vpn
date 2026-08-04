# tunnel-control.ps1
# Runs elevated, via a Scheduled Task, to inspect and switch AmneziaWG tunnels.
#
# Why this exists, and why it does more than start/stop:
#
#   * Granting the user rights on a tunnel service works only until AmneziaWG
#     recreates that service, which resets the descriptor.
#   * More importantly, AmneziaWG does not merely stop a tunnel when it is
#     switched off -- it DELETES the service. So when the VPN is genuinely off
#     there is nothing to start, and turning it back on means recreating the
#     service with /installtunnelservice, which needs administrator rights.
#   * The config directory is readable only by administrators, so listing what
#     tunnels exist at all has to happen here too.
#
# SECURITY. This runs with full administrator rights and is triggered by an
# ordinary user process, so it is a privilege boundary:
#
#   * It must live somewhere unprivileged users cannot write, or anyone could
#     swap it out and get arbitrary code as admin. setup-scheduled-task.ps1
#     installs it under %ProgramFiles% and verifies that directory's ACL.
#   * Tunnel names are matched against config files actually present in the
#     AmneziaWG config directory; a name is never pasted into a path or a
#     command line, so ".." and friends cannot escape it.
#   * Requests older than a few seconds are rejected, so a leftover request
#     file cannot be replayed later.
#
# ASCII-only: PowerShell 5.1 reads .ps1 as ANSI without a BOM.

$ErrorActionPreference = 'Stop'

# Fixed path, not LocalAppData: the task runs as SYSTEM, whose profile is not
# the user's, so both sides need one agreed location.
$DataDir     = Join-Path $env:ProgramData 'BigPictureVPN'
$RequestPath = Join-Path $DataDir 'request.json'
$ResultPath  = Join-Path $DataDir 'result.json'
$TunnelsPath = Join-Path $DataDir 'tunnels.json'
$LogPath     = Join-Path $DataDir 'control.log'

$ExePath        = 'C:\Program Files\AmneziaWG\amneziawg.exe'
$ConfigDir      = 'C:\Program Files\AmneziaWG\Data\Configurations'
$SERVICE_PREFIX = 'AmneziaWGTunnel$'
$MAX_AGE_SECONDS = 15
$SETTLE_TIMEOUT  = 25

function Write-Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Result([string]$id, [bool]$ok, [string]$error) {
    $payload = [ordered]@{
        id        = $id
        ok        = $ok
        error     = $error
        completed = (Get-Date).ToString('o')
    }
    $json = $payload | ConvertTo-Json -Compress
    # WriteAllText, not Set-Content: PowerShell 5.1 writes UTF-8 *with* a BOM,
    # and the Rust side's JSON parser rejects a leading BOM -- so the answer
    # was written but never read, and the app waited for it forever.
    [System.IO.File]::WriteAllText($ResultPath, $json)
    Write-Log "result: $json"
}

function Get-ConfigFiles {
    if (-not (Test-Path $ConfigDir)) { return @() }
    return @(Get-ChildItem $ConfigDir -Force -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '\.conf(\.dpapi)?$' })
}

function Get-TunnelName([System.IO.FileInfo]$file) {
    return ($file.Name -replace '\.conf(\.dpapi)?$','')
}

# Publish what tunnels exist and their state. The app cannot read the config
# directory itself, so this file is its only view of configs that currently
# have no service.
function Write-Inventory {
    $items = @()
    foreach ($cfg in Get-ConfigFiles) {
        $name = Get-TunnelName $cfg
        $svc  = Get-Service -Name "$SERVICE_PREFIX$name" -ErrorAction SilentlyContinue
        $items += [ordered]@{
            name       = $name
            hasService = [bool]$svc
            running    = ($null -ne $svc -and $svc.Status -eq 'Running')
        }
    }
    $payload = [ordered]@{
        generated = (Get-Date).ToString('o')
        tunnels   = $items
    }
    # ConvertTo-Json unwraps a single-element array, which would break the
    # consumer's parsing; -AsArray is not available on 5.1, so depth is set
    # explicitly and the array is forced by construction above.
    $json = $payload | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($TunnelsPath, $json)   # no BOM; see Write-Result
    Write-Log "inventory: $json"
}

# Wait until the service leaves a transitional state. 'GONE' means AmneziaWG
# removed it, which is what happens to a config that cannot connect.
function Wait-Settled([string]$name) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $SETTLE_TIMEOUT) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $s) { return 'GONE' }
        if ($s.Status -eq 'Running' -or $s.Status -eq 'Stopped') { return $s.Status.ToString() }
        Start-Sleep -Milliseconds 300
    }
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $s) { return 'GONE' }
    return $s.Status.ToString()
}

# Only one tunnel may be active: each config installs its own default route.
function Stop-OtherTunnels([string]$keepServiceName) {
    Get-Service -Name "$SERVICE_PREFIX*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $keepServiceName -and $_.Status -ne 'Stopped' } |
        ForEach-Object {
            Write-Log "stopping other tunnel $($_.Name)"
            try { Stop-Service -Name $_.Name -ErrorAction Stop; [void](Wait-Settled $_.Name) }
            catch { Write-Log "  could not stop $($_.Name): $($_.Exception.Message)" }
        }
}

$id = ''
try {
    if (-not (Test-Path $RequestPath)) {
        Write-Log 'no request file; nothing to do'
        exit 0
    }

    $request = Get-Content $RequestPath -Raw | ConvertFrom-Json
    $id     = [string]$request.id
    $action = [string]$request.action
    $tunnel = [string]$request.tunnel
    Write-Log "request: id=$id action=$action tunnel=$tunnel"

    # Reject replays of an old request. Unix seconds rather than a formatted
    # timestamp, so the writer (Rust) and the reader (PowerShell) cannot
    # disagree about date parsing.
    $issued = [int64]$request.issued
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $issued
    if ($age -gt $MAX_AGE_SECONDS -or $age -lt -$MAX_AGE_SECONDS) {
        Write-Result $id $false "stale request ($age s old)"
        exit 1
    }

    if ($action -notin @('list','start','stop')) {
        Write-Result $id $false "unsupported action '$action'"
        exit 1
    }

    if ($action -eq 'list') {
        Write-Inventory
        Write-Result $id $true ''
        exit 0
    }

    # Resolve the tunnel against configs actually on disk. The name is compared,
    # never concatenated into a path, so it cannot point outside the directory.
    $config = Get-ConfigFiles | Where-Object { (Get-TunnelName $_) -eq $tunnel } | Select-Object -First 1
    $serviceName = "$SERVICE_PREFIX$tunnel"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($null -eq $config -and $null -eq $service) {
        Write-Result $id $false "no config or service named '$tunnel'"
        exit 1
    }

    if ($action -eq 'stop') {
        if ($null -eq $service) {
            # AmneziaWG deletes the service when a tunnel is switched off, so
            # a missing service means it is already off.
            Write-Log 'no service: tunnel is already off'
            Write-Inventory
            Write-Result $id $true ''
            exit 0
        }
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $serviceName }
        $state = Wait-Settled $serviceName
        Write-Inventory
        if ($state -eq 'Stopped' -or $state -eq 'GONE') {
            Write-Result $id $true ''
            exit 0
        }
        Write-Result $id $false "tunnel did not stop (state $state)"
        exit 1
    }

    # --- start ---------------------------------------------------------------
    Stop-OtherTunnels $serviceName

    if ($null -eq $service) {
        if ($null -eq $config) {
            Write-Result $id $false "no config file for '$tunnel'"
            exit 1
        }
        # The service does not exist because the tunnel is off. Recreate it;
        # /installtunnelservice also starts it.
        Write-Log "installing tunnel service from $($config.FullName)"
        & $ExePath /installtunnelservice $config.FullName | Out-Null
        Start-Sleep -Milliseconds 700
    } elseif ($service.Status -ne 'Running') {
        Start-Service -Name $serviceName
    } else {
        Write-Log 'already running'
        Write-Inventory
        Write-Result $id $true ''
        exit 0
    }

    $state = Wait-Settled $serviceName
    Write-Inventory

    if ($state -eq 'Running') {
        Write-Result $id $true ''
        exit 0
    }
    if ($state -eq 'GONE') {
        Write-Result $id $false "AmneziaWG removed the tunnel: config '$tunnel' cannot connect"
        exit 1
    }
    Write-Result $id $false "tunnel did not start (state $state)"
    exit 1
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    try { Write-Result $id $false $_.Exception.Message } catch { }
    exit 1
}
