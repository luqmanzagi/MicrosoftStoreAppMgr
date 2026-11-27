# Map-AppName.ps1
# Dot-source this file. It only defines functions.
# Get-PreInstallSnapshot, Get-SnapshotDiff, and Get-InstalledAppData map a
# newly installed Store app to its local name, packaging type, and process names.
# Packaging types: MSIX, DesktopBridge, PWA, Win32, Squirrel, Portable.

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

function Get-PreInstallSnapshot {
    <#
    .SYNOPSIS
        Records Appx packages, Win32 uninstall keys, and WinGet portable folders before an install.
    #>
    $appxFullNames = [System.Collections.Generic.List[string]]::new()
    $appxNames = [System.Collections.Generic.List[string]]::new()
    foreach ($pkg in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        if ($pkg.PackageFullName) { $appxFullNames.Add([string]$pkg.PackageFullName) }
        if ($pkg.Name) { $appxNames.Add([string]$pkg.Name) }
    }

    $win32Keys = [System.Collections.Generic.List[string]]::new()
    foreach ($app in @(Get-Win32Apps)) {
        if ($app.PSChildName) { $win32Keys.Add([string]$app.PSChildName) }
    }

    $portableFolders = [System.Collections.Generic.List[string]]::new()
    foreach ($folder in @(Get-WinGetPortableFolders)) {
        if ($folder) { $portableFolders.Add([string]$folder) }
    }

    [PSCustomObject]@{
        AppxFullNames    = $appxFullNames.ToArray()
        AppxNames        = $appxNames.ToArray()
        Win32Keys        = $win32Keys.ToArray()
        PortableFolders  = $portableFolders.ToArray()
    }
}

function Get-NameMatchScore([string]$candidate, [string]$needle) {
    if (-not $candidate -or -not $needle) { return 0 }
    $c = ($candidate.ToLower() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' '
    $n = ($needle.ToLower() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' '
    if (-not $c -or -not $n) { return 0 }
    if ($c -eq $n) { return 100 }
    $cc = $c -replace ' ', ''
    $nc = $n -replace ' ', ''
    if ($cc -eq $nc) { return 90 }
    $tokens = @($n -split ' ' | Where-Object { $_.Length -ge 4 })
    if ($tokens.Count -gt 0) {
        $hit = @($tokens | Where-Object { $cc.Contains($_) }).Count
        if ($hit -eq $tokens.Count) { return 80 }
        if ($hit -gt 0) { return 60 }
    }
    if ($nc.Length -ge 4 -and $cc.Contains($nc)) { return 70 }
    return 0
}

function Test-IsAppxSidePackage($Package) {
    # Runtimes and source packages that winget updates alongside the product.
    $name = [string]$Package.Name
    if ($name -match '^(?i)Microsoft\.(Winget\.Source$|WindowsAppRuntime(\.|$)|VCLibs\.|UI\.Xaml\.|NET\.Native\.|Advertising\.|Services\.Store\.|WinJS\.|DirectXRuntime$|Windows\.ApplicationModel\.Resources$)') {
        return $true
    }

    if (-not $Package.InstallLocation) { return $false }
    $manifestPath = Join-Path $Package.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }
    $raw = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $false }
    if ($raw -match '<Properties>[\s\S]*?<Framework>\s*true\s*</Framework>') { return $true }
    if ($raw -notmatch '<Application[\s>]') { return $true }
    return $false
}

function Test-IsWin32SidePackage($App) {
    $name = [string]$App.DisplayName
    return $name -match '(?i)(Visual C\+\+ .*Redistributable|Windows Desktop Runtime|WebView2 Runtime|Windows Package Manager|\.NET (Runtime|Host|Targeting Pack)|ASP\.NET Core)'
}

function Test-IsPortableSideFolder([string]$Folder) {
    $leaf = Split-Path $Folder -Leaf
    return $leaf -match '^(?i)Microsoft\.(Winget\.Source|WindowsAppRuntime|VCLibs|UI\.Xaml|NET\.Native|DesktopAppInstaller)'
}

function Select-PreferredAppx($Packages, [string]$PreferredName) {
    $list = @($Packages | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1) { return $list[0] }

    $best = $null
    $bestScore = 0
    foreach ($pkg in $list) {
        $product = [string]$pkg.Name
        $dot = $product.IndexOf('.')
        if ($dot -ge 0 -and $dot -lt ($product.Length - 1)) {
            $product = $product.Substring($dot + 1)
        }
        $score = Get-NameMatchScore $product $PreferredName
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $pkg
        }
    }
    if ($best) { return $best }

    $nonMs = @($list | Where-Object { $_.Name -notlike 'Microsoft.*' })
    if ($nonMs.Count -eq 1) { return $nonMs[0] }
    return $list[0]
}

function Select-PreferredWin32($Apps, [string]$PreferredName) {
    $list = @($Apps | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($list.Count -eq 1 -or -not $PreferredName) { return $list[0] }

    $best = $list[0]
    $bestScore = -1
    foreach ($app in $list) {
        $score = Get-NameMatchScore $app.DisplayName $PreferredName
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $app
        }
    }
    return $best
}

function Get-SnapshotDiff {
    <#
    .SYNOPSIS
        Returns the new Appx package, Win32 app, and WinGet portable folder absent from the pre-install snapshot.
        Runtime and source packages that appear beside the product are ignored.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Before,

        [string]$PreferredName
    )

    $beforeAppx = @($Before.AppxFullNames)
    $beforeNames = @($Before.AppxNames)
    $beforeWin32 = @($Before.Win32Keys)
    $beforePortable = @($Before.PortableFolders)

    # A version bump of a package that was already installed (Winget.Source,
    # Windows App Runtime, inbox Camera) is not the product this install added.
    $brandNewAppx = @()
    $upgradedAppx = @()
    foreach ($pkg in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
        if ($beforeAppx -contains $pkg.PackageFullName) { continue }
        if (Test-IsAppxSidePackage $pkg) { continue }
        if ($beforeNames -contains $pkg.Name) { $upgradedAppx += $pkg }
        else { $brandNewAppx += $pkg }
    }
    $newAppx = @(if ($brandNewAppx.Count -gt 0) { $brandNewAppx } else { $upgradedAppx })

    $newWin32 = @()
    foreach ($app in @(Get-Win32Apps)) {
        if ($beforeWin32 -notcontains $app.PSChildName -and -not (Test-IsWin32SidePackage $app)) {
            $newWin32 += $app
        }
    }

    $newPortable = @()
    foreach ($folder in @(Get-WinGetPortableFolders)) {
        if ($beforePortable -notcontains $folder -and -not (Test-IsPortableSideFolder $folder)) {
            $newPortable += $folder
        }
    }

    [PSCustomObject]@{
        Appx      = (Select-PreferredAppx $newAppx $PreferredName)
        Win32     = (Select-PreferredWin32 $newWin32 $PreferredName)
        Portable  = $(if ($newPortable.Count -gt 0) { $newPortable[0] } else { $null })
    }
}

function Get-InstalledAppData {
    <#
    .SYNOPSIS
        Reads the installed name, package id, packaging type, and process names from a snapshot diff.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Diff
    )

    $NewAppx      = $Diff.Appx
    $NewWin32     = $Diff.Win32
    $NewPortable  = $Diff.Portable

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

    if (-not $PrimaryProcess) { $PrimaryProcess = "" }

    [PSCustomObject]@{
        AppType        = $AppType
        InstalledName  = $InstalledName
        PackageId      = $PackageId
        PrimaryProcess = $PrimaryProcess
        AllProcesses   = @($AllProcesses | Where-Object { $_ })
    }
}
