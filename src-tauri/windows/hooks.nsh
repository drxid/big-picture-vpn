; The installer already runs elevated, which is the one moment a UAC prompt can
; be answered. It registers the task that lets the app switch AmneziaWG tunnels
; later without one.
;
; Sysnative, not plain powershell.exe: NSIS is a 32-bit process, so it would get
; the 32-bit PowerShell, whose %ProgramFiles% is "Program Files (x86)". The helper
; would be installed there instead of where the script says it is.

!define BPVPN_POWERSHELL "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

!macro NSIS_HOOK_POSTINSTALL
  nsExec::ExecToLog '"${BPVPN_POWERSHELL}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\setup-scheduled-task.ps1"'
  Pop $0
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::ExecToLog '"${BPVPN_POWERSHELL}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\setup-scheduled-task.ps1" -Remove'
  Pop $0
!macroend

; The setup script logs next to itself, and the uninstaller only deletes what it
; installed, so without this the folder would stay behind.
!macro NSIS_HOOK_POSTUNINSTALL
  Delete "$INSTDIR\scripts\task-setup-output.txt"
  RMDir "$INSTDIR\scripts"
  RMDir "$INSTDIR"
!macroend
