# Silent uninstall only. Invoke-Hybrid.ps1 calls this after a successful install.
# A QuietUninstallString, msiexec /qn, or Remove-AppxPackage runs here.
# When none of those exist, this script does not call winget uninstall.
# It prints NEEDS_RESTORE=1 and exits 2 so the caller can system-restore.
# Exit 0: silent uninstall finished. Exit 1: silent uninstall failed. Exit 2: restore.

param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="The display name of the application to uninstall")]
    [string]$ApplicationName,

    [Parameter(Mandatory=$false, HelpMessage="Package id, included in the restore message when lookup fails")]
    [string]$Id
)

# ---- Registry lookup (reused from Find-AppUninstallInfo.ps1) ----
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
    # Short display name fully contained in a longer Store title (e.g. "PDF X" vs "PDF X: PDF Editor")
    if ($allCandidateInNeedle) { return 85 }

    # Same product with publisher/scope qualifiers (e.g. "Visual Studio Code" vs "Microsoft Visual Studio Code (User)")
    # Must NOT match a different product that merely starts with the same words
    # (e.g. "Windows App" vs "Windows App Certification Kit Native Components").
    $allNeedleInCandidate = $true
    foreach ($t in $nTokens) {
        if ($cTokens -notcontains $t) { $allNeedleInCandidate = $false; break }
    }
    if ($allNeedleInCandidate) {
        $extra = @($cTokens | Where-Object { $nTokens -notcontains $_ })
        $unknown = @($extra | Where-Object { $script:NameQualifiers -notcontains $_ })
        if ($unknown.Count -eq 0) { return 80 }
    }

    # Compact prefix only for single-token names with a known suffix ("WhatsApp" vs "WhatsAppDesktop")
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

function Write-UninstallMethod([string]$Method) {
    Write-Output "UNINSTALL_METHOD=$Method"
}

function Test-IsProcessElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
                if ($item.DisplayName) { $result += $item }
            } catch { }
        }
    }
    $result
}

function Find-SquirrelUninstall([string]$Name) {
    if (-not $Name) { return $null }
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA $Name),
        (Join-Path $env:LOCALAPPDATA "$Name\$Name")
    )
    foreach ($dir in $dirs) {
        $exe = Join-Path $dir 'Update.exe'
        if (-not (Test-Path $exe)) { continue }
        return [pscustomobject]@{
            DisplayName          = $Name
            Publisher            = $null
            DisplayVersion       = $null
            InstallLocation      = $dir
            UninstallString      = "`"$exe`" --uninstall"
            QuietUninstallString = "`"$exe`" --uninstall -s"
            WindowsInstaller     = 0
            PSChildName          = $Name
            PSPath               = $null
            NormName             = (Normalize-Name $Name)
        }
    }
    $null
}

function Get-DerivedQuietUninstallString($app) {
    if ($app.QuietUninstallString) { return [string]$app.QuietUninstallString }

    if ($app.WindowsInstaller -eq 1 -and $app.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        return "msiexec.exe /x $($app.PSChildName) /qn /norestart"
    }

    $u = [string]$app.UninstallString
    if (-not $u) { return $null }

    # Squirrel (Discord, Slack, ...)
    if ($u -match 'Update\.exe') {
        if ($u -match '--uninstall') { return ($u -replace '--uninstall.*', '--uninstall -s') }
        return "$u --uninstall -s"
    }

    # Chromium (Brave, Chrome, Edge, Opera, Vivaldi)
    if ($u -match 'Installer\\setup\.exe' -and $u -match '--uninstall') {
        if ($u -match '--force-uninstall') { return $u }
        return "$u --force-uninstall"
    }

    # Inno Setup
    if ($u -match '(?i)unins\d+\.exe') {
        if ($u -match '/VERYSILENT') { return $u }
        return "$u /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
    }

    $null
}

