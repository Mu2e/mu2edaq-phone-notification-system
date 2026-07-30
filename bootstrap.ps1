<#
.SYNOPSIS
    Bootstrap the mu2edaq-phone-notification-system Python environment on Windows
    (PowerShell port of bootstrap.sh). Creates venv\, installs dependencies and
    the package (editable). Safe to re-run.

.DESCRIPTION
    The C++ notify library is built separately with CMake (not on this host
    without a compiler). The AWS proxy/chain scripts under scripts\ are Linux
    cloud/ssh deploy helpers and are not ported.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here

# Prefer 'python'; fall back to the py launcher ('python3' on Windows is the
# Microsoft Store alias stub, so it is not used here).
$Python = $env:PYTHON
if (-not $Python) {
    if (Get-Command python -ErrorAction SilentlyContinue) { $Python = 'python' }
    elseif (Get-Command py -ErrorAction SilentlyContinue) { $Python = 'py' }
    else { Write-Error 'Python 3.9+ not found on PATH. Install it first.'; exit 1 }
}

if (-not (Test-Path 'venv')) {
    Write-Host 'Creating virtual environment in venv\ ...'
    & $Python -m venv venv
}

$VenvPy = Join-Path $Here 'venv\Scripts\python.exe'
& $VenvPy -m pip install --upgrade pip | Out-Null
& $VenvPy -m pip install -r requirements.txt
& $VenvPy -m pip install -e .

# Install the discovery sibling if checked out next to us.
if (Test-Path '..\mu2edaq-discovery') {
    & $VenvPy -m pip install -e '..\mu2edaq-discovery'
}

New-Item -ItemType Directory -Force -Path data, core | Out-Null

Write-Host ''
Write-Host 'Bootstrap complete.'
Write-Host '  Run the server:  .\start-mu2edaq-notify-server.ps1'
Write-Host '  Run the tests:   venv\Scripts\pytest.exe'
Write-Host '  Build the C++ library:  cmake -S . -B build && cmake --build build'
