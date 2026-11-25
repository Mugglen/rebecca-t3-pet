@echo off
setlocal
if /I not "%~d0"=="D:" (
  echo Rebecca must run from a D: project directory.
  pause
  exit /b 1
)
if not exist "%~dp0tmp" mkdir "%~dp0tmp"
set "TEMP=%~dp0tmp"
set "TMP=%TEMP%"
set "PSModuleAnalysisCachePath=%TEMP%\PowerShellModuleCache"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\Start-Rebecca.ps1" -Mode live
