@echo off
REM Double-click launcher for Windows (and for Mac users via terminal if needed)
cd /d "%~dp0"
echo ==========================================
echo   PIXSHELL
echo ==========================================
echo Dir: %CD%
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [ERROR] node not found. Install Node.js 20+
  pause
  exit /b 1
)

echo [1/3] Node:
node -v

if not exist "node_modules\electron" goto INSTALL
if not exist "node_modules\ssh2" goto INSTALL
if not exist "node_modules\@xterm\xterm" goto INSTALL
echo [2/3] dependencies ok
goto START

:INSTALL
echo [2/3] npm install first run (project-local cache)...
if not exist ".npm-cache" mkdir ".npm-cache"
set npm_config_cache=%CD%\.npm-cache
call npm install --cache "%CD%\.npm-cache"
if errorlevel 1 (
  echo [ERROR] npm install failed
  pause
  exit /b 1
)

:START
echo [3/3] starting Electron...
set ELECTRON_DISABLE_SECURITY_WARNINGS=1
if exist "node_modules\electron\cli.js" (
  node node_modules\electron\cli.js packages\app\main\main.js
) else if exist "node_modules\.bin\electron.cmd" (
  call node_modules\.bin\electron.cmd packages\app\main\main.js
) else (
  call npx electron packages\app\main\main.js
)
echo.
pause
