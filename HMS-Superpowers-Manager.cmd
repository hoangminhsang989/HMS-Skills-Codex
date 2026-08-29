@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manager\HmsSuperpowersManager.ps1"
if errorlevel 1 (
  echo.
  echo HMS Superpowers Manager exited with an error.
  pause
)
