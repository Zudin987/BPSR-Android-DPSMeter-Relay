@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0scripts\LaunchManager.ps1" (
    echo ERROR: scripts\LaunchManager.ps1 was not found.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\LaunchManager.ps1"
