# Test-AppInstalled.ps1
# For each app in a JSON file (itemID / itemName), run:
#   winget list --id <itemID> --exact
# then confirm the hit against local Appx / Start Menu / ARP data.
# Winget-only Microsoft Store ghosts are reported as stale, not installed.

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

function Normalize-Name([string]$s) {
    if (-not $s) { return "" }
    ($s.ToLower() -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' '
}

function Get-AppxProductName([string]$packageName) {
    if (-not $packageName) { return "" }
    $dot = $packageName.IndexOf('.')
    if ($dot -ge 0 -and $dot -lt ($packageName.Length - 1)) {
        return $packageName.Substring($dot + 1)
    }
    return $packageName
}

$script:NameQualifiers = @(
    'microsoft', 'user', 'machine', 'x86', 'x64', 'arm64', 'win32', 'win64',
    'setup', 'installer', 'desktop', 'beta', 'preview', 'stable',
    'edition', 'version', 'the', 'for', 'official', 'free', 'plus', 'pro', 'home'
)
$script:CompactSuffixes = @('desktop', 'beta', 'preview', 'uwp', 'client', 'host', 'win32')

function Get-MatchScore([string]$candidate, [string]$needle) {
    if (-not $candidate -or -not $needle) { return 0 }
    $c = Normalize-Name $candidate
    $n = Normalize-Name $needle
    if (-not $c -or -not $n) { return 0 }
    if ($c -eq $n) { return 100 }

    $cc = $c -replace ' ', ''
    $nc = $n -replace ' ', ''
    if ($cc -eq $nc) { return 95 }

    $cTokens = @($c -split ' ')
    $nTokens = @($n -split ' ')
    $allCandidateInNeedle = $true
    foreach ($t in $cTokens) {
        if ($nTokens -notcontains $t) { $allCandidateInNeedle = $false; break }
    }
    if ($allCandidateInNeedle) { return 85 }

    $allNeedleInCandidate = $true
    foreach ($t in $nTokens) {
        if ($cTokens -notcontains $t) { $allNeedleInCandidate = $false; break }
    }
    if ($allNeedleInCandidate) {
        $extra = @($cTokens | Where-Object { $nTokens -notcontains $_ })
        $unknown = @($extra | Where-Object { $script:NameQualifiers -notcontains $_ })
        if ($unknown.Count -eq 0) { return 80 }
    }

    if ($cTokens.Count -eq 1 -and $nTokens.Count -eq 1) {
        if ($nc.Length -ge 4 -and $cc.StartsWith($nc)) {
            $extra = $cc.Substring($nc.Length)
            if ($script:CompactSuffixes -contains $extra) { return 75 }
        }
        if ($cc.Length -ge 4 -and $nc.StartsWith($cc)) {
            $extra = $nc.Substring($cc.Length)
            if ($script:CompactSuffixes -contains $extra) { return 70 }
        }
    }

    return 0
}

function Get-UninstallCommandPath([string]$uninstallString) {
    if (-not $uninstallString) { return $null }
    $s = $uninstallString.Trim()
    if ($s -match '(?i)^\s*"?msiexec(\.exe)?"?') { return 'msiexec' }
    if ($s -match '^"([^"]+)"') { return $Matches[1] }
    $token = ($s -split '\s+')[0]
    if ($token) { return $token }
    $null
}

function Test-ArpEntryPresent($app) {
    if ($app.InstallLocation) {
        $loc = "$($app.InstallLocation)".Trim().Trim('"')
        if ($loc -and (Test-Path -LiteralPath $loc)) { return $true }
    }
    foreach ($raw in @($app.UninstallString, $app.QuietUninstallString)) {
        $path = Get-UninstallCommandPath $raw
        if (-not $path) { continue }
        if ($path -eq 'msiexec') { return $true }
        try {
            if (Test-Path -LiteralPath $path) { return $true }
        } catch { }
    }
    return $false
}

function Get-UninstallRegistryApps {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $result = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $item = Get-ItemProperty $_.PSPath -ErrorAction Stop
                if ($item.DisplayName -and (Test-ArpEntryPresent $item)) { $result += $item }
            } catch { }
        }
    }
    $result
}

