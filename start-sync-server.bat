@echo off
setlocal EnableExtensions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -Component server
if errorlevel 1 (
  echo.
  echo Daily Assistant sync-server could not be started. See the message above.
  pause
  exit /b 1
)
exit /b 0

