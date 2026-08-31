# Determine log file path: {parentDir}/log/uninstall/{date}.log
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

# Ask the user to provide a file path interactively
$filePath = Read-Host "Enter the path to your file (text file with one app ID per line, or JSON file)"

if (-not (Test-Path $filePath)) {
    Write-Error "File not found: $filePath"
    exit 1
}

# Determine if file is JSON (by extension or content)
$isJson = $filePath -match '\.json$'
$apps = @()

if ($isJson) {
    # Parse JSON and extract both itemName and itemID
    try {
        $jsonContent = Get-Content $filePath -Raw | ConvertFrom-Json
        if ($jsonContent -is [Array]) {
            # Array of objects - store objects with name and ID
            $apps = $jsonContent | ForEach-Object { 
                [PSCustomObject]@{
                    Name = $_.itemName
                    ID = $_.itemID
                }
            }
        } elseif ($jsonContent.itemID) {
            # Single object
            $apps = @([PSCustomObject]@{
                Name = $jsonContent.itemName
                ID = $jsonContent.itemID
            })
        } else {
            Write-Error "JSON file does not contain 'itemID' fields"
            exit 1
        }
        Write-Host "Loaded $($apps.Count) apps from JSON file"
    }
    catch {
        Write-Error "Failed to parse JSON file: $_"
        exit 1
    }
} else {
    # Read all non-empty lines (trim whitespace) - text file format
    # For text files, store as objects with only ID (no name available)
    $apps = Get-Content $filePath | Where-Object { $_.Trim() -ne '' } | ForEach-Object {
        [PSCustomObject]@{
            Name = $null
            ID = $_.Trim()
        }
    }
    Write-Host "Loaded $($apps.Count) app IDs from text file"
}

foreach ($app in $apps) {
    $startTime = Get-Date
    # Display name and ID if available, otherwise just ID
    if ($app.Name) {
        Write-Host "Uninstalling: $($app.Name) ($($app.ID))"
        $label = "$($app.Name) [$($app.ID)]"
    } else {
        Write-Host "Uninstalling: $($app.ID)"
        $label = $app.ID
    }
    winget uninstall --id $app.ID
    $stopTime = Get-Date
    $elapsedTime = New-Timespan -Start $startTime -End $stopTime
    Add-Content -Path $logPath -Value ("Uninstallation on {0} took {1}" -f $label, $elapsedTime.ToString("mm\:ss"))
}

