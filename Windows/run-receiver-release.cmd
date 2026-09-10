@echo off
setlocal
set "RECEIVER_DIR=%~dp0PasswallReceiver\bin\Release\net8.0-windows"
set "LOG_FILE=%~dp0receiver-release.log"

cd /d "%RECEIVER_DIR%"
echo [%date% %time%] Starting PasswallReceiver > "%LOG_FILE%"
PasswallReceiver.exe >> "%LOG_FILE%" 2>&1
