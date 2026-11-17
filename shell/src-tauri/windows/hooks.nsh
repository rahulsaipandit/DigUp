; DigUp's additions to Tauri's NSIS installer (bundle.windows.nsis.installerHooks).

; The helper folder is replaced whole: an update would otherwise leave behind what an older version had there and
; this one doesn't (another ffmpeg's DLLs).
!macro NSIS_HOOK_PREINSTALL
  ${If} $INSTDIR != ""
    RMDir /r "$INSTDIR\helper"
  ${EndIf}
!macroend

; "Delete the application data" also takes DigUp's model (865 MB) and its index: the app keeps them in
; %LOCALAPPDATA%\DigUp, not in the data folders named after its identifier, which Tauri deletes. Never on an update.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    RMDir /r "$LOCALAPPDATA\DigUp\Models"
    RMDir /r "$LOCALAPPDATA\DigUp\index"
    RMDir "$LOCALAPPDATA\DigUp"
  ${EndIf}
!macroend

; DOWNSTREAM-FORK (2026-11-17, security): the worker that reads files for DigUp runs in an AppContainer, which is given read
; access to the folders DigUp's own files are in. An uninstall takes that access and the container away again, before the
; files are removed (`digup sandbox-remove`). Not on an update: the access stays, and the helper folder gets it again.
!macro NSIS_HOOK_PREUNINSTALL
  ${If} $UpdateMode <> 1
    ${If} ${FileExists} "$INSTDIR\helper\digup.exe"
      nsExec::Exec '"$INSTDIR\helper\digup.exe" sandbox-remove'
      Pop $0
    ${EndIf}
  ${EndIf}
!macroend
