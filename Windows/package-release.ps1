param(
    [string]$Runtime = "win-x64",
    [switch]$FrameworkDependent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot
$version = (Get-Content (Join-Path $root "VERSION") -Raw).Trim()
$dist = Join-Path $root "dist"
$stage = Join-Path $dist "Passwall-Windows-$Runtime"
$archive = "$stage.zip"
$checksum = "$archive.sha256"

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $archive, $checksum -Force -ErrorAction SilentlyContinue
New-Item $stage -ItemType Directory -Force | Out-Null

$publishOptions = @(
    "-c", "Release", "--nologo", "-r", $Runtime,
    "--self-contained", "true",
    "-p:PublishSingleFile=true",
    "-p:IncludeNativeLibrariesForSelfExtract=true", "-p:Version=$version",
    "-o", $stage
)
if ($FrameworkDependent) {
    $publishOptions = @(
        "-c", "Release", "--nologo",
        "--self-contained", "false", "-p:Version=$version",
        "-o", $stage
    )
}

dotnet publish (Join-Path $PSScriptRoot "PasswallReceiver\PasswallReceiver.csproj") @publishOptions
dotnet publish (Join-Path $PSScriptRoot "PasswallReceiver.Watchdog\PasswallReceiver.Watchdog.csproj") @publishOptions

Copy-Item (Join-Path $PSScriptRoot "install-startup.ps1") $stage
Copy-Item (Join-Path $PSScriptRoot "Passwall.ico") $stage
$runtimeNote = if ($FrameworkDependent) {
    "This package requires the .NET 8 Runtime."
} else {
    "This package includes the required .NET runtime."
}
@"
Passwall Receiver $version

Run PasswallReceiver.exe to start once. It stays in the notification area.
Run install-startup.ps1 to install under Local AppData, create a desktop shortcut, and start automatically.
Run install-startup.ps1 -Uninstall to remove Passwall, its desktop shortcut, and its login task.

$runtimeNote
This public-alpha package is unsigned. Verify its SHA-256 checksum before use.
Use it only on devices and local networks you trust.
"@ | Set-Content (Join-Path $stage "INSTALL.txt") -Encoding ASCII

Remove-Item (Join-Path $stage "*.pdb") -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $archive

$verify = Join-Path $env:TEMP "passwall-release-verify"
Remove-Item $verify -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $archive $verify
foreach ($required in @(
    "PasswallReceiver.exe",
    "PasswallReceiver.Watchdog.exe",
    "Passwall.ico",
    "install-startup.ps1",
    "INSTALL.txt"
)) {
    if (-not (Test-Path (Join-Path $verify $required))) {
        throw "Release archive is missing $required"
    }
}
Remove-Item $verify -Recurse -Force

$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumLine = "$hash  $(Split-Path $archive -Leaf)`n"
[System.IO.File]::WriteAllText(
    $checksum,
    $checksumLine,
    [System.Text.Encoding]::ASCII)
Write-Warning "Windows executables are unsigned; sign them before external distribution."
Write-Host $archive
Write-Host $checksum
