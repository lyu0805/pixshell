[CmdletBinding()]
param(
    [ValidateSet('build', 'publish', 'run', 'clean')]
    [string]$Action = 'publish',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$Runtime = 'win-x64',

    [switch]$SelfContained,

    [string]$OutputDir = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$project = Join-Path $scriptDir 'PixShell.csproj'
$framework = 'net9.0-windows'

function Fail($message) {
    Write-Host "[ERROR] $message" -ForegroundColor Red
    exit 1
}

function Find-Dotnet {
    if ($env:PIXSHELL_DOTNET) {
        if (Test-Path -LiteralPath $env:PIXSHELL_DOTNET) {
            return $env:PIXSHELL_DOTNET
        }
        Fail "PIXSHELL_DOTNET is set but the file does not exist: $env:PIXSHELL_DOTNET"
    }

    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    Fail 'dotnet was not found in PATH. Install .NET SDK 9 or set PIXSHELL_DOTNET to dotnet.exe.'
}

function Invoke-Dotnet {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    Write-Host "> dotnet $($Arguments -join ' ')"
    & $dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Test-SourceAssets {
    $required = @(
        'web\terminal.html',
        'web\xterm.js',
        'web\xterm.css',
        'web\addon-fit.js'
    )

    foreach ($item in $required) {
        $path = Join-Path $scriptDir $item
        if (-not (Test-Path -LiteralPath $path)) {
            Fail "Required web asset is missing from source: $item"
        }
    }
}

function Test-PublishOutput($publishDir) {
    $required = @(
        'PixShell.exe',
        'web\terminal.html',
        'web\xterm.js',
        'web\xterm.css',
        'web\addon-fit.js'
    )

    foreach ($item in $required) {
        $path = Join-Path $publishDir $item
        if (-not (Test-Path -LiteralPath $path)) {
            Fail "Required publish file is missing: $item"
        }
    }

    $loader = Get-ChildItem -LiteralPath $publishDir -Filter 'WebView2Loader.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $loader) {
        Fail 'WebView2Loader.dll was not copied to publish output.'
    }

    Write-Host '[OK] Publish output contains PixShell.exe, web assets, and WebView2Loader.dll.' -ForegroundColor Green
    Write-Host '[INFO] WebView2 Evergreen Runtime is not bundled; target machines must have it installed.'
}

if (-not (Test-Path -LiteralPath $project)) {
    Fail "Project file not found: $project"
}

Test-SourceAssets
$dotnet = Find-Dotnet
Write-Host "[INFO] dotnet: $dotnet"
& $dotnet --version
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$selfContainedValue = 'false'
if ($SelfContained) {
    $selfContainedValue = 'true'
}

if ($Action -eq 'clean') {
    $paths = @(
        (Join-Path $scriptDir 'bin'),
        (Join-Path $scriptDir 'obj'),
        (Join-Path $scriptDir 'publish')
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Write-Host "[INFO] Removing $path"
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    Write-Host '[OK] Clean complete.' -ForegroundColor Green
    exit 0
}

try {
    Get-Process -Name 'PixShell' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
} catch {
    Write-Host '[WARN] Could not stop an existing PixShell process; continuing.' -ForegroundColor Yellow
}

Invoke-Dotnet @('restore', $project, '-r', $Runtime)

if ($Action -eq 'build' -or $Action -eq 'run') {
    Invoke-Dotnet @('build', $project, '-c', $Configuration, '-r', $Runtime, '--self-contained', $selfContainedValue, '-v', 'minimal', '-nologo', '--no-restore')
    $exe = Join-Path $scriptDir (Join-Path 'bin' (Join-Path $Configuration (Join-Path $framework (Join-Path $Runtime 'PixShell.exe'))))
    if (-not (Test-Path -LiteralPath $exe)) {
        Fail "Build succeeded but executable was not found: $exe"
    }
    Write-Host "[OK] Build output: $exe" -ForegroundColor Green

    if ($Action -eq 'run') {
        Write-Host '[INFO] Starting PixShell...'
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    }
    exit 0
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $scriptDir (Join-Path 'publish' $Runtime)
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $scriptDir $OutputDir
}

if (Test-Path -LiteralPath $OutputDir) {
    Write-Host "[INFO] Removing previous publish output: $OutputDir"
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Invoke-Dotnet @('publish', $project, '-c', $Configuration, '-r', $Runtime, '--self-contained', $selfContainedValue, '-o', $OutputDir, '-v', 'minimal', '-nologo', '--no-restore')
Test-PublishOutput $OutputDir
Write-Host "[OK] Publish output: $OutputDir" -ForegroundColor Green
