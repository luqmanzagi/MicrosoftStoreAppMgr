param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="The winget package ID to install")]
    [string]$Id
)

# Determine log file path: {parentDir}/logs/install/{date}.log
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

# Create log directory structure
$logDir = Join-Path $parentDir 'logs\install'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Use current date as filename (YYYY-MM-DD.log)
$dateStr = Get-Date -Format 'yyyy-MM-dd'
$logPath = Join-Path $logDir "$dateStr.log"

Write-Host "Installing: $Id"
$startTime = Get-Date

# Run install and capture output + exit code
$outputLines = @()
$errorText = $null
try {
    $null = & winget install --id $Id --accept-source-agreements --accept-package-agreements 2>&1 |
        Tee-Object -Variable outputLines
}
catch {
    $errorText = $_.Exception.Message
}
finally {
    $endTime = Get-Date
    $elapsed = New-TimeSpan -Start $startTime -End $endTime
}

$text = ($outputLines -join "`n")
if ($errorText) { $text = $text + "`n" + $errorText }
$code = $LASTEXITCODE

# Status classification
$status = "failure"
if ($text -match 'Found an existing package already installed' -or
    $text -match 'No available upgrade found' -or
    $text -match 'No newer package versions are available') {
    $status = "exist"
}
elseif (($code -eq 0) -and (
    $text -match 'Successfully installed' -or
    $text -match 'Installation completed' -or
    $text -match 'Succeeded'
)) {
    $status = "success"
}
elseif ($text -match 'No package found matching input criteria' -or
        $text -match 'No available package found matching input criteria' -or
        $text -match 'Package not found') {
    $status = "failure"
}
elseif ($code -eq 0) {
    $status = "success"
}

# Extract "Name [ID]" if possible
$label = $Id
$m = [regex]::Match($text, '(?i)Found\s+(.+?\[[^\]]+\])')
if ($m.Success) {
    $label = $m.Groups[1].Value.Trim()
} else {
    $m2 = [regex]::Match($text, '(?im)^\s*(.+?\[[^\]]+\])\s*$')
    if ($m2.Success) {
        $label = $m2.Groups[1].Value.Trim()
    } else {
        # Fallback: query Winget for the header without disturbing our saved exit code
        try {
            $show = & winget show --id $Id --exact 2>$null
            $m3 = [regex]::Match(($show -join "`n"), '(?i)Found\s+(.+?\[[^\]]+\])')
            if ($m3.Success) { $label = $m3.Groups[1].Value.Trim() }
        } catch { }
    }
}

# Build log entry
$logEntry = "Install {0} took {1} {2}" -f $label, $elapsed.ToString("mm\:ss"), $status

# If installation failed, append error information
if ($status -eq "failure") {
    if ($errorText) {
        $logEntry += " - Error: $errorText"
    } elseif ($text) {
        # Extract key error messages from output (first few lines that look like errors)
        $errorLines = ($text -split "`n" | Where-Object { 
            $_ -match '(?i)(error|failed|exception|not found|unable)' -and 
            $_.Trim().Length -gt 0 
        } | Select-Object -First 3)
        if ($errorLines) {
            $errorSummary = ($errorLines -join "; ").Trim()
            # Limit error text length to avoid overly long log entries
            if ($errorSummary.Length -gt 200) {
                $errorSummary = $errorSummary.Substring(0, 197) + "..."
            }
            $logEntry += " - Error: $errorSummary"
        }
    }
}

Add-Content -Path $logPath -Value $logEntry

# Report result
switch ($status) {
    "success" { Write-Host "Successfully installed $label" -ForegroundColor Green }
    "exist"   { Write-Host "Already installed: $label" -ForegroundColor Yellow }
    "failure" { Write-Host "Failed to install: $label" -ForegroundColor Red }
}
