param([switch]$StartupStatus)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Never force-kill a receiver during input sharing or an active transfer.
if (-not $StartupStatus -and (Get-Process "PasswallReceiver", "PasswallReceiver.Watchdog" -ErrorAction SilentlyContinue)) {
    throw "Quit Passwall Receiver from its tray menu before installing or uninstalling."
}

# Only retire the old installer task when it belongs to this installation.
$appDirectory = Join-Path $env:LOCALAPPDATA "Passwall\App"
$receiver = Join-Path $appDirectory "PasswallReceiver.exe"
$runValue = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name PasswallReceiver -ErrorAction SilentlyContinue
if (-not $StartupStatus -and $runValue -and $runValue.PasswallReceiver -ne ('"' + $receiver + '"')) {
    throw "Another program owns the PasswallReceiver login entry. Resolve the conflicting startup entry first."
}
$task = Get-ScheduledTask -TaskName "PasswallReceiver" -ErrorAction SilentlyContinue
if ($StartupStatus) {
    if ($task -and @($task.Actions).Count -eq 1 -and $task.Actions[0].Execute.Trim('"') -eq $receiver) { exit 2 }
    exit 0
}
if ($task) {
    if (@($task.Actions).Count -ne 1 -or
        $task.Actions[0].Execute.Trim('"') -ne $receiver) {
        throw "An existing Passwall startup task uses another location. Remove it with its original installer first."
    }
    $owner = $task.Principal.UserId
    $ownerSid = if ($owner -like 'S-1-*') { $owner } else {
        ([Security.Principal.NTAccount]::new($owner)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if ($ownerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw "The existing Passwall startup task belongs to another user."
    }
    Unregister-ScheduledTask -TaskName "PasswallReceiver" -Confirm:$false -ErrorAction Stop
}