function Invoke-QuietUninstallCommand([string]$quiet) {
    if ($quiet -match '^"([^"]+)"\s*(.*)$') {
        $exe  = $Matches[1]
        $args = $Matches[2]
    } elseif ($quiet -match '^(\S+)\s+(.*)$') {
        $exe  = $Matches[1]
        $args = $Matches[2]
    } else {
        $exe  = $quiet
        $args = $null
    }

    if ($args) {
        $argList = if ($args -match '"') { $args } else { @($args -split '\s+' | Where-Object { $_ }) }
        Start-Process -FilePath $exe -ArgumentList $argList -Wait -NoNewWindow
    } else {
        Start-Process -FilePath $exe -Wait -NoNewWindow
    }
}

function Stop-MatchingProcesses([string]$Name) {
    if (-not $Name -or $Name.Trim().Length -lt 4) { return }
    $n = Normalize-Name $Name
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $pName = Normalize-Name $_.ProcessName
        $pName -eq $n -or $pName -like "$n *"
    } | ForEach-Object {
        try {
            Write-Host "Stopping process: $($_.ProcessName) (PID $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        } catch { }
    }
}


function Find-StorePackage([string]$needle) {
    if ($null -eq $script:AppxPackages) {
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
        if (Test-IsProcessElevated) {
            $packages += @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        }
        $script:AppxPackages = @($packages | Sort-Object PackageFullName -Unique)
    }
    $packages = $script:AppxPackages
    if (-not $packages) { return $null }

    $minScore = 70
    $best = $null
    $bestScore = 0

    # Match the Appx *product* name (after the publisher prefix).
    # "Facebook.InstagramBeta" must not win a search for "Facebook".
    foreach ($pkg in $packages) {
        $score = Get-MatchScore (Get-AppxProductName $pkg.Name) $needle
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $pkg
        }
    }

    # Match the Start Menu display name (e.g. "WhatsApp") and map back to the package
    $startApps = @(Get-StartApps -ErrorAction SilentlyContinue)
    foreach ($sa in $startApps) {
        $score = Get-MatchScore $sa.Name $needle
        if ($score -le $bestScore) { continue }
        if ($sa.AppID -notmatch '^(?<family>.+)!.+$') { continue }
        $family = $Matches['family']
        $mapped = $packages | Where-Object { $_.PackageFamilyName -eq $family } | Select-Object -First 1
        if ($mapped) {
            $bestScore = $score
            $best = $mapped
        }
    }

    if ($bestScore -lt $minScore) { return $null }
    [pscustomobject]@{ Package = $best; Score = $bestScore }
}

function Find-RegistryMatch([string]$ApplicationName) {
    $apps = @(Get-UninstallRegistryApps)
    $apps | ForEach-Object {
        $_ | Add-Member -NotePropertyName NormName -NotePropertyValue (Normalize-Name $_.DisplayName) -Force
    }

    $needle = Normalize-Name $ApplicationName
    $match = @($apps | Where-Object { $_.NormName -eq $needle })
    $regScore = 0
    if ($match.Count -gt 0) {
        return [pscustomobject]@{ Match = $match; Score = 100 }
    }

    $bestReg = $null
    foreach ($app in $apps) {
        $score = Get-MatchScore $app.DisplayName $ApplicationName
        if ($score -gt $regScore) {
            $regScore = $score
            $bestReg = $app
        }
    }
    if ($regScore -ge 80) {
        return [pscustomobject]@{ Match = @($bestReg); Score = $regScore }
    }
    [pscustomobject]@{ Match = @(); Score = 0 }
}

# ---- Find matching application (Win32 registry, Squirrel, then Store/MSIX) ----
# Store/Win32 bootstrappers (Discord) often finish after winget reports success.
$needle = Normalize-Name $ApplicationName
$match = @()
$regScore = 0
$storeHit = $null
$storePkg = $null
$storeScore = 0
$maxLookupAttempts = 6

