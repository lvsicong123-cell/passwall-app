Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "Installer lifecycle tests may run only on a disposable GitHub-hosted runner"
}
$root = Split-Path $PSScriptRoot
$setup = Join-Path $root "dist\Passwall-Setup.exe"
$payload = Join-Path $root "dist\Passwall-Windows-win-x64"
$app = Join-Path $env:LOCALAPPDATA "Passwall\App"
$data = Split-Path $app
$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Passwall"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$desktop = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) "Passwall Receiver.lnk"
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Run-Setup {
    $p = Start-Process $setup -ArgumentList "/S" -Wait -PassThru
    Assert ($p.ExitCode -eq 0) "Setup failed: $($p.ExitCode)"
}
function Run-Uninstall {
    # NSIS _?= keeps the test process synchronous; normal GUI uninstalls self-copy.
    $p = Start-Process (Join-Path $app "Uninstall.exe") -ArgumentList "/S _?=$app" -Wait -PassThru
    return $p.ExitCode
}
Assert (-not (Test-Path $app)) "Refusing to modify an existing installation"
Assert (-not (Test-Path $key)) "Unexpected pre-existing uninstall registration"
Assert (-not (Get-ScheduledTask -TaskName PasswallReceiver -ErrorAction SilentlyContinue)) "Unexpected startup task"
$expected = (Get-Content "$setup.sha256" -Raw).Trim().Split()[0]
Assert ((Get-FileHash $setup -Algorithm SHA256).Hash -eq $expected) "Setup checksum mismatch"

# A normal machine can have Restricted script policy; setup must not change it.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Restricted -Force
$policies = Get-ExecutionPolicy -List | ConvertTo-Json -Compress
Run-Setup
foreach ($name in @('PasswallReceiver.exe', 'PasswallReceiver.Watchdog.exe', 'PasswallReceiver.Watchdog.runtimeconfig.json', 'Passwall.ico')) {
    Assert ((Get-FileHash (Join-Path $app $name)).Hash -eq (Get-FileHash (Join-Path $payload $name)).Hash) "Installed payload mismatch: $name"
}
Assert (Test-Path $desktop) "Desktop shortcut missing"
Assert (Test-Path $key) "Windows Apps uninstall entry missing"
Assert ((Get-ItemProperty $key).DisplayVersion -eq (Get-Content (Join-Path $root VERSION) -Raw).Trim()) "Wrong installed version"
Assert (-not (Get-ItemProperty $runKey -Name PasswallReceiver -ErrorAction SilentlyContinue)) "Startup should default off"
Assert (-not (Get-Process PasswallReceiver -ErrorAction SilentlyContinue)) "Silent setup must not launch the app"
# Conflicting startup ownership must fail without changing the foreign value.
New-ItemProperty $runKey -Name PasswallReceiver -Value 'foreign-program.exe' -PropertyType String -Force | Out-Null
$p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru
Assert ($p.ExitCode -ne 0) "Foreign startup entry must block installation"
Assert ((Get-ItemProperty $runKey).PasswallReceiver -eq 'foreign-program.exe') "Foreign startup entry changed"
Remove-ItemProperty $runKey -Name PasswallReceiver
Set-Content (Join-Path $data 'installer-test-sentinel.txt') 'keep settings'
Set-Content (Join-Path $app 'user-file.txt') 'keep unknown file'

# Explicit selection is represented by the existing native Run entry on upgrade.
New-ItemProperty $runKey -Name PasswallReceiver -Value ('"' + (Join-Path $app 'PasswallReceiver.exe') + '"') -PropertyType String -Force | Out-Null
Run-Setup
Assert ((Get-ItemProperty $runKey).PasswallReceiver -eq ('"' + (Join-Path $app 'PasswallReceiver.exe') + '"')) "Upgrade lost startup preference"

# A locked executable must produce failure and retain a working uninstall entry.
$lock = [IO.File]::Open((Join-Path $app 'PasswallReceiver.exe'), 'Open', 'Read', 'None')
try { Assert ((Run-Uninstall) -ne 0) "Locked payload must fail uninstall" } finally { $lock.Dispose() }
Assert (Test-Path $key) "Failed uninstall removed recovery entry"
Assert (Test-Path (Join-Path $app 'Uninstall.exe')) "Failed uninstall removed uninstaller"
Run-Setup
Assert ((Run-Uninstall) -eq 0) "Uninstall failed"
Assert (-not (Test-Path (Join-Path $app 'PasswallReceiver.exe'))) "Receiver remains installed"
Assert (-not (Test-Path $key)) "Uninstall entry remains"
Assert (-not (Get-ItemProperty $runKey -Name PasswallReceiver -ErrorAction SilentlyContinue)) "Login startup remains"
Assert (Test-Path (Join-Path $data 'installer-test-sentinel.txt')) "Uninstall removed user settings"
Assert (Test-Path (Join-Path $app 'user-file.txt')) "Uninstall removed unknown file"

# Simulate the v0.1.0 script-installed payload and task without launching it.
Copy-Item (Join-Path $payload '*') $app -Force
$action = New-ScheduledTaskAction -Execute (Join-Path $app 'PasswallReceiver.exe')
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName PasswallReceiver -Action $action -Principal $principal -Force | Out-Null
# A running receiver must block before modifying the legacy startup task.
$fake = Join-Path $env:TEMP 'PasswallReceiver.exe'
Add-Type -TypeDefinition 'public class InstallerProcessFixture { public static void Main() { System.Threading.Thread.Sleep(60000); } }' -OutputAssembly $fake -OutputType ConsoleApplication
$running = Start-Process $fake -PassThru
try {
    $p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru
    Assert ($p.ExitCode -ne 0) "Running receiver must block setup"
    Assert (-not $running.HasExited) "Setup killed a running receiver"
    Assert ([bool](Get-ScheduledTask -TaskName PasswallReceiver -ErrorAction SilentlyContinue)) "Blocked setup removed legacy startup"
} finally { Stop-Process -Id $running.Id -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300
Run-Setup
Assert (-not (Get-ScheduledTask -TaskName PasswallReceiver -ErrorAction SilentlyContinue)) "Legacy task not retired"
Assert ((Get-ItemProperty $runKey).PasswallReceiver -eq ('"' + (Join-Path $app 'PasswallReceiver.exe') + '"')) "Legacy startup preference not migrated"
Assert ((Run-Uninstall) -eq 0) "Migrated uninstall failed"
Assert (-not (Test-Path (Join-Path $app 'PasswallReceiver.Watchdog.runtimeconfig.json'))) "Legacy runtime file remains"
$foreignAction = New-ScheduledTaskAction -Execute 'C:\foreign-program.exe'
Register-ScheduledTask -TaskName PasswallReceiver -Action $foreignAction -Principal $principal -Force | Out-Null
try {
    $p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru
    Assert ($p.ExitCode -ne 0) "Foreign task must block setup"
    Assert ((Get-ScheduledTask -TaskName PasswallReceiver).Actions[0].Execute -eq 'C:\foreign-program.exe') "Foreign task changed"
} finally { Unregister-ScheduledTask -TaskName PasswallReceiver -Confirm:$false }
Assert ((Get-ExecutionPolicy -List | ConvertTo-Json -Compress) -eq $policies) "Installer changed persistent execution policy"
Write-Host "PASS: installer payload, shortcuts, version, default startup, upgrade, failure recovery, legacy migration, uninstall and data preservation. No hardware acceptance."
