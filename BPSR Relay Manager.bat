@echo off
setlocal
cd /d "%~dp0"

set "EXE=%~dp0.build\native\BPSR Relay Manager.exe"
if not exist "%~dp0scripts\BuildNativeManager.ps1" (
    echo ERROR: scripts\BuildNativeManager.ps1 was not found.
    pause
    exit /b 1
)

echo Building native BPSR Relay Manager...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\BuildNativeManager.ps1" -OutputPath "%EXE%"
if errorlevel 1 (
    echo.
    echo ERROR: Native manager build failed.
    pause
    exit /b 1
)

start "" "%EXE%"
