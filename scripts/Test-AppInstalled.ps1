# Test-AppInstalled.ps1
# For each app in a JSON file (itemID / itemName), run:
#   winget list --id <itemID>
# and report whether the package is currently installed.

param(
    [Parameter(Position = 0)]
    [string]$JsonPath
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

# Fallback JSON if -JsonPath is omitted or empty
if (-not $JsonPath) {
    $JsonPath = Join-Path $parentDir 'results\app_2026-08-19.json'
} elseif (-not [System.IO.Path]::IsPathRooted($JsonPath)) {
    $candidate = Join-Path (Get-Location).Path $JsonPath
    if (Test-Path $candidate) {
        $JsonPath = $candidate
    } else {
        $JsonPath = Join-Path $parentDir $JsonPath
    }
}

if (-not (Test-Path $JsonPath)) {
    Write-Error "JSON file not found: $JsonPath"
    exit 1
}

$logDir = Join-Path $parentDir 'logs\check'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$dateStr = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$logPath = Join-Path $logDir "$dateStr.log"

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logPath -Value $Message
    Write-Host $Message
}

try {
    $jsonContent = Get-Content $JsonPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse JSON file: $_"
    exit 1
}

$apps = @()
if ($jsonContent -is [Array]) {
    $apps = $jsonContent | ForEach-Object {
        [PSCustomObject]@{ Name = $_.itemName; ID = $_.itemID }
    }
} elseif ($jsonContent.itemID) {
    $apps = @([PSCustomObject]@{ Name = $jsonContent.itemName; ID = $jsonContent.itemID })
} else {
    Write-Error "JSON does not contain 'itemID' fields."
    exit 1
}

$apps = @($apps | Where-Object { $_.ID })
if ($apps.Count -eq 0) {
    Write-Error "No itemID values found in $JsonPath"
    exit 1
}

Write-Log "=== Test-AppInstalled started: $(Get-Date) ==="
Write-Log "JSON : $JsonPath"
Write-Log "Apps : $($apps.Count)"

$totalInstalled    = 0
$totalNotInstalled = 0
$totalUnknown      = 0

for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

    Write-Log ""
    Write-Log "------------------------------------------------"
    Write-Log "[$($i + 1)/$($apps.Count)] $label"
    Write-Log "------------------------------------------------"

    $outputLines = @()
    $errorText = $null
    try {
        $null = & winget list $app.ID 2>&1 |
            Tee-Object -Variable outputLines
    } catch {
        $errorText = $_.Exception.Message
    }

    $text = ($outputLines -join "`n")
    if ($errorText) { $text = "$text`n$errorText" }
    $code = $LASTEXITCODE

    $status = 'unknown'
    if ($text -match 'No installed package found matching input criteria' -or
        $text -match 'No packages found matching input criteria') {
        $status = 'not installed'
        $totalNotInstalled++
    } elseif ($code -eq 0 -and $text -match $([regex]::Escape($app.ID))) {
        $status = 'installed'
        $totalInstalled++
    } elseif ($code -eq 0) {
        $status = 'installed'
        $totalInstalled++
    } else {
        $totalUnknown++
    }

    if ($text.Trim()) {
        Write-Log $text.TrimEnd()
    }
    Write-Log "  Result: $status (exit $code)"
}

Write-Log ""
Write-Log "================================================"
Write-Log "SUMMARY"
Write-Log "================================================"
Write-Log "Total apps checked : $($apps.Count)"
Write-Log "Installed          : $totalInstalled"
Write-Log "Not installed      : $totalNotInstalled"
Write-Log "Unknown            : $totalUnknown"
Write-Log "=== Test-AppInstalled finished: $(Get-Date) ==="
Write-Host ""
Write-Host "Log saved to: $logPath"
