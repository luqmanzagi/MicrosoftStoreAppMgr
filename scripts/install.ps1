# Determine log file path: {parentDir}/log/install/{date}.log
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

# Array to track successfully installed apps
$successfulInstalls = @()

foreach ($app in $apps) {
    # Display name and ID if available, otherwise just ID
    if ($app.Name) {
        Write-Host "Installing: $($app.Name) ($($app.ID))"
    } else {
        Write-Host "Installing: $($app.ID)"
    }
    $startTime = Get-Date

    # Run install and capture output + exit code
    $outputLines = @()
    $errorText = $null
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
    if ($app.Name) {
        $label = "$($app.Name) [$($app.ID)]"
    } else {
        $label = $app.ID
    }
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
                $show = & winget show --id $app.ID --exact 2>$null
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
    
    # Track successful installations
    if ($status -eq "success") {
        $successfulInstalls += [PSCustomObject]@{
            itemID = $app.ID
        }
    }
}

# Create output JSON file for successfully installed apps
if ($successfulInstalls.Count -gt 0) {
    # Determine output filename based on input filename
    $inputFileName = Split-Path -Leaf $filePath
    $inputNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($inputFileName)
    $outputFileName = "uninstall_$inputNameWithoutExt.json"
    $outputPath = Join-Path (Split-Path -Parent $filePath) $outputFileName
    
    # Convert to JSON and save
    $jsonOutput = $successfulInstalls | ConvertTo-Json
    $jsonOutput | Out-File -FilePath $outputPath -Encoding UTF8
    
    Write-Host "`nSuccessfully installed $($successfulInstalls.Count) app(s). Output saved to: $outputPath"
} else {
    Write-Host "`nNo apps were successfully installed."
}


