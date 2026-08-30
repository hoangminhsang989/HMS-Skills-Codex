@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manager\HmsModelSettings.ps1"
if errorlevel 1 (
  echo.
  echo HMS Model Settings exited with an error.
  pause
)