for ($lookupTry = 1; $lookupTry -le $maxLookupAttempts; $lookupTry++) {
    $regHit = Find-RegistryMatch $ApplicationName
    $match = @($regHit.Match)
    $regScore = [int]$regHit.Score

    if ($match.Count -eq 0) {
        $squirrel = Find-SquirrelUninstall $ApplicationName
        if ($squirrel) {
            $match = @($squirrel)
            $regScore = 100
        }
    }

    $storeHit = Find-StorePackage $needle
    $storePkg = $null
    $storeScore = 0
    if ($storeHit) {
        $storePkg = $storeHit.Package
        $storeScore = [int]$storeHit.Score
    }

    # Prefer the stronger identity. A weak registry prefix match must not beat
    # the real Store package (Windows App vs Windows App Certification Kit).
    if ($storeScore -gt $regScore) {
        $match = @()
    } else {
        $storePkg = $null
    }

    if ($match.Count -gt 0 -or $storePkg) { break }
    if ($lookupTry -lt $maxLookupAttempts) {
        Write-Host "App not visible yet; waiting for installer to finish ($lookupTry/$maxLookupAttempts)..."
        Start-Sleep -Seconds 8
        $script:AppxPackages = $null
    }
}

# ---- Logging setup ----
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$logDir = Join-Path $parentDir 'logs\uninstall'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$dateStr  = Get-Date -Format 'yyyy-MM-dd'
$logPath  = Join-Path $logDir "$dateStr.log"

if (-not $match -and -not $storePkg) {
    $idNote = if ($Id) { " (id $Id)" } else { '' }
    Write-UninstallMethod 'restore'
    Write-Output 'NEEDS_RESTORE=1'
    Write-Host "No application found matching '$ApplicationName'$idNote. No silent uninstall. System restore is required."
    exit 2
}

$startTime = Get-Date

if ($storePkg) {
    $displayName = $ApplicationName
    try {
        $manifestName = ($storePkg | Get-AppxPackageManifest -ErrorAction Stop).Package.Properties.DisplayName
        if ($manifestName) { $displayName = $manifestName }
    } catch { }

    Write-Host "Application found : $displayName (v$($storePkg.Version)) [Store/MSIX]"
    Write-Host "Using Remove-AppxPackage: $($storePkg.PackageFullName)"
    Write-UninstallMethod 'Remove-AppxPackage'
    if (Test-IsProcessElevated) {
        Remove-AppxPackage -Package $storePkg.PackageFullName -AllUsers
    } else {
        Remove-AppxPackage -Package $storePkg.PackageFullName
    }
} else {
    # Pick the best match (prefer entries that have a QuietUninstallString)
    $match = $match | Sort-Object {
        [int]([string]::IsNullOrEmpty($_.QuietUninstallString))
    }, DisplayName | Select-Object -First 1

    $displayName = $match.DisplayName
    $quiet = Get-DerivedQuietUninstallString $match

    Write-Host "Application found : $($match.DisplayName) (v$($match.DisplayVersion))"
    Stop-MatchingProcesses $ApplicationName

    if ($quiet) {
        $methodName = if ($quiet -match 'msiexec') { 'msiexec' } else { 'QuietUninstallString' }
        Write-Host "Using QuietUninstallString: $quiet"
        Write-UninstallMethod $methodName
        Invoke-QuietUninstallCommand $quiet
    } else {
        # Do not run UninstallString: it is interactive for Brave/CapCut/Discord-style apps.
        # Do not call winget uninstall. The caller system-restores instead.
        Write-Host "No silent uninstaller for '$displayName'. System restore is required."
        Write-UninstallMethod 'restore'
        Write-Output 'NEEDS_RESTORE=1'
        exit 2
    }
}

$stopTime    = Get-Date
$elapsedTime = New-TimeSpan -Start $startTime -End $stopTime

# ---- Log result ----
$logEntry = "Uninstallation of '{0}' on {1} took {2}" -f $displayName, $startTime.ToString('yyyy-MM-dd HH:mm:ss'), $elapsedTime.ToString("mm\:ss")
Add-Content -Path $logPath -Value $logEntry

Write-Host "Uninstallation of '$displayName' completed in $($elapsedTime.ToString('mm\:ss'))"
exit 0
