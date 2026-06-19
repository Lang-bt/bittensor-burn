# Install bittensor-burn-message from wheels in this folder (no dist/ subfolder needed).
$ErrorActionPreference = "Stop"
$WheelDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Py = Get-Command python -ErrorAction SilentlyContinue
if (-not $Py) {
    $Py = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $Py) {
    Write-Error "Python not found. Install Python 3.9+ and ensure it is on PATH."
}

Write-Host "Installing from: $WheelDir"
& $Py.Source -m pip install bittensor-burn-message --no-index --find-links $WheelDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Done. Try: bittensor-burn-message install --help"
