# Invoke-TestPy.ps1
# For each app in result/app_1.json:
#   1. Install it  (same logic as scripts/install.ps1)
#   2. Immediately uninstall it if it was NOT already installed ('exist')
#      using uni4.py
# Then move on to the next app.

# -- Path setup --
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$jsonPath    = Join-Path $parentDir 'result\app_1.json'
$uninstallPy = Join-Path $parentDir 'uni4.py'

# Validate required files
if (-not (Test-Path $jsonPath)) {
    Write-Error "JSON file not found: $jsonPath"
    exit 1
}
if (-not (Test-Path $uninstallPy)) {
    Write-Error "Uninstall script not found: $uninstallPy"
    exit 1
}

# -- Logging --
$logDir = Join-Path $parentDir 'logs\test'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$dateStr = Get-Date -Format 'yyyy-MM-dd-HH'
$logPath = Join-Path $logDir "$dateStr.log"

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logPath -Value $Message
    Write-Host $Message
}

# -- Load apps from JSON --
$jsonContent = Get-Content $jsonPath -Raw | ConvertFrom-Json
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

Write-Log "=== Invoke-TestPy started: $(Get-Date) ==="
Write-Log "Loaded $($apps.Count) app(s) from $jsonPath"

# Counters for final summary
$totalExist            = 0
$totalSuccess          = 0
$totalFailure          = 0
$totalUninstallSuccess = 0
$totalUninstallFailure = 0
$totalSkipped          = 0

# ================================================================
# MAIN LOOP - Install then Uninstall per app
# ================================================================
for ($i = 0; $i -lt $apps.Count; $i++) {
    $app   = $apps[$i]
    $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

    Write-Log ""
    Write-Log "------------------------------------------------"
    Write-Log "[$($i + 1)/$($apps.Count)] $label"
    Write-Log "------------------------------------------------"

    # -- STEP 1: INSTALL --
    Write-Host "  Installing..."

    $startTime   = Get-Date
    $outputLines = @()
    $errorText   = $null

    try {
        $null = & winget install --id $app.ID --accept-source-agreements --accept-package-agreements 2>&1 |
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
    if ($errorText) { $text = "$text`n$errorText" }
    $code = $LASTEXITCODE

    # Status classification (mirrors install.ps1)
    $status = 'failure'
    if ($text -match 'Found an existing package already installed' -or
        $text -match 'No available upgrade found' -or
        $text -match 'No newer package versions are available') {
        $status = 'exist'
    }
    elseif (($code -eq 0) -and (
        $text -match 'Successfully installed' -or
        $text -match 'Installation completed' -or
        $text -match 'Succeeded'
    )) {
        $status = 'success'
    }
    elseif ($text -match 'No package found matching input criteria' -or
            $text -match 'No available package found matching input criteria' -or
            $text -match 'Package not found') {
        $status = 'failure'
    }
    elseif ($code -eq 0) {
        $status = 'success'
    }

    # Resolve friendly label (mirrors install.ps1)
    $m = [regex]::Match($text, '(?i)Found\s+(.+?\[[^\]]+\])')
    if ($m.Success) { $label = $m.Groups[1].Value.Trim() }

    $installLog = "  Install {0} took {1} => {2}" -f $label, $elapsed.ToString("mm\:ss"), $status

    # Append error detail on failure
    if ($status -eq 'failure') {
        $totalFailure++
        if ($errorText) {
            $installLog += " - Error: $errorText"
        } elseif ($text) {
            $errLines = ($text -split "`n" |
                Where-Object { $_ -match '(?i)(error|failed|exception|not found|unable)' -and $_.Trim().Length -gt 0 } |
                Select-Object -First 3)
            if ($errLines) {
                $errSummary = ($errLines -join '; ').Trim()
                if ($errSummary.Length -gt 200) { $errSummary = $errSummary.Substring(0, 197) + '...' }
                $installLog += " - Error: $errSummary"
            }
        }
    } elseif ($status -eq 'exist') {
        $totalExist++
    } else {
        $totalSuccess++
    }

    Write-Log $installLog

    # -- STEP 2: UNINSTALL (only if NOT 'exist') --
    if ($status -eq 'exist') {
        Write-Log "  Skipping uninstall - app already existed."
        $totalSkipped++
        continue
    }

    Write-Host "  Uninstalling..."

    $startTime = Get-Date
    $uniOutput = $null
    $uniExit   = 1

    try {
        $uniOutput = & python $uninstallPy $app.ID 2>&1
        $uniExit   = $LASTEXITCODE
    }
    catch {
        $uniOutput = $_.Exception.Message
        $uniExit   = 1
    }
    finally {
        $endTime = Get-Date
        $elapsed = New-TimeSpan -Start $startTime -End $endTime
    }

    $uniStatus = if ($uniExit -eq 0) { 'success' } else { 'failure' }
    if ($uniStatus -eq 'success') { $totalUninstallSuccess++ } else { $totalUninstallFailure++ }

    $uninstallLog = "  Uninstall {0} took {1} => {2}" -f $label, $elapsed.ToString("mm\:ss"), $uniStatus
    Write-Log $uninstallLog
}

# -- Summary --
Write-Log ""
Write-Log "================================================"
Write-Log "SUMMARY"
Write-Log "================================================"
Write-Log "Total apps processed : $($apps.Count)"
Write-Log "Install   - exist: $totalExist  success: $totalSuccess  failure: $totalFailure"
Write-Log "Uninstall - success: $totalUninstallSuccess  failure: $totalUninstallFailure  skipped (exist): $totalSkipped"
Write-Log "=== Invoke-TestPy finished: $(Get-Date) ==="
Write-Host ""
Write-Host "Log saved to: $logPath"
