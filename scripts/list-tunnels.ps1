# list-tunnels.ps1
# READ-ONLY inventory of AmneziaWG tunnels: which configs exist on disk, which
# of them already have a service, and how each service is configured.
# Needs elevation only because Data\Configurations is admin-only.
#
# ASCII-only: PowerShell 5.1 reads .ps1 as ANSI without a BOM.

$ErrorActionPreference = 'Continue'

$ConfigDir = 'C:\Program Files\AmneziaWG\Data\Configurations'
$LogPath   = Join-Path $PSScriptRoot 'tunnels-inventory.txt'

Set-Content -Path $LogPath -Value '' -Encoding ASCII
function Info([string]$m) { Write-Host $m; Add-Content -Path $LogPath -Value $m -Encoding ASCII }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
Info "elevated: $($pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

Info ''
Info '=== CONFIG FILES ==='
if (Test-Path $ConfigDir) {
    $files = Get-ChildItem $ConfigDir -Force -ErrorAction SilentlyContinue
    if (-not $files) {
        Info '(none)'
    } else {
        foreach ($f in $files) {
            # "<name>.conf.dpapi" (encrypted) or "<name>.conf" (plain)
            $tunnel = $f.Name -replace '\.conf(\.dpapi)?$',''
            Info ("{0,-40} tunnel-name='{1}'  {2} bytes" -f $f.Name, $tunnel, $f.Length)
        }
    }
} else {
    Info "config dir not readable: $ConfigDir"
}

Info ''
Info '=== TUNNEL SERVICES ==='
$svcs = Get-CimInstance Win32_Service -Filter "Name LIKE 'AmneziaWGTunnel%'" -ErrorAction SilentlyContinue
if (-not $svcs) {
    Info '(none)'
} else {
    foreach ($s in $svcs) {
        Info ("{0,-32} state={1,-8} start={2}" -f $s.Name, $s.State, $s.StartMode)
        Info ("    path: {0}" -f $s.PathName)
        $sddl = ((& sc.exe sdshow $s.Name | Where-Object { $_.Trim() }) -join '').Trim()
        Info ("    sddl: {0}" -f $sddl)
    }
}

Info ''
Info '=== ADAPTERS ==='
Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'WireGuard' } |
    ForEach-Object { Info ("{0,-20} {1,-12} ifIndex={2}" -f $_.Name, $_.Status, $_.ifIndex) }

Info ''
Info "written to $LogPath"
