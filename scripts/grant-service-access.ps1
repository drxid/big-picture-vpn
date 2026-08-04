# grant-service-access.ps1
# Grants one specific user the right to START/STOP the AmneziaWG tunnel service,
# so the Big Picture app can toggle the VPN without ever raising a UAC prompt.
#
# Only that single service is touched. The original security descriptor is saved
# to service-sddl-backup.txt and can be restored with -Revoke.
#
# Must run elevated (one time). ASCII-only: PowerShell 5.1 reads .ps1 as ANSI
# without a BOM, so non-ASCII text would arrive mangled.

[CmdletBinding()]
param(
    # SID to grant access to. Defaults to the user running the script.
    [string]$UserSid,

    # Restore the security descriptor saved in the backup file.
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'

$BackupPath = Join-Path $PSScriptRoot 'service-sddl-backup.txt'
$LogPath    = Join-Path $PSScriptRoot 'grant-output.txt'

# Access rights we grant:
#   RP = SERVICE_START
#   WP = SERVICE_STOP
#   LC = SERVICE_QUERY_STATUS
#   RC = READ_CONTROL
$GrantMask = 'RPWPLCRC'

# The elevated window closes the moment the script ends, so every line is
# mirrored into a log file that the calling (non-elevated) session can read.
Set-Content -Path $LogPath -Value '' -Encoding ASCII
function Info([string]$m) { Write-Host $m; Add-Content -Path $LogPath -Value $m -Encoding ASCII }
function Fail([string]$m) { Info "FAIL: $m"; exit 1 }

# --- elevation guard -------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'not elevated. Re-run as Administrator.'
}

if (-not $UserSid) { $UserSid = $id.User.Value }

# --- locate the tunnel service ---------------------------------------------
# Service name follows the config file name, so find it by prefix rather than
# hardcoding: a different .conf would produce a different service name.
$svc = Get-Service -Name 'AmneziaWGTunnel$*' -ErrorAction SilentlyContinue
if ($null -eq $svc) { Fail 'no AmneziaWGTunnel$* service found.' }
if ($svc -is [array]) {
    Info "Multiple tunnel services found:"
    $svc | ForEach-Object { Info "  - $($_.Name)" }
    Fail 'more than one tunnel service; specify which one manually.'
}
$ServiceName = $svc.Name
Info "service : $ServiceName"
Info "sid     : $UserSid"

# --- read current descriptor -----------------------------------------------
$current = (& sc.exe sdshow $ServiceName | Where-Object { $_.Trim() }) -join ''
$current = $current.Trim()
if ($LASTEXITCODE -ne 0 -or -not $current) { Fail "sdshow failed (exit $LASTEXITCODE)." }
Info "current : $current"

# --- revoke path -----------------------------------------------------------
if ($Revoke) {
    if (-not (Test-Path $BackupPath)) { Fail "no backup at $BackupPath" }
    $original = (Get-Content $BackupPath -Raw).Trim()
    Info "restoring: $original"
    & sc.exe sdset $ServiceName $original | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "sdset failed (exit $LASTEXITCODE)." }
    Info 'RESTORED.'
    exit 0
}

# --- back up before touching anything --------------------------------------
if (-not (Test-Path $BackupPath)) {
    $current | Set-Content -Path $BackupPath -Encoding ASCII
    Info "backup  : saved to $BackupPath"
} else {
    Info "backup  : already exists at $BackupPath (keeping the original)"
}

# --- idempotency check -----------------------------------------------------
if ($current -match [regex]::Escape(";;;$UserSid)")) {
    Info 'ACE for this SID is already present. Nothing to do.'
    exit 0
}

# --- splice the new ACE onto the end of the DACL ---------------------------
# A descriptor may carry a trailing SACL (S:...); the new ACE must go at the
# end of the D: section, not after S:.
if ($current -match '^(D:.*?)(S:.*)$') {
    $dacl = $Matches[1]
    $sacl = $Matches[2]
} else {
    $dacl = $current
    $sacl = ''
}
$newSddl = "$dacl(A;;$GrantMask;;;$UserSid)$sacl"
Info "new     : $newSddl"

& sc.exe sdset $ServiceName $newSddl | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "sdset failed (exit $LASTEXITCODE)." }

# --- verify -----------------------------------------------------------------
$after = ((& sc.exe sdshow $ServiceName | Where-Object { $_.Trim() }) -join '').Trim()
if ($after -match [regex]::Escape(";;;$UserSid)")) {
    Info 'GRANTED. Verified in the live descriptor.'
    exit 0
} else {
    Fail "descriptor does not contain the new ACE after sdset: $after"
}
