# test-vpn-toggle.ps1
# Proof-of-concept: can we toggle the AmneziaWG tunnel from an external process?
# Cycle: baseline -> stop -> verify OFF -> start -> verify ON.
# The tunnel is always restored, even if a step fails.
#
# Must run elevated. ASCII-only on purpose: PowerShell 5.1 reads .ps1 as ANSI
# when there is no BOM, so non-ASCII text would arrive mangled.

$ErrorActionPreference = 'Stop'

$ServiceName = 'AmneziaWGTunnel$-PC'
$AdapterName = '-PC'
$LogPath     = Join-Path $PSScriptRoot 'test-result.log'

$script:Lines = @()
function Log([string]$msg) {
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    $line = "[$stamp] $msg"
    Write-Host $line
    $script:Lines += $line
}

function Get-SvcState {
    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $s) { return 'ABSENT' }
    return $s.Status.ToString()
}

function Get-AdapterState {
    $a = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if ($null -eq $a) { return 'ABSENT' }
    return $a.Status.ToString()
}

function Get-DefaultRouteIface {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Sort-Object RouteMetric |
         Select-Object -First 1
    if ($null -eq $r) { return 'NONE' }
    return $r.InterfaceAlias
}

function Get-ExternalIP {
    foreach ($url in @('https://api.ipify.org','https://ifconfig.me/ip')) {
        try {
            $ip = (Invoke-RestMethod -Uri $url -TimeoutSec 8).ToString().Trim()
            if ($ip) { return $ip }
        } catch { }
    }
    return 'UNAVAILABLE'
}

function Snapshot([string]$label) {
    $svc  = Get-SvcState
    $ad   = Get-AdapterState
    $rt   = Get-DefaultRouteIface
    $ip   = Get-ExternalIP
    Log "$label service=$svc adapter=$ad default-route=$rt external-ip=$ip"
    return [pscustomobject]@{ Service = $svc; Adapter = $ad; Route = $rt; IP = $ip }
}

function Wait-ForState([string]$want, [int]$timeoutSec = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if ((Get-SvcState) -eq $want) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Elevation is reported, not required: once grant-service-access.ps1 has run,
# the whole point is that this works from an ordinary, non-elevated process.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Log "=== AmneziaWG external toggle test ==="
Log "elevated: $elevated"
Log "service : $ServiceName"
Log "adapter : $AdapterName"

$ok = $false
$before = $null
$off    = $null
$after  = $null

try {
    $before = Snapshot 'BASELINE '

    if ($before.Service -ne 'Running') {
        Log "NOTE: tunnel was not running at start; test will still exercise start/stop."
    }

    # --- turn OFF ----------------------------------------------------------
    Log '--> Stop-Service ...'
    # No -Force: it enumerates dependent services, which needs a right we
    # deliberately did not grant. Plain stop is all the tunnel needs.
    Stop-Service -Name $ServiceName
    if (-not (Wait-ForState 'Stopped')) {
        Log 'FAIL: service did not reach Stopped within timeout.'
    } else {
        Log 'service reached Stopped.'
    }
    Start-Sleep -Seconds 3   # let routing settle
    $off = Snapshot 'VPN-OFF  '

    # did anything auto-resurrect the tunnel?
    Start-Sleep -Seconds 3
    $recheck = Get-SvcState
    Log "auto-restart check after 3s: service=$recheck"

    # --- turn ON -----------------------------------------------------------
    Log '--> Start-Service ...'
    Start-Service -Name $ServiceName
    if (-not (Wait-ForState 'Running')) {
        Log 'FAIL: service did not reach Running within timeout.'
    } else {
        Log 'service reached Running.'
    }
    Start-Sleep -Seconds 4   # let handshake + routing settle
    $after = Snapshot 'VPN-ON   '

    # --- verdict -----------------------------------------------------------
    $stoppedOk = ($off.Service  -eq 'Stopped')
    $startedOk = ($after.Service -eq 'Running')
    $routeFlip = ($off.Route -ne $before.Route) -and ($after.Route -eq $before.Route)
    $ipFlip    = ($off.IP -ne 'UNAVAILABLE') -and ($before.IP -ne 'UNAVAILABLE') -and
                 ($off.IP -ne $before.IP) -and ($after.IP -eq $before.IP)

    Log ''
    Log '=== VERDICT ==='
    Log ("service stops on command : " + $(if ($stoppedOk) { 'YES' } else { 'NO' }))
    Log ("service starts on command: " + $(if ($startedOk) { 'YES' } else { 'NO' }))
    Log ("default route flips      : " + $(if ($routeFlip) { 'YES' } else { 'NO' }))
    Log ("external IP flips        : " + $(if ($ipFlip)    { 'YES' } else { 'NO' }))
    $ok = $stoppedOk -and $startedOk
    Log ("OVERALL                  : " + $(if ($ok) { 'TOGGLE WORKS' } else { 'TOGGLE FAILED' }))
}
catch {
    Log "ERROR: $($_.Exception.Message)"
}
finally {
    # safety net: never leave the user without their tunnel
    $final = Get-SvcState
    if ($final -ne 'Running') {
        Log "SAFETY: service is '$final', forcing it back to Running ..."
        try {
            Start-Service -Name $ServiceName
            [void](Wait-ForState 'Running' 25)
            Log "SAFETY: service is now '$(Get-SvcState)'."
        } catch {
            Log "SAFETY FAILED: $($_.Exception.Message) -- start the tunnel manually!"
        }
    } else {
        Log 'SAFETY: tunnel is Running. All good.'
    }
    $script:Lines | Set-Content -Path $LogPath -Encoding UTF8
    Log "log written to $LogPath"
}