function Initialize-LocalInventory {
    Write-Log "Indexing local installs (Appx, Start Menu, ARP)..."
    $script:AppxPackages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        -not $_.InstallLocation -or (Test-Path -LiteralPath $_.InstallLocation)
    })
    $script:StartApps = @(Get-StartApps -ErrorAction SilentlyContinue)
    $script:ArpApps   = @(Get-UninstallRegistryApps)
    Write-Log "Local index : Appx=$($script:AppxPackages.Count) StartMenu=$($script:StartApps.Count) ARP=$($script:ArpApps.Count)"
}

function Find-LocalInstallEvidence {
    param(
        [string]$Name,
        [string]$Id
    )

    $bestScore  = 0
    $bestDetail = $null

    if ($Id) {
        foreach ($app in $script:ArpApps) {
            if ($app.PSChildName -and ($app.PSChildName -ieq $Id)) {
                return "ARP $($app.DisplayName) [$($app.PSChildName)]"
            }
        }
    }

    if (-not $Name) { return $null }

    foreach ($app in $script:ArpApps) {
        $score = Get-MatchScore $app.DisplayName $Name
        if ($score -ge 80 -and $score -gt $bestScore) {
            $bestScore  = $score
            $bestDetail = "ARP $($app.DisplayName)"
        }
    }

    foreach ($pkg in $script:AppxPackages) {
        $score = Get-MatchScore (Get-AppxProductName $pkg.Name) $Name
        if ($score -lt 70) {
            $score = Get-MatchScore $pkg.Name $Name
        }
        if ($score -ge 70 -and $score -gt $bestScore) {
            $bestScore  = $score
            $bestDetail = "Appx $($pkg.Name)"
        }
    }

    foreach ($sa in $script:StartApps) {
        $score = Get-MatchScore $sa.Name $Name
        if ($score -ge 70 -and $score -gt $bestScore) {
            $bestScore  = $score
            $bestDetail = "Start Menu $($sa.Name)"
        }
    }

    return $bestDetail
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
Initialize-LocalInventory

$totalInstalled    = 0
$totalNotInstalled = 0
$totalStale        = 0
$totalUnknown      = 0
$installedApps     = @()
$staleApps         = @()

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
        $null = & winget list --id $app.ID --exact --disable-interactivity --accept-source-agreements 2>&1 |
            Tee-Object -Variable outputLines
    } catch {
        $errorText = $_.Exception.Message
    }

    $text = ($outputLines -join "`n")
    if ($errorText) { $text = "$text`n$errorText" }
    $code = $LASTEXITCODE

    $wingetHit = $false
    $status = 'unknown'
    $localEvidence = $null

    if ($text -match 'No installed package found matching input criteria' -or
        $text -match 'No packages found matching input criteria') {
        $status = 'not installed'
        $totalNotInstalled++
    } elseif ($code -eq 0 -and $text -match $([regex]::Escape($app.ID))) {
        $wingetHit = $true
    } elseif ($code -eq 0) {
        $wingetHit = $true
    } else {
        $totalUnknown++
    }

    if ($wingetHit) {
        $localEvidence = Find-LocalInstallEvidence -Name $app.Name -Id $app.ID
        if ($localEvidence) {
            $status = 'installed'
            $totalInstalled++
            $installedApps += $label
        } else {
            $status = 'stale (winget only)'
            $totalStale++
            $staleApps += $label
        }
    }

    if ($text.Trim()) {
        Write-Log $text.TrimEnd()
    }
    if ($wingetHit) {
        if ($localEvidence) {
            Write-Log "  Local check: $localEvidence"
        } else {
            Write-Log "  Local check: not found (Appx / Start Menu / ARP)"
        }
    }
    Write-Log "  Result: $status (exit $code)"
}

Write-Log ""
Write-Log "================================================"
Write-Log "SUMMARY"
Write-Log "================================================"
Write-Log "Total apps checked  : $($apps.Count)"
Write-Log "Installed           : $totalInstalled"
Write-Log "Not installed       : $totalNotInstalled"
Write-Log "Stale (winget only) : $totalStale"
Write-Log "Unknown             : $totalUnknown"
Write-Log "Installed apps      :"
if ($installedApps.Count -eq 0) {
    Write-Log "  (none)"
} else {
    foreach ($name in $installedApps) {
        Write-Log "  - $name"
    }
}
Write-Log "Stale apps          :"
if ($staleApps.Count -eq 0) {
    Write-Log "  (none)"
} else {
    foreach ($name in $staleApps) {
        Write-Log "  - $name"
    }
}
Write-Log "=== Test-AppInstalled finished: $(Get-Date) ==="
Write-Host ""
Write-Host "Log saved to: $logPath"
