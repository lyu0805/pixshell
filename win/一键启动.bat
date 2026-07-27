@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Action run -Configuration Debug -Runtime win-x64
exit /b %ERRORLEVEL%
