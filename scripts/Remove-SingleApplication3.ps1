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

function Test-NameMatch([string]$candidate, [string]$needle) {
    if (-not $candidate -or -not $needle) { return $false }
    $n = Normalize-Name $candidate
    return ($n -eq $needle -or $n -like "*$needle*" -or $needle -like "*$n*")
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
