[CmdletBinding()]
param(
    [string]$Version = '0.1.5',
    [string]$Runtime = 'win-x64',
    [string]$PublishDir = '',
    [string]$OutputDir = '',
    [string]$InnoSetupCompiler = '',
    [switch]$SkipInstaller
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$winRoot = Split-Path -Parent $scriptDir

if (-not $PublishDir) {
    $PublishDir = Join-Path $winRoot (Join-Path 'publish' $Runtime)
}
if (-not [System.IO.Path]::IsPathRooted($PublishDir)) {
    $PublishDir = Join-Path $winRoot $PublishDir
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $winRoot (Join-Path 'dist' 'artifacts')
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $winRoot $OutputDir
}

$Version = $Version.TrimStart('v', 'V')
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'Version is empty.'
}

$archLabel = 'x64'
if ($Runtime -match 'arm64') { $archLabel = 'arm64' }
elseif ($Runtime -match 'x86') { $archLabel = 'x86' }

$exe = Join-Path $PublishDir 'PixShell.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Publish output missing PixShell.exe: $PublishDir"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$zipName = "PixShell-$Version-win-$archLabel.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Write-Host "[INFO] Creating zip: $zipPath"
# Compress-Archive paths are relative content names from the publish root
Push-Location $PublishDir
try {
    Compress-Archive -Path * -DestinationPath $zipPath -CompressionLevel Optimal -Force
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Failed to create zip: $zipPath"
}
Write-Host "[OK] Zip: $zipPath"

$setupPath = $null
if (-not $SkipInstaller) {
    function Find-Iscc {
        param([string]$Hint)
        if ($Hint -and (Test-Path -LiteralPath $Hint)) { return $Hint }
        if ($env:INNO_SETUP_ISCC -and (Test-Path -LiteralPath $env:INNO_SETUP_ISCC)) {
            return $env:INNO_SETUP_ISCC
        }
        $cmd = Get-Command iscc -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $candidates = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
            "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe"
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path -LiteralPath $c)) { return $c }
        }
        return $null
    }

    $iscc = Find-Iscc -Hint $InnoSetupCompiler
    if (-not $iscc) {
        throw @'
Inno Setup compiler (ISCC.exe) not found.
Install Inno Setup 6, or set INNO_SETUP_ISCC / pass -InnoSetupCompiler.
Fallback: zip artifact is still produced; setup.exe requires ISCC.
'@
    }

    $iss = Join-Path $scriptDir 'PixShell.iss'
    if (-not (Test-Path -LiteralPath $iss)) {
        throw "Missing Inno script: $iss"
    }

    # ISCC expects OutputDir to exist
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # Resolve absolute paths for defines (Inno handles both, abs is safer in CI)
    $publishAbs = (Resolve-Path -LiteralPath $PublishDir).Path
    $outputAbs = (Resolve-Path -LiteralPath $OutputDir).Path

    Write-Host "[INFO] Compiling installer with: $iscc"
    & $iscc `
        "/DMyAppVersion=$Version" `
        "/DPublishDir=$publishAbs" `
        "/DOutputDir=$outputAbs" `
        "/DArchLabel=$archLabel" `
        $iss
    if ($LASTEXITCODE -ne 0) {
        throw "ISCC failed with exit code $LASTEXITCODE"
    }

    $setupName = "PixShell-$Version-win-$archLabel-setup.exe"
    $setupPath = Join-Path $OutputDir $setupName
    if (-not (Test-Path -LiteralPath $setupPath)) {
        # Inno may have written with slight naming differences; pick newest setup.exe
        $found = Get-ChildItem -LiteralPath $OutputDir -Filter '*-setup.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) {
            if ($found.Name -ne $setupName) {
                Move-Item -LiteralPath $found.FullName -Destination $setupPath -Force
            }
        }
    }
    if (-not (Test-Path -LiteralPath $setupPath)) {
        throw "Installer not found after ISCC: $setupPath"
    }
    Write-Host "[OK] Setup: $setupPath"
} else {
    Write-Host '[INFO] SkipInstaller set; only zip produced.'
}

Write-Host '[OK] Windows packaging complete.'
[pscustomobject]@{
    Version = $Version
    Zip = $zipPath
    Setup = $setupPath
} | Format-List
