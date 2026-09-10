param(
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host "Passwall Windows development preflight" -ForegroundColor Cyan
Write-Host "User: $env:USERNAME"

$privateIPv4 = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike "127.*" -and
        $_.AddressState -eq "Preferred"
    } |
    Select-Object -ExpandProperty IPAddress
Write-Host "IPv4: $($privateIPv4 -join ', ')"

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $sdk8 = dotnet --list-sdks | Where-Object { $_ -match '^8\.' }
    if ($sdk8) {
        Write-Host "[ok] .NET 8 SDK: $sdk8" -ForegroundColor Green
    } else {
        Write-Host "[missing] .NET 8 SDK" -ForegroundColor Yellow
        Write-Host "Install with: winget install Microsoft.DotNet.SDK.8"
    }
} else {
    Write-Host "[missing] dotnet" -ForegroundColor Yellow
    Write-Host "Install with: winget install Microsoft.DotNet.SDK.8"
}

$sshService = Get-Service sshd -ErrorAction SilentlyContinue

if ($sshService) {
    Write-Host "[ok] OpenSSH Server installed" -ForegroundColor Green
} elseif (!$Apply) {
    Write-Host "[check needed] OpenSSH Server is not currently available" -ForegroundColor Yellow
    Write-Host "Re-run as Administrator with: .\setup-dev.ps1 -Apply"
} else {
    if (!(Test-Administrator)) {
        throw "-Apply requires an Administrator PowerShell window"
    }
    Write-Host "Installing OpenSSH Server..."
    $sshCapability = Get-WindowsCapability -Online |
        Where-Object Name -like "OpenSSH.Server*"
    Add-WindowsCapability -Online -Name $sshCapability.Name | Out-Null
}

if ($Apply -or $sshService) {
    if (!(Test-Administrator) -and $Apply) {
        throw "-Apply requires an Administrator PowerShell window"
    }
    if ($Apply) {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd
    }
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "sshd: $($service.Status), startup configuration available"
    }
}

if ($dotnet -and $sdk8) {
    Push-Location "$PSScriptRoot\PasswallReceiver"
    try {
        dotnet build
    } finally {
        Pop-Location
    }
}

Write-Host "Preflight complete." -ForegroundColor Cyan
