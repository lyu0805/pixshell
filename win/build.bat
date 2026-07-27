@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
)
exit /b %ERRORLEVEL%
