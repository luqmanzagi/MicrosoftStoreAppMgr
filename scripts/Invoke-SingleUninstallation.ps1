param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="The winget package ID to uninstall")]
    [string]$Id
)

# Determine log file path: {parentDir}/logs/uninstall/{date}.log
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

# Create log directory structure
$logDir = Join-Path $parentDir 'logs\uninstall'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Use current date as filename (YYYY-MM-DD.log)
$dateStr = Get-Date -Format 'yyyy-MM-dd'
$logPath = Join-Path $logDir "$dateStr.log"

Write-Host "Uninstalling: $Id"
$startTime = Get-Date

winget uninstall --id $Id

$stopTime = Get-Date
$elapsedTime = New-TimeSpan -Start $startTime -End $stopTime

# Log the result
$label = $Id
Add-Content -Path $logPath -Value ("Uninstallation on {0} took {1}" -f $label, $elapsedTime.ToString("mm\:ss"))

Write-Host "Uninstallation of $Id completed in $($elapsedTime.ToString('mm\:ss'))"
