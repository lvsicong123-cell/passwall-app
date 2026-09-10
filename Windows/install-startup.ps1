param(
    [string]$TaskName = "PasswallReceiver",
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installDirectory = Join-Path $env:LOCALAPPDATA "Passwall\App"
$shortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) "Passwall Receiver.lnk"

if ($Uninstall -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$stopDeadline = [DateTime]::UtcNow.AddSeconds(5)
do {
    $running = Get-Process "PasswallReceiver", "PasswallReceiver.Watchdog" -ErrorAction SilentlyContinue
    if (-not $running) { break }
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt $stopDeadline)
if (Get-Process "PasswallReceiver", "PasswallReceiver.Watchdog" -ErrorAction SilentlyContinue) {
    throw "Passwall is still running. Close it and run the installer again."
}

if ($Uninstall) {
    Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item $installDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $TaskName"
    exit 0
}

$sourceReceiver = Join-Path $PSScriptRoot "PasswallReceiver.exe"
if (-not (Test-Path $sourceReceiver)) {
    throw "Receiver not found: $sourceReceiver"
}

if ([System.IO.Path]::GetFullPath($PSScriptRoot) -ne [System.IO.Path]::GetFullPath($installDirectory)) {
    if (Test-Path $installDirectory) {
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                Remove-Item $installDirectory -Recurse -Force -ErrorAction Stop
                break
            } catch {
                if ($attempt -eq 20) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    New-Item $installDirectory -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot "*") $installDirectory -Recurse -Force
}

$receiverPath = Join-Path $installDirectory "PasswallReceiver.exe"
$userID = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction `
    -Execute $receiverPath `
    -WorkingDirectory $installDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userID
$principal = New-ScheduledTaskPrincipal `
    -UserId $userID `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

if ($TaskName -ne "PasswallReceiverDev") {
    Unregister-ScheduledTask -TaskName "PasswallReceiverDev" -Confirm:$false -ErrorAction SilentlyContinue
}

$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$shortcut.TargetPath = $receiverPath
$shortcut.WorkingDirectory = $installDirectory
$shortcut.Save()

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed $TaskName for $userID at $installDirectory"
