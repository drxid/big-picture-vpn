# setup-scheduled-task.ps1
# One-time (elevated) setup of the privileged helper that starts and stops
# AmneziaWG tunnels.
#
# Granting the user rights on the tunnel service works only until AmneziaWG
# recreates it, which resets the descriptor -- observed twice in one session.
# A scheduled task does not depend on the service, so it survives that, and
# survives AmneziaWG updates too.
#
# The task runs as the current user with highest privileges. Because that user
# is an administrator, they can trigger it themselves with no UAC prompt --
# which is the whole point, since a UAC dialog cannot be answered with a
# gamepad from Steam Big Picture.
#
# Usage:
#   setup-scheduled-task.ps1            install
#   setup-scheduled-task.ps1 -Remove    uninstall
#
# ASCII-only: PowerShell 5.1 reads .ps1 as ANSI without a BOM.

[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$TaskName    = 'BigPictureVPN-Control'
$InstallDir  = Join-Path $env:ProgramFiles 'BigPictureVPN'
$ScriptName  = 'tunnel-control.ps1'
$TargetPath  = Join-Path $InstallDir $ScriptName
$SourcePath  = Join-Path $PSScriptRoot $ScriptName
# Where the app and the elevated helper exchange request/result files. Must be
# reachable from both, and the task runs as SYSTEM, so it cannot be in the
# user's profile.
$DataDir     = Join-Path $env:ProgramData 'BigPictureVPN'

# The elevated window closes as soon as the script ends, so every line is
# mirrored into a log the calling session can read.
$LogPath = Join-Path $PSScriptRoot 'task-setup-output.txt'
Set-Content -Path $LogPath -Value '' -Encoding ASCII
function Info([string]$m) { Write-Host $m; Add-Content -Path $LogPath -Value $m -Encoding ASCII }
function Fail([string]$m) { Info "FAIL: $m"; exit 1 }

# --- elevation guard -------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'not elevated. Re-run as Administrator.'
}

# --- uninstall -------------------------------------------------------------
if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Info "removed task $TaskName"
    } else {
        Info "task $TaskName not found"
    }
    if (Test-Path $TargetPath) {
        Remove-Item $TargetPath -Force
        Info "removed $TargetPath"
    }
    if ((Test-Path $InstallDir) -and -not (Get-ChildItem $InstallDir -Force)) {
        Remove-Item $InstallDir -Force
        Info "removed empty $InstallDir"
    }
    Info 'UNINSTALL DONE.'
    exit 0
}

# --- install the helper into a location users cannot write -----------------
# This is the security boundary: the script runs as administrator and is
# triggered by an unprivileged process, so if an ordinary user could replace
# the file, they would gain arbitrary code execution as admin.
if (-not (Test-Path $SourcePath)) { Fail "helper script not found: $SourcePath" }

if (-not (Test-Path $InstallDir)) {
    [void](New-Item -ItemType Directory -Path $InstallDir)
    Info "created $InstallDir"
}
Copy-Item $SourcePath $TargetPath -Force
Info "installed $TargetPath"

# Verify the assumption rather than trusting it: report any non-admin identity
# that can write here. Compared by SID, not by name -- account names are
# localised, and this machine reports them in Russian.
$SafeSids = @(
    'S-1-5-18',                                                              # SYSTEM
    'S-1-5-32-544',                                                          # Administrators
    'S-1-3-0',                                                               # CREATOR OWNER
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'         # TrustedInstaller
)

$acl = Get-Acl $InstallDir
$writers = $acl.Access | Where-Object {
    if ($_.AccessControlType -ne 'Allow') { return $false }
    if (-not ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)) { return $false }
    $sid = ''
    try { $sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    return ($sid -notin $SafeSids)
}
if ($writers) {
    Info 'WARNING: these identities can write to the install directory:'
    $writers | ForEach-Object { Info "    $($_.IdentityReference) : $($_.FileSystemRights)" }
    Info 'That would let them replace the elevated helper. Fix the ACL before relying on this.'
} else {
    Info 'install dir is writable only by administrators/SYSTEM.'
}

# --- register the task -----------------------------------------------------
$userSid = $id.User.Value
Info "granting run rights to: $($id.Name) ($userSid)"

# --- shared data directory -------------------------------------------------
if (-not (Test-Path $DataDir)) {
    [void](New-Item -ItemType Directory -Path $DataDir)
    Info "created $DataDir"
}
# The app writes request.json here as an ordinary user; SYSTEM reads it. Modify
# rather than FullControl, so the user cannot rewrite the directory's own ACL.
$dataAcl = Get-Acl $DataDir
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
    (New-Object Security.Principal.SecurityIdentifier($userSid)),
    [Security.AccessControl.FileSystemRights]::Modify,
    ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Allow)
$dataAcl.SetAccessRule($rule)
Set-Acl -Path $DataDir -AclObject $dataAcl
Info "granted the user Modify on $DataDir"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $TargetPath)

# Run as SYSTEM. Interactive needs an elevated interactive token the scheduler
# cannot mint without a UAC prompt, and S4U needs the account to hold the
# "log on as a batch job" right -- both report success and silently run
# nothing. SYSTEM depends on neither, so it works regardless of how the
# account is configured. The user is given permission to start the task, but
# not to modify it, which would otherwise mean arbitrary code as SYSTEM.
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

# Queue, not IgnoreNew. The app fires requests back to back -- listing tunnels
# at startup and then turning the VPN on -- and while the previous run is still
# marked Running, `schtasks /run` silently does nothing while still returning
# exit code 0. The second request then never gets an answer and the app hangs
# waiting for one.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances Queue `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable

# No trigger: the app is the only thing that starts it.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Info "replaced existing task"
}

[void](Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Principal $principal -Settings $settings `
    -Description 'Starts and stops AmneziaWG tunnels for Big Picture VPN.')

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Fail 'task did not register.' }

# --- let the user start the task, and only start it ------------------------
# A task registered by an administrator is not runnable by a standard token by
# default. 0x1200a9 is read + execute: enough to trigger it, not enough to
# rewrite what it does.
try {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $registered = $service.GetFolder('\').GetTask($TaskName)

    $DACL_SECURITY_INFORMATION = 4
    $sddl = $registered.GetSecurityDescriptor($DACL_SECURITY_INFORMATION)
    Info "task sddl before: $sddl"

    if ($sddl -match [regex]::Escape(";;;$userSid)")) {
        Info 'task already grants this user run rights'
    } else {
        # Append inside the DACL, ahead of any SACL section.
        if ($sddl -match '^(D:.*?)(S:.*)$') { $dacl = $Matches[1]; $sacl = $Matches[2] }
        else { $dacl = $sddl; $sacl = '' }
        $newSddl = "$dacl(A;;0x1200a9;;;$userSid)$sacl"
        $registered.SetSecurityDescriptor($newSddl, 0)
        Info "task sddl after : $($registered.GetSecurityDescriptor($DACL_SECURITY_INFORMATION))"
    }
} catch {
    Info "WARNING: could not adjust task permissions: $($_.Exception.Message)"
    Info 'The app may not be able to start the task without elevation.'
}

Info ''
Info "registered task : $($task.TaskName)"
Info "run level       : $($task.Principal.RunLevel)"
Info "runs as         : $($task.Principal.UserId)"
Info "action          : powershell.exe -File `"$TargetPath`""
Info "data dir        : $DataDir"
Info ''
Info 'SETUP DONE.'
