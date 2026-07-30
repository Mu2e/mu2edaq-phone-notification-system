<#
.SYNOPSIS
    Stop the Mu2e DAQ notification server cleanly on Windows (PowerShell port of
    stop-mu2edaq-notify-server.sh): graceful close, then a forced kill after a
    grace period, and clean up the pid file.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here

$PidFile = 'data\notify-server.pid'

function Test-ProcessAlive([int]$ProcId) {
    return [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue)
}

if (-not (Test-Path $PidFile)) {
    Write-Host 'No pid file; server not running (or started by hand).'
    exit 0
}

$ProcId = [int]((Get-Content $PidFile -Raw).Trim())
if (-not (Test-ProcessAlive $ProcId)) {
    Write-Host 'Stale pid file removed.'
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$proc = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
if ($proc) { $proc.CloseMainWindow() | Out-Null }
for ($i = 0; $i -lt 10; $i++) {
    if (-not (Test-ProcessAlive $ProcId)) {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host 'Server stopped.'
        exit 0
    }
    Start-Sleep -Milliseconds 500
}

Write-Host 'Server did not exit; forcing.'
Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
Write-Host 'Server killed.'
