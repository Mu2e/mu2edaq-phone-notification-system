<#
.SYNOPSIS
    Start the Mu2e DAQ notification server on Windows (PowerShell port of
    start-mu2edaq-notify-server.sh). Bootstraps the venv first if needed.
    Extra arguments pass through to mu2edaq-notify-server, e.g.:
        .\start-mu2edaq-notify-server.ps1 --port 9000 --no-zmq
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ServerArgs
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here

$PidFile = 'data\notify-server.pid'
$LogFile = 'data\notify-server.log'
$ServerExe = Join-Path $Here 'venv\Scripts\mu2edaq-notify-server.exe'

if (-not (Test-Path $ServerExe)) {
    & (Join-Path $Here 'bootstrap.ps1')
}

function Test-ProcessAlive([int]$ProcId) {
    return [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue)
}

if (Test-Path $PidFile) {
    $existing = (Get-Content $PidFile -Raw).Trim()
    if ($existing -match '^\d+$' -and (Test-ProcessAlive ([int]$existing))) {
        Write-Host "Server already running (pid $existing)."
        exit 0
    }
}

New-Item -ItemType Directory -Force -Path data | Out-Null
$Config = if ($env:MU2EDAQ_NOTIFY_CONFIG) { $env:MU2EDAQ_NOTIFY_CONFIG } else { 'config\notify-server.yaml' }

$argList = @('--config', $Config)
if ($ServerArgs) { $argList += $ServerArgs }
$proc = Start-Process -FilePath $ServerExe -ArgumentList $argList -WorkingDirectory $Here `
    -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" `
    -WindowStyle Hidden -PassThru
Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
Start-Sleep -Seconds 1
if (Test-ProcessAlive $proc.Id) {
    Write-Host "Started mu2edaq-notify-server (pid $($proc.Id), log $LogFile)."
} else {
    Write-Error "Server failed to start; last log lines:"
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 20 | Write-Host }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    exit 1
}
