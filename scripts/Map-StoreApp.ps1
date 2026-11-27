<#
.SYNOPSIS
    Reads a JSON list of Microsoft Store apps (itemName, itemID, href, categories),
    installs each via winget, maps its local installed name and process names to a CSV,
    and uninstalls it cleanly.
.EXAMPLE
    .\Map-StoreApp.ps1 -JsonPath ".\test.json"
#>

param(
    [string]$JsonPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'results\apps_test.json'),
    [string]$CsvPath  = (Join-Path $PSScriptRoot 'store_app_mappings.csv')
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Please run this script as Administrator."
    exit 1
}

if (-not (Test-Path $JsonPath)) {
    Write-Error "JSON file not found at: $JsonPath"
    exit 1
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-Win32Apps {
    $RegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty $RegPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object PSChildName, PSPath, DisplayName, InstallLocation, DisplayIcon, UninstallString
}

function Get-WinGetPortableFolders {
    $WinGetPkgRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path $WinGetPkgRoot) {
        return @(Get-ChildItem -Path $WinGetPkgRoot -Directory | Select-Object -ExpandProperty FullName)
    }
    return @()
}

function Get-FilteredExecutables {
    param([string]$SearchDir)

    if (-not $SearchDir -or -not (Test-Path $SearchDir)) { return @() }

    return @(Get-ChildItem -Path $SearchDir -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "^unins|Update\.exe|Squirrel|Crashpad|createdump|elevate|vc_redist|dotnet" } |
        Sort-Object Length -Descending)
}

function Resolve-Win32Executables {
    param([PSCustomObject]$Win32App)

    $PrimaryExe = $null
    $SearchDir  = $null

    # 1. Check DisplayIcon first (often formatted as "C:\Path\To\App.exe,0")
    if ($Win32App.DisplayIcon) {
        $CleanIcon = ($Win32App.DisplayIcon -split ',')[0].Trim('"').Trim()
        if ($CleanIcon -like "*.exe" -and (Test-Path $CleanIcon)) {
            $SearchDir = Split-Path $CleanIcon -Parent
            if ($CleanIcon -notmatch "^unins|Update\.exe|Squirrel") {
                $PrimaryExe = $CleanIcon
            }
        }
    }

    # 2. Fallback to InstallLocation or Squirrel's %LocalAppData% directory
    if (-not $SearchDir) {
        if ($Win32App.InstallLocation -and (Test-Path $Win32App.InstallLocation)) {
            $SearchDir = $Win32App.InstallLocation
        }
        elseif ($Win32App.UninstallString -match '([a-zA-Z]:\\[^"]+?\\Update\.exe)') {
            $SearchDir = Split-Path $Matches[1] -Parent
        }
    }

    $AllExeFiles = Get-FilteredExecutables -SearchDir $SearchDir
    if (-not $PrimaryExe -and $AllExeFiles) {
        $PrimaryExe = $AllExeFiles[0].FullName
    }

    return [PSCustomObject]@{
        PrimaryExePath = $PrimaryExe
        AllExeNames    = @($AllExeFiles | ForEach-Object { $_.Name } | Select-Object -Unique)
    }
}

# ============================================================================
# LOAD JSON & PROCESS BATCH
# ============================================================================

$AppsList = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
if ($AppsList -isnot [System.Array]) { $AppsList = @($AppsList) }

$CompletedIds = @()
if (Test-Path $CsvPath) {
    $CompletedIds = (Import-Csv -Path $CsvPath).StoreId
}

$Total = $AppsList.Count
$Index = 0

