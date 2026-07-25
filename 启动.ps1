# PixShell launcher (Windows double-click)
# Works even when macOS Claude session cannot chmod .command files.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

Write-Host "=========================================="
Write-Host "  PIXSHELL"
Write-Host "=========================================="
Write-Host "Dir: $Root"
Write-Host ""

function Find-Node {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    "$env:ProgramFiles\nodejs\node.exe",
    "${env:ProgramFiles(x86)}\nodejs\node.exe",
    "$env:LOCALAPPDATA\Programs\node\node.exe"
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  return $null
}

$node = Find-Node
if (-not $node) {
  Write-Host "[ERROR] node not found. Install Node.js 20+ from https://nodejs.org/"
  Read-Host "Press Enter to exit"
  exit 1
}

Write-Host "[1/3] Node: $(& $node -v)"

$needInstall = -not (Test-Path "node_modules\electron") -or -not (Test-Path "node_modules\ssh2") -or -not (Test-Path "node_modules\@xterm\xterm")
if ($needInstall) {
  Write-Host "[2/3] npm install (first run, may take a while)..."
  npm install
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] npm install failed"
    Read-Host "Press Enter to exit"
    exit 1
  }
} else {
  Write-Host "[2/3] dependencies ok"
}

Write-Host "[3/3] starting Electron..."
$env:ELECTRON_DISABLE_SECURITY_WARNINGS = "1"
$electron = Join-Path $Root "node_modules\electron\cli.js"
if (-not (Test-Path $electron)) {
  Write-Host "[ERROR] electron missing after install"
  Read-Host "Press Enter to exit"
  exit 1
}

& $node $electron "packages\app\main\main.js"
if ($LASTEXITCODE -ne 0) {
  Write-Host "Electron exited with code $LASTEXITCODE"
  Read-Host "Press Enter to exit"
}
