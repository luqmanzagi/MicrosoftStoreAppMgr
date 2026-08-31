param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="The display name of the application to uninstall")]
    [string]$ApplicationName,

    [Parameter(Mandatory=$false, HelpMessage="Optional winget/Store package ID used if name lookup fails")]
    [string]$Id
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

function Get-WingetFlatText([string]$Text) {
    if (-not $Text) { return "" }
    (($Text -replace '\x00', '') -replace ' (?=[A-Za-z])', '')
}

function Get-WingetPath {
    $cmd = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $fallback) { return $fallback }
    throw "winget.exe not found"
}

function Invoke-WingetUninstallDirect {
    param([Parameter(Mandatory)][string[]]$WingetArgs)

    Write-Host ("Using winget " + ($WingetArgs -join ' '))
    $output = & (Get-WingetPath) @WingetArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = -1 }

    foreach ($line in $output) {
        if ($line -and "$line".Trim()) { Write-Host $line }
    }
    Write-Host "winget exit code: $code"
    [pscustomobject]@{ ExitCode = [int]$code; Output = ($output -join "`n") }
}

function Invoke-WingetUninstallUnelevated {
    param([Parameter(Mandatory)][string[]]$WingetArgs)

    $wingetPath = Get-WingetPath
    $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile  = Join-Path $env:TEMP "winget-uninst-$stamp.out"
    $codeFile = Join-Path $env:TEMP "winget-uninst-$stamp.exit"
    $cmdFile  = Join-Path $env:TEMP "winget-uninst-$stamp.cmd"
    $taskName = "MSCrawlerWingetUninstall_$stamp"

    $argLine = ($WingetArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '""') } else { $_ }
    }) -join ' '

    @(
        '@echo off'
        " `"$wingetPath`" $argLine > `"$outFile`" 2>&1"
        "echo %ERRORLEVEL% > `"$codeFile`""
    ) | Set-Content -Path $cmdFile -Encoding ASCII

    Write-Host "Retrying winget unelevated (user-scope package cannot be uninstalled as administrator)"
    Write-Host ("Using winget " + ($WingetArgs -join ' ') + " [unelevated]")

    $action    = New-ScheduledTaskAction -Execute $env:ComSpec -Argument "/c `"$cmdFile`""
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $settings.ExecutionTimeLimit = 'PT15M'

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 1
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

        $waitFile = (Get-Date).AddSeconds(20)
        while (-not (Test-Path $codeFile) -and (Get-Date) -lt $waitFile) {
            Start-Sleep -Milliseconds 250
        }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $cmdFile -ErrorAction SilentlyContinue
    }

    $output = @()
    if (Test-Path $outFile) {
        $output = Get-Content -Path $outFile -ErrorAction SilentlyContinue
    }
    $code = -1
    if (Test-Path $codeFile) {
        $raw = (Get-Content -Path $codeFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ("$raw".Trim() -match '^-?\d+') { $code = [int]$Matches[0] }
    }
    Remove-Item $outFile, $codeFile -ErrorAction SilentlyContinue

    foreach ($line in $output) {
        if ($line -and "$line".Trim()) { Write-Host $line }
    }
    Write-Host "winget exit code: $code"
    [pscustomobject]@{ ExitCode = [int]$code; Output = ($output -join "`n") }
}

function Find-StorePackage([string]$needle) {
    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
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

$apps = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation,
                  UninstallString, QuietUninstallString, WindowsInstaller, PSChildName, PSPath

$apps | ForEach-Object {
    $_ | Add-Member -NotePropertyName NormName -NotePropertyValue (Normalize-Name $_.DisplayName) -Force
}

# ---- Find matching application (Win32 registry and Store/MSIX) ----
$needle = Normalize-Name $ApplicationName
$match = $apps | Where-Object { $_.NormName -eq $needle }
$regScore = 0
if ($match) {
    $regScore = 100
} else {
    $bestReg = $null
    foreach ($app in $apps) {
        $score = Get-MatchScore $app.DisplayName $ApplicationName
        if ($score -gt $regScore) {
            $regScore = $score
            $bestReg = $app
        }
    }
    if ($regScore -ge 80) {
        $match = $bestReg
    } else {
        $regScore = 0
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
    $match = $null
} else {
    $storePkg = $null
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

$useWinget = $false
if (-not $match -and -not $storePkg) {
    if ($Id) {
        $useWinget = $true
    } else {
        Write-UninstallMethod 'not found'
        Write-Error "No application found matching '$ApplicationName'."
        exit 1
    }
}

$startTime = Get-Date

if ($useWinget) {
    $displayName = $ApplicationName
    Write-Host "Name lookup missed '$ApplicationName'. Falling back to winget."
    Write-UninstallMethod 'winget'

    $wingetArgs = @(
        'uninstall', '--id', $Id,
        '--silent', '--disable-interactivity', '--accept-source-agreements'
    )

    $result = Invoke-WingetUninstallDirect -WingetArgs $wingetArgs
    $wingetExit = $result.ExitCode
    $flat = Get-WingetFlatText $result.Output

    $adminUserScope = $flat -match 'installed for user scope cannot be uninstalled when running with administrator privileges'
    if ($wingetExit -ne 0 -and $adminUserScope) {
        $result = Invoke-WingetUninstallUnelevated -WingetArgs $wingetArgs
        $wingetExit = $result.ExitCode
        $flat = Get-WingetFlatText $result.Output
    }

    if ($wingetExit -ne 0 -and $flat -match 'Successfully uninstalled') {
        $wingetExit = 0
    }
    Write-Output "WINGET_EXIT=$wingetExit"
} elseif ($storePkg) {
    $displayName = $ApplicationName
    try {
        $manifestName = ($storePkg | Get-AppxPackageManifest -ErrorAction Stop).Package.Properties.DisplayName
        if ($manifestName) { $displayName = $manifestName }
    } catch { }

    Write-Host "Application found : $displayName (v$($storePkg.Version)) [Store/MSIX]"
    Write-Host "Using Remove-AppxPackage: $($storePkg.PackageFullName)"
    Write-UninstallMethod 'Remove-AppxPackage'
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
        $methodName = if ($quiet -match 'msiexec') { 'msiexec' } else { 'QuietUninstallString' }
        Write-Host "Using QuietUninstallString: $quiet"
        Write-UninstallMethod $methodName

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
            Write-UninstallMethod 'no uninstall string'
            Write-Error "No uninstall string available for '$($match.DisplayName)'."
            exit 1
        }

        $silentArgs = "/S /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /quiet /norestart /qn /norestart"
        Write-Host "No QuietUninstallString found. Using UninstallString with silent args: $uninstall"
        Write-UninstallMethod 'UninstallString'

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

if ($useWinget -and $wingetExit -ne 0) {
    Write-Host "Uninstallation of '$displayName' failed in $($elapsedTime.ToString('mm\:ss')) (winget exit $wingetExit)"
    exit $wingetExit
}

Write-Host "Uninstallation of '$displayName' completed in $($elapsedTime.ToString('mm\:ss'))"
