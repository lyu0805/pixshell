@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
cd /d "%~dp0"

set "LOG=%CD%\build.log"

echo === PixShell (Windows) 构建 ===
echo.

rem ---------------------------------------------------------------------------
rem 找 dotnet。
rem
rem 不能只靠 `where dotnet`：装了 .NET 之后没重开窗口，新 PATH 不会进到当前进程；
rem 双击 .bat 继承的是资源管理器启动时的旧环境，于是明明装了却报"没找到"。
rem
rem 注意：这里刻意**不用** for %%p in (...) 那种括号列表 ——
rem %ProgramFiles(x86)% 展开后自带一个 ")"，会被 cmd 当成列表收尾括号把语法拆散，
rem 残片会被当成命令执行（表现就是莫名其妙冒出 AT/Invalid command 之类的报错）。
rem 用子程序逐个探测，值里不出现裸括号，稳。
rem ---------------------------------------------------------------------------
set "DOTNET="

rem 环境变量强制指定优先
if defined PIXSHELL_DOTNET if exist "%PIXSHELL_DOTNET%" set "DOTNET=%PIXSHELL_DOTNET%"

if not defined DOTNET (
    for /f "delims=" %%i in ('where dotnet 2^>nul') do (
        if not defined DOTNET set "DOTNET=%%i"
    )
)

set "PFX86=%ProgramFiles(x86)%"
call :probe "%ProgramFiles%\dotnet\dotnet.exe"
call :probe "%ProgramW6432%\dotnet\dotnet.exe"
call :probe "!PFX86!\dotnet\dotnet.exe"
call :probe "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe"
call :probe "%USERPROFILE%\.dotnet\dotnet.exe"
call :probe "C:\Program Files\dotnet\dotnet.exe"

if not defined DOTNET (
    echo [X] 没找到 dotnet。
    echo.
    echo     装一个 .NET 9 SDK，二选一：
    echo       winget install Microsoft.DotNet.SDK.9
    echo       https://dotnet.microsoft.com/download/dotnet/9.0
    echo.
    echo     如果确信已装：那是 PATH 没生效 —— 重开一个命令行窗口再跑，
    echo     或者把完整路径设进 PIXSHELL_DOTNET 后重跑：
    echo       set PIXSHELL_DOTNET=C:\Program Files\dotnet\dotnet.exe
    echo.
    pause
    exit /b 1
)

echo [i] dotnet = %DOTNET%
for /f "delims=" %%v in ('"%DOTNET%" --version 2^>nul') do echo [i] SDK 版本 = %%v
echo.

rem 构建前关掉在跑的实例，否则 MSB3027/MSB3021 文件占用必失败
taskkill /F /IM PixShell.exe >nul 2>&1
if not errorlevel 1 echo [i] 已关闭正在运行的 PixShell.exe

echo [*] 开始构建（完整日志: build.log）...
echo.
rem 关键：输出既要看得见、也要留一份日志，失败时能回看具体是哪一行报错
"%DOTNET%" build PixShell.csproj -v minimal -nologo > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

type "%LOG%"
echo.

if not "%RC%"=="0" (
    echo ============================================================
    echo [X] 构建失败，退出码 %RC%
    echo ------------------------------------------------------------
    echo 只看报错行：
    findstr /n /i /C:"error " /C:"error CS" /C:"error MSB" "%LOG%"
    echo ============================================================
    echo 完整日志: %LOG%
    pause
    exit /b %RC%
)

echo [OK] 构建成功。
echo     产物: %CD%\bin\Debug\net9.0-windows\PixShell.exe
echo.

if /i "%~1"=="run" (
    echo [*] 启动 ...
    start "" "%CD%\bin\Debug\net9.0-windows\PixShell.exe"
    exit /b 0
)

pause
exit /b 0

rem ---------------------------------------------------------------------------
:probe
rem 已经找到就不再覆盖；%~1 去掉外层引号后判存在
if defined DOTNET exit /b 0
if exist %1 set "DOTNET=%~1"
exit /b 0
