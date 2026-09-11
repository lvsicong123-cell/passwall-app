Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "Sections.nsh"

Name "Passwall Receiver"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Passwall\App"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "Passwall Receiver"
VIAddVersionKey /LANG=1033 "FileDescription" "Passwall Receiver Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Passwall contributors"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Passwall"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define MUI_ICON "Passwall.ico"
!define MUI_UNICON "Passwall.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\PasswallReceiver.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open Passwall Receiver"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro PrepareLifecycle
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File "installer-lifecycle.ps1"
    ; Process-only execution policy; Group Policy still takes precedence.
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-lifecycle.ps1"'
    Pop $0
    ${If} $0 != 0
        MessageBox MB_OK|MB_ICONSTOP "Cannot continue. Quit Passwall Receiver and check the installation details. No files were removed. If your device blocks scripts, contact your administrator." /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
!macroend

Section "Passwall Receiver (required)" Core
    SectionIn RO
    !insertmacro PrepareLifecycle
    SetOutPath "$INSTDIR"
    ClearErrors
    File "${PAYLOAD}\PasswallReceiver.exe"
    File "${PAYLOAD}\PasswallReceiver.Watchdog.exe"
    File "${PAYLOAD}\PasswallReceiver.Watchdog.runtimeconfig.json"
    File "${PAYLOAD}\Passwall.ico"
    File "..\LICENSE"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    ${If} ${Errors}
        SetErrorLevel 1
        Abort "Unable to write application files. Check available space and permissions."
    ${EndIf}
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Passwall Receiver"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Passwall contributors"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\Passwall.ico"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
    CreateDirectory "$SMPROGRAMS\Passwall"
    CreateShortcut "$SMPROGRAMS\Passwall\Passwall Receiver.lnk" "$INSTDIR\PasswallReceiver.exe"
    CreateShortcut "$SMPROGRAMS\Passwall\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
    ${If} ${Errors}
        SetErrorLevel 1
        Abort "Unable to finish setup. Run the installer again after checking permissions."
    ${EndIf}
    ReadRegStr $0 HKCU "${RUN_KEY}" "PasswallReceiver"
    ClearErrors
    ${If} $0 != ""
        DeleteRegValue HKCU "${RUN_KEY}" "PasswallReceiver"
    ${EndIf}
    Delete "$DESKTOP\Passwall Receiver.lnk"
    ${If} ${Errors}
        SetErrorLevel 1
        Abort "Unable to update startup or shortcuts. Check permissions and retry."
    ${EndIf}
SectionEnd

Section "Desktop shortcut" Desktop
    ClearErrors
    CreateShortcut "$DESKTOP\Passwall Receiver.lnk" "$INSTDIR\PasswallReceiver.exe"
    ${If} ${Errors}
        SetErrorLevel 1
        Abort "Unable to create the desktop shortcut."
    ${EndIf}
SectionEnd

Section /o "Start at login" Startup
    ClearErrors
    WriteRegStr HKCU "${RUN_KEY}" "PasswallReceiver" '$\"$INSTDIR\PasswallReceiver.exe$\"'
    ${If} ${Errors}
        SetErrorLevel 1
        Abort "Unable to enable login startup."
    ${EndIf}
SectionEnd

Function .onInit
    SetShellVarContext current
    ${IfNot} ${IsNativeAMD64}
        MessageBox MB_OK|MB_ICONSTOP "This package requires x64 Windows." /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    SetRegView 64
    ${DisableX64FSRedirection}
    ; Keep this installer scoped to a fixed current-user location, including /D.
    StrCpy $INSTDIR "$LOCALAPPDATA\Passwall\App"
    ReadRegStr $0 HKCU "${RUN_KEY}" "PasswallReceiver"
    ${If} $0 == '$\"$INSTDIR\PasswallReceiver.exe$\"'
        !insertmacro SelectSection ${Startup}
    ${EndIf}
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File "installer-lifecycle.ps1"
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\installer-lifecycle.ps1" -StartupStatus'
    Pop $0
    ${If} $0 == 2
        !insertmacro SelectSection ${Startup}
    ${EndIf}
FunctionEnd

Function un.onInit
    SetShellVarContext current
    SetRegView 64
    ${DisableX64FSRedirection}
    ${If} $INSTDIR != "$LOCALAPPDATA\Passwall\App"
        MessageBox MB_OK|MB_ICONSTOP "Uninstaller must run from the original installation folder." /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
FunctionEnd

Section "Uninstall"
    !insertmacro PrepareLifecycle
    ClearErrors
    Delete "$INSTDIR\PasswallReceiver.exe"
    Delete "$INSTDIR\PasswallReceiver.Watchdog.exe"
    Delete "$INSTDIR\PasswallReceiver.Watchdog.runtimeconfig.json"
    Delete "$INSTDIR\Passwall.ico"
    Delete "$INSTDIR\LICENSE"
    Delete "$INSTDIR\install-startup.ps1"
    Delete "$INSTDIR\INSTALL.txt"
    ${If} ${Errors}
        MessageBox MB_OK|MB_ICONSTOP "Some application files could not be removed. Close applications and try uninstalling again." /SD IDOK
        SetErrorLevel 1
        Abort
    ${EndIf}
    Delete "$DESKTOP\Passwall Receiver.lnk"
    Delete "$SMPROGRAMS\Passwall\Passwall Receiver.lnk"
    Delete "$SMPROGRAMS\Passwall\Uninstall.lnk"
    RMDir "$SMPROGRAMS\Passwall"
    DeleteRegValue HKCU "${RUN_KEY}" "PasswallReceiver"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    SetOutPath "$TEMP"
    RMDir "$INSTDIR"
SectionEnd