foreach ($App in $AppsList) {
    $Index++
    $StoreId    = $App.itemID.Trim()
    $StoreName  = $App.itemName
    $Categories = if ($App.categories) { ($App.categories -join ";") } else { "" }

    Write-Host "================================================================="
    Write-Host "[$Index/$Total] Processing: $StoreName ($StoreId)"

    if ($CompletedIds -contains $StoreId) {
        Write-Host "    [SKIP] Already mapped in $CsvPath"
        continue
    }

    # 1. Triple pre-install snapshot (AppX + Win32/Squirrel Registry + WinGet Portable Folder)
    $BeforeAppx     = @(Get-AppxPackage | Select-Object -ExpandProperty PackageFullName)
    $BeforeWin32    = @(Get-Win32Apps | Select-Object -ExpandProperty PSChildName)
    $BeforePortable = Get-WinGetPortableFolders

    # 2. Install via winget
    Write-Host "    [1/3] Installing via winget..."
    winget install --id $StoreId --source msstore --accept-package-agreements --accept-source-agreements --silent | Out-Null
    Start-Sleep -Seconds 2

    # 3. Diff all three snapshots
    Write-Host "    [2/3] Resolving packaging type, installed name, and executables..."
    $NewAppx     = Get-AppxPackage | Where-Object { $BeforeAppx -notcontains $_.PackageFullName } | Select-Object -First 1
    $NewWin32    = Get-Win32Apps   | Where-Object { $BeforeWin32 -notcontains $_.PSChildName } | Select-Object -First 1
    $NewPortable = Get-WinGetPortableFolders | Where-Object { $BeforePortable -notcontains $_ } | Select-Object -First 1

    $AppType        = "FAILED_OR_NOT_DETECTED"
    $InstalledName  = ""
    $PackageId      = ""
    $PrimaryProcess = ""
    $AllProcesses   = @()

    if ($NewAppx) {
        $PackageId    = $NewAppx.PackageFullName
        $ManifestPath = Join-Path $NewAppx.InstallLocation "AppxManifest.xml"
        $ManifestRaw  = Get-Content -Path $ManifestPath -Raw
        [xml]$Manifest = $ManifestRaw

        $InstalledName = $Manifest.Package.Properties.DisplayName
        $AppNodes      = @($Manifest.Package.Applications.Application)
        $ManifestExes  = @($AppNodes | ForEach-Object {
            [System.IO.Path]::GetFileName($_.Executable)
        } | Where-Object { $_ } | Select-Object -Unique)

        # Sub-classify MSIX into PWA, DesktopBridge (FullTrustApplication), or Pure MSIX
        $IsPwa = ($ManifestExes -contains "pwahelper.exe") -or
                 ($ManifestExes -contains "msedge_proxy.exe") -or
                 ($ManifestRaw -match 'StartPage="https?://')

        $IsDesktopBridge = ($ManifestRaw -match 'EntryPoint="Windows\.FullTrustApplication"') -or
                           (Test-Path (Join-Path $NewAppx.InstallLocation "VFS"))

        if ($IsPwa) {
            $AppType        = "PWA"
            $PrimaryProcess = if ($ManifestExes) { $ManifestExes[0] } else { "pwahelper.exe" }
            # Include Edge WebView2/Browser runtimes because PWA network traffic leaves via those processes
            $AllProcesses   = @($ManifestExes + @("msedgewebview2.exe", "msedge.exe") | Select-Object -Unique)
        }
        elseif ($IsDesktopBridge) {
            $AppType        = "DesktopBridge"
            $PrimaryProcess = $ManifestExes | Select-Object -First 1

            # Scan the entire InstallLocation (including VFS) for bundled helper/worker .exe files
            $FolderExes   = Get-FilteredExecutables -SearchDir $NewAppx.InstallLocation | ForEach-Object { $_.Name }
            $AllProcesses = @($ManifestExes + $FolderExes | Select-Object -Unique)
        }
        else {
            $AppType        = "MSIX"
            $PrimaryProcess = $ManifestExes | Select-Object -First 1
            $AllProcesses   = $ManifestExes
        }
    }
    elseif ($NewWin32) {
        $IsSquirrel    = ($NewWin32.UninstallString -match "Update\.exe") -or ($NewWin32.PSPath -match "HKEY_CURRENT_USER")
        $AppType       = if ($IsSquirrel) { "Squirrel" } else { "Win32" }
        $InstalledName = $NewWin32.DisplayName
        $PackageId     = $NewWin32.PSChildName

        $Resolved = Resolve-Win32Executables -Win32App $NewWin32
        if ($Resolved.PrimaryExePath) {
            $PrimaryProcess = [System.IO.Path]::GetFileName($Resolved.PrimaryExePath)
            $AllProcesses   = $Resolved.AllExeNames
        }
    }
    elseif ($NewPortable) {
        $AppType       = "Portable"
        $PackageId     = Split-Path $NewPortable -Leaf
        $InstalledName = ($PackageId -split '_')[0]

        $PortableExes = Get-FilteredExecutables -SearchDir $NewPortable
        if ($PortableExes) {
            $PrimaryProcess = $PortableExes[0].Name
            $AllProcesses   = @($PortableExes | ForEach-Object { $_.Name } | Select-Object -Unique)
        }
    }
    else {
        Write-Warning "    Could not detect new package for $StoreName ($StoreId). Logging failure row."
    }

    # Build and append mapping record
    $Record = [PSCustomObject]@{
        Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        StoreId        = $StoreId
        StoreName      = $StoreName
        InstalledName  = $InstalledName
        PrimaryProcess = $PrimaryProcess
        AllProcesses   = ($AllProcesses -join ";")
        AppType        = $AppType
        Categories     = $Categories 
        PackageId      = $PackageId
    }

    $Record | Format-List StoreId, StoreName, InstalledName, PrimaryProcess, AllProcesses, AppType
    $Record | Export-Csv -Path $CsvPath -Append -NoTypeInformation

    # 4. Cleanly uninstall
    if ($AppType -in @("MSIX", "DesktopBridge", "PWA")) {
        Write-Host "    [3/3] Uninstalling $AppType package..."
        Remove-AppxPackage -Package $NewAppx.PackageFullName
    }
    elseif ($AppType -in @("Win32", "Squirrel", "Portable")) {
        Write-Host "    [3/3] Uninstalling $AppType package..."
        winget uninstall --id $StoreId --silent --accept-source-agreements | Out-Null
    }
}

Write-Host "`n[+] Batch complete. Full mapping table saved to: $CsvPath"