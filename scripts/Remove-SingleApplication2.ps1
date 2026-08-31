param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="The display name of the application to uninstall")]
    [string]$ApplicationName
)

# ---- Registry lookup (reused from Find-AppUninstallInfo.ps1) ----
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Normalize-Name([string]$s) {
    if (-not $s) { return "" }
    ($s.ToLower() -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' '
}

function Test-NameMatch([string]$candidate, [string]$needle) {
    if (-not $candidate -or -not $needle) { return $false }
    $n = Normalize-Name $candidate
    return ($n -eq $needle -or $n -like "*$needle*" -or $needle -like "*$n*")
}

function Find-StorePackage([string]$needle) {
    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    if (-not $packages) { return $null }

    # Match the Appx package name (e.g. 5319275A.WhatsAppDesktop)
    $hits = @($packages | Where-Object { Test-NameMatch $_.Name $needle })

    # Match the Start Menu display name (e.g. "WhatsApp") and map back to the package
    if (-not $hits) {
        $startApps = @(Get-StartApps -ErrorAction SilentlyContinue |
            Where-Object { Test-NameMatch $_.Name $needle })
        foreach ($sa in $startApps) {
            if ($sa.AppID -notmatch '^(?<family>.+)!.+$') { continue }
            $family = $Matches['family']
            $hits += @($packages | Where-Object { $_.PackageFamilyName -eq $family })
        }
    }

    if (-not $hits) { return $null }
    $hits | Select-Object -First 1
}

$apps = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation,
                  UninstallString, QuietUninstallString, WindowsInstaller, PSChildName, PSPath

$apps | ForEach-Object {
    $_ | Add-Member -NotePropertyName NormName -NotePropertyValue (Normalize-Name $_.DisplayName) -Force
}

# ---- Find matching application (Win32 registry, then Store/MSIX) ----
$needle = Normalize-Name $ApplicationName
$match = $apps | Where-Object { $_.NormName -eq $needle }

if (-not $match) {
    $match = $apps | Where-Object { $_.NormName -like "*$needle*" -or $needle -like "*$($_.NormName)*" }
}

$storePkg = $null
if (-not $match) {
    $storePkg = Find-StorePackage $needle
}

if (-not $match -and -not $storePkg) {
    Write-Error "No application found matching '$ApplicationName'."
    exit 1
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

$startTime = Get-Date

if ($storePkg) {
    $displayName = $ApplicationName
    try {
        $manifestName = ($storePkg | Get-AppxPackageManifest -ErrorAction Stop).Package.Properties.DisplayName
        if ($manifestName) { $displayName = $manifestName }
    } catch { }

    Write-Host "Application found : $displayName (v$($storePkg.Version)) [Store/MSIX]"
    Write-Host "Using Remove-AppxPackage: $($storePkg.PackageFullName)"
    Remove-AppxPackage -Package $storePkg.PackageFullName
} else {
    # Pick the best match (prefer entries that have a QuietUninstallString)
    $match = $match | Sort-Object {
        [int]([string]::IsNullOrEmpty($_.QuietUninstallString))
    }, DisplayName | Select-Object -First 1

    $displayName = $match.DisplayName

    # Build the QuietUninstallString for MSI products if missing
    $quiet = $match.QuietUninstallString
    if (-not $quiet -and $match.WindowsInstaller -eq 1 -and $match.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        $quiet = "msiexec.exe /x $($match.PSChildName) /qn /norestart"
    }

    Write-Host "Application found : $($match.DisplayName) (v$($match.DisplayVersion))"

    if ($quiet) {
        Write-Host "Using QuietUninstallString: $quiet"

        # Split the command into executable and arguments
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
            Start-Process -FilePath $exe -ArgumentList $args -Wait -NoNewWindow
        } else {
            Start-Process -FilePath $exe -Wait -NoNewWindow
        }
    } else {
        $uninstall = $match.UninstallString
        if (-not $uninstall) {
            Write-Error "No uninstall string available for '$($match.DisplayName)'."
            exit 1
        }

        $silentArgs = "/S /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /quiet /norestart /qn /norestart"
        Write-Host "No QuietUninstallString found. Using UninstallString with silent args: $uninstall"

        # Split the command into executable and arguments, then append silent flags
        if ($uninstall -match '^"([^"]+)"\s*(.*)$') {
            $exe  = $Matches[1]
            $args = "$($Matches[2]) $silentArgs".Trim()
        } elseif ($uninstall -match '^(\S+)\s+(.*)$') {
            $exe  = $Matches[1]
            $args = "$($Matches[2]) $silentArgs".Trim()
        } else {
            $exe  = $uninstall
            $args = $silentArgs
        }

        Start-Process -FilePath $exe -ArgumentList $args -Wait -NoNewWindow
    }
}

$stopTime    = Get-Date
$elapsedTime = New-TimeSpan -Start $startTime -End $stopTime

# ---- Log result ----
$logEntry = "Uninstallation of '{0}' on {1} took {2}" -f $displayName, $startTime.ToString('yyyy-MM-dd HH:mm:ss'), $elapsedTime.ToString("mm\:ss")
Add-Content -Path $logPath -Value $logEntry

Write-Host "Uninstallation of '$displayName' completed in $($elapsedTime.ToString('mm\:ss'))"
