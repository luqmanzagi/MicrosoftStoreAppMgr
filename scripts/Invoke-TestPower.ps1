# Invoke-TestPower.ps1
# For each app in result/app_1.json:
#   1. Install it  (same logic as scripts/install.ps1)
#   2. Immediately uninstall it if it was NOT already installed ('exist')
#      using scripts/Remove-SingleApplication.ps1
# Then move on to the next app.

# -- Path setup --
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$jsonPath          = Join-Path $parentDir 'results\app_2026-08-19.json'
$uninstallScript   = Join-Path $scriptDir 'Remove-SingleApplication.new.ps1'

# Validate required files
if (-not (Test-Path $jsonPath)) {
    Write-Error "JSON file not found: $jsonPath"
    exit 1
}
if (-not (Test-Path $uninstallScript)) {
    Write-Error "Uninstall script not found: $uninstallScript"
    exit 1
}

# -- Logging --
$logDir = Join-Path $parentDir 'logs\test'
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

Write-Log "=== Invoke-TestPower started: $(Get-Date) ==="
Write-Log "Loaded $($apps.Count) app(s) from $jsonPath"

# Counters for final summary
$totalExist   = 0
$totalSuccess = 0
$totalFailure = 0
$totalUninstallSuccess = 0
$totalUninstallFailure = 0
$totalSkipped = 0

# Uninstall method counters (attempts / success / failure)
$uniMethodNames = @(
    'Remove-AppxPackage',
    'QuietUninstallString',
    'msiexec',
    'UninstallString',
    'winget',
    'not found',
    'no uninstall string',
    'no display name',
    'unknown'
)
$uniMethodTotal   = @{}
$uniMethodSuccess = @{}
$uniMethodFailure = @{}
foreach ($name in $uniMethodNames) {
    $uniMethodTotal[$name]   = 0
    $uniMethodSuccess[$name] = 0
    $uniMethodFailure[$name] = 0
}

function Get-UninstallMethod {
    param([string]$Text)
    $m = [regex]::Match($Text, 'UNINSTALL_METHOD=([^\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    if ($Text -match 'Using Remove-AppxPackage') { return 'Remove-AppxPackage' }
    if ($Text -match 'Using QuietUninstallString:.*msiexec') { return 'msiexec' }
    if ($Text -match 'Using QuietUninstallString') { return 'QuietUninstallString' }
    if ($Text -match 'Using UninstallString') { return 'UninstallString' }
    if ($Text -match 'Using winget uninstall' -or $Text -match 'Falling back to winget') { return 'winget' }
    if ($Text -match 'No application found matching') { return 'not found' }
    if ($Text -match 'No uninstall string available') { return 'no uninstall string' }
    return 'unknown'
}

function Add-UninstallMethodCount {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Status
    )
    if (-not $uniMethodTotal.ContainsKey($Method)) {
        $uniMethodTotal[$Method]   = 0
        $uniMethodSuccess[$Method] = 0
        $uniMethodFailure[$Method] = 0
        $script:uniMethodNames += $Method
    }
    $uniMethodTotal[$Method] = $uniMethodTotal[$Method] + 1
    if ($Status -eq 'success') {
        $uniMethodSuccess[$Method] = $uniMethodSuccess[$Method] + 1
    } else {
        $uniMethodFailure[$Method] = $uniMethodFailure[$Method] + 1
    }
}

# ================================================================
# MAIN LOOP - Install then Uninstall per app
# ================================================================
for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

    Write-Log ""
    Write-Log "------------------------------------------------"
    Write-Log "[$($i + 1)/$($apps.Count)] $label"
    Write-Log "------------------------------------------------"

    # -- STEP 1: INSTALL (same approach as scripts/install.ps1) --
    Write-Host "  Installing..."

    $startTime   = Get-Date
    $outputLines  = @()
    $errorText    = $null

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

    Write-Host "  Uninstalling via Remove-SingleApplication..."

    # Remove-SingleApplication.ps1 expects -ApplicationName (display name)
    $appName = $app.Name
    if (-not $appName) {
        Write-Log "  Skipping uninstall - no display name available for registry lookup."
        $totalUninstallFailure++
        Add-UninstallMethodCount -Method 'no display name' -Status 'failure'
        continue
    }

    $startTime = Get-Date
    $uniOutput = $null
    $uniExit   = 0

    try {
        $uniOutput = & $uninstallScript -ApplicationName $appName -Id $app.ID 2>&1
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

    # Check for errors in the output as well (Remove-SingleApplication uses Write-Error + exit 1)
    $uniText = ($uniOutput | Out-String)
    $uniMethod = Get-UninstallMethod -Text $uniText
    if ($uniExit -ne 0) {
        $uniStatus = 'failure'
    } elseif ($uniMethod -eq 'winget') {
        $uniStatus = 'success'
    } elseif ($uniText -match '(?i)(error|not found|no application found)') {
        $uniStatus = 'failure'
    } else {
        $uniStatus = 'success'
    }

    if ($uniStatus -eq 'success') { $totalUninstallSuccess++ } else { $totalUninstallFailure++ }

    Add-UninstallMethodCount -Method $uniMethod -Status $uniStatus

    $uninstallLog = "  Uninstall {0} took {1} => {2} ({3})" -f $label, $elapsed.ToString("mm\:ss"), $uniStatus, $uniMethod
    if ($uniStatus -eq 'failure' -and $uniText) {
        $errDetail = ($uniText -split "`n" |
            Where-Object {
                $_.Trim().Length -gt 0 -and
                $_ -match '(?i)(failed|exit code|no installed package|no application|not found|error)' -and
                $_ -notmatch 'CategoryInfo|FullyQualifiedErrorId|WriteErrorException'
            } |
            Select-Object -First 2) -join '; '
        if ($errDetail) {
            if ($errDetail.Length -gt 200) { $errDetail = $errDetail.Substring(0, 197) + '...' }
            $uninstallLog += " - $errDetail"
        }
    }
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
Write-Log "Uninstall methods:"
foreach ($name in $uniMethodNames) {
    $n = $uniMethodTotal[$name]
    if ($n -eq 0 -and $name -eq 'unknown') { continue }
    Write-Log ("  {0,-22} : {1}  (success: {2}  failure: {3})" -f $name, $n, $uniMethodSuccess[$name], $uniMethodFailure[$name])
}
Write-Log "=== Invoke-TestPower finished: $(Get-Date) ==="
Write-Host ""
Write-Host "Log saved to: $logPath"
