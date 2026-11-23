# Invoke-TestRestore.ps1
# Same install, screen recording, mitmdump, and network trace flow as
# Invoke-TestPower.ps1. Cleanup is a system restore, not an uninstall.
#
# On the first run this script creates one restore point named
# "MicrosoftStoreAppMgr test baseline". Later runs reuse that point.
# Checkpoint-Computer is called from New-BaselineRestorePoint only, and
# only when that baseline does not already exist.
#
# After a successful install the script prints
# "Installation finish, start to restore" and restores that point.
# Restore-Computer restarts Windows. Run this script again after logon;
# results\restore-session.json holds the next app and the sequence number.
# Apps that already exist or fail to install are skipped, with no reboot.
#
# Run from an elevated Windows PowerShell 5.1 window:
#   powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-TestRestore.ps1
#
# Start the app list over on the same point: delete results\restore-session.json.
# Create a new baseline only from a clean machine: delete that file and the
# restore point with the baseline name, then run this script again.

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin) {
    Write-Error "Invoke-TestRestore.ps1 must run as Administrator."
    exit 1
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Error "Run Invoke-TestRestore.ps1 with Windows PowerShell 5.1 (powershell.exe)."
    exit 1
}

# -- Path setup --
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$jsonPath = Join-Path $parentDir 'results\apps_manual.json'
$script:SessionPath = Join-Path $parentDir 'results\restore-session.json'
$script:RestorePointDescription = 'MicrosoftStoreAppMgr test baseline'
$script:FrequencyKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$script:FrequencyName = 'SystemRestorePointCreationFrequency'
$script:MarkerKey = 'HKLM:\SOFTWARE\MicrosoftStoreAppMgr'
$script:MarkerName = 'RestorePending'

if (-not (Test-Path $jsonPath)) {
    Write-Error "JSON file not found: $jsonPath"
    exit 1
}

# Ensure .\results\screen_records exists in parent directory
$recDir = Join-Path $parentDir 'results\screen_records'
if (-not (Test-Path -LiteralPath $recDir)) {
    New-Item -ItemType Directory -Path $recDir -Force | Out-Null
}

$netdumpDir = Join-Path $parentDir 'results\netdump'
if (-not (Test-Path -LiteralPath $netdumpDir)) {
    New-Item -ItemType Directory -Path $netdumpDir -Force | Out-Null
}

$etlDir = Join-Path $parentDir 'results\logs\etl'
if (-not (Test-Path -LiteralPath $etlDir)) {
    New-Item -ItemType Directory -Path $etlDir -Force | Out-Null
}

$mitmLogDir = Join-Path $parentDir 'results\logs\mitmdump'
if (-not (Test-Path -LiteralPath $mitmLogDir)) {
    New-Item -ItemType Directory -Path $mitmLogDir -Force | Out-Null
}

# wpr keeps in-progress traces here. Stop-NetworkStackTrace.ps1 deletes this directory.
$networkStackTempDir = Join-Path $env:TEMP 'MicrosoftStoreAppMgr\network-stacks'
$startNetworkStackTrace = Join-Path $scriptDir 'Start-NetworkStackTrace.ps1'
$stopNetworkStackTrace = Join-Path $scriptDir 'Stop-NetworkStackTrace.ps1'

# -- Logging --
$logDir = Join-Path $parentDir 'results\logs\terminal'
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

function Info($msg) {
    $line = "[INFO ] $msg"
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor Cyan
}

function Warn($msg) {
    $line = "[WARN ] $msg"
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor Yellow
}

function Get-ProbeTimeStamp {
    # yyyy-MMM-dd:HH:mm, for example 2026-Nov-23:14:05. 24-hour clock, English month.
    return [datetime]::Now.ToString('yyyy-MMM-dd:HH:mm', [cultureinfo]::InvariantCulture)
}

function Get-RestoreAppLabel {
    if ($label) { return [string]$label }
    if ($script:Session -and $null -ne $script:Session.pendingIndex) {
        $index = [int]$script:Session.pendingIndex
        if ($index -ge 0 -and $index -lt @($apps).Count) {
            $pendingApp = $apps[$index]
            if ($pendingApp.Name) { return "$($pendingApp.Name) [$($pendingApp.ID)]" }
            return [string]$pendingApp.ID
        }
    }
    return ''
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

# Put display names here to test a few apps. Leave this empty to run every app.
$onlyNames = @(
    'Opera GX',
    'CapCut'
)
if ($onlyNames.Count -gt 0) {
    $want = @{}
    foreach ($n in $onlyNames) { $want[$n] = $true }
    $apps = @($apps | Where-Object { $want.ContainsKey($_.Name) })
    if ($apps.Count -eq 0) {
        Write-Error "None of the selected names were found in $jsonPath."
        exit 1
    }
    Write-Log "Limited to $($apps.Count) selected app(s)."
}

# One baseline only. Session progress lives on this drive so the restore,
# which rolls the registry back, does not delete the next-app index.
function Get-RestorePointSnapshot {
    $sequences = New-Object 'System.Collections.Generic.HashSet[int]'
    $points = @()
    $failed = $false
    $errorText = $null
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
    } catch {
        $failed = $true
        $errorText = $_.Exception.Message
    }
    foreach ($p in $points) {
        if ($p -and $null -ne $p.SequenceNumber) {
            [void]$sequences.Add([int]$p.SequenceNumber)
        }
    }
    return [pscustomobject]@{
        Points    = $points
        Sequences = $sequences
        Failed    = $failed
        Error     = $errorText
    }
}

function Read-RestoreSession {
    if (-not (Test-Path -LiteralPath $script:SessionPath)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $script:SessionPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Error "Could not read $($script:SessionPath). Not creating a restore point."
        exit 1
    }
    $session = @{}
    foreach ($p in $raw.PSObject.Properties) {
        $session[$p.Name] = $p.Value
    }
    return $session
}

function Save-RestoreSession {
    $dir = Split-Path -Parent $script:SessionPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$($script:SessionPath).tmp"
    $script:Session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:SessionPath -Force
}

function New-EmptySession {
    param(
        [int]$Sequence,
        $FrequencyOriginal
    )
    return @{
        description       = $script:RestorePointDescription
        sequenceNumber    = $Sequence
        createdAt         = (Get-Date).ToString('s')
        frequencyOriginal = $FrequencyOriginal
        nextIndex         = 0
        pendingRestore    = $false
        pendingIndex      = -1
        installSuccess    = 0
        installExist      = 0
        installFailure    = 0
        restoreStarted    = 0
        restoreSkipped    = 0
    }
}

function Repair-RestoreSession {
    if ($null -eq $script:Session.nextIndex) { $script:Session.nextIndex = 0 }
    if ($null -eq $script:Session.pendingRestore) { $script:Session.pendingRestore = $false }
    if ($null -eq $script:Session.pendingIndex) { $script:Session.pendingIndex = -1 }
    foreach ($name in @('installSuccess', 'installExist', 'installFailure', 'restoreStarted', 'restoreSkipped')) {
        if ($null -eq $script:Session[$name]) { $script:Session[$name] = 0 }
    }
}

function Get-SystemRestoreFrequency {
    $value = (Get-ItemProperty -Path $script:FrequencyKey -Name $script:FrequencyName -ErrorAction SilentlyContinue).$($script:FrequencyName)
    if ($null -eq $value) { return 1440 }
    return [int]$value
}

function Set-SystemRestoreFrequency {
    param([int]$Value)
    if (-not (Test-Path -LiteralPath $script:FrequencyKey)) {
        New-Item -Path $script:FrequencyKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:FrequencyKey -Name $script:FrequencyName -Value $Value -Type DWord
}

function Restore-SystemRestoreFrequency {
    if ($null -eq $script:Session -or $null -eq $script:Session.frequencyOriginal) { return }
    $wanted = [int]$script:Session.frequencyOriginal
    $current = Get-SystemRestoreFrequency
    if ($current -ne $wanted) {
        Set-SystemRestoreFrequency -Value $wanted
        Write-Log "SystemRestorePointCreationFrequency set back to $wanted."
    }
}

function Get-BaselineRestorePoints {
    param($Points)
    return @($Points | Where-Object { $_ -and $_.Description -eq $script:RestorePointDescription } | Sort-Object SequenceNumber)
}

function Select-CreatedRestorePoint {
    param($Created)
    $matched = @($Created | Where-Object { $_.Description -eq $script:RestorePointDescription } | Sort-Object SequenceNumber)
    if ($matched.Count -gt 0) { return $matched[0] }
    return @($Created | Sort-Object SequenceNumber)[0]
}

function Find-NewRestorePoint {
    param($BeforeSnapshot)
    $after = Get-RestorePointSnapshot
    $newPoints = @()
    foreach ($p in @($after.Points)) {
        if ($p -and -not $BeforeSnapshot.Sequences.Contains([int]$p.SequenceNumber)) {
            $newPoints += $p
        }
    }
    if ($newPoints.Count -eq 0) { return $null }
    if ($newPoints.Count -gt 1) {
        Write-Log "Windows created $($newPoints.Count) restore points. Using the baseline name when it is present, otherwise the oldest new point."
    }
    return (Select-CreatedRestorePoint -Created $newPoints)
}

function New-BaselineRestorePoint {
    # Only call this when no point with the baseline name exists.
    $originalFrequency = Get-SystemRestoreFrequency
    Write-Log "Creating one baseline restore point: $($script:RestorePointDescription)"
    Write-Log "This can take several minutes. This script will not create another."

    $before = Get-RestorePointSnapshot
    if ($before.Failed) {
        Write-Log "Get-ComputerRestorePoint failed: $($before.Error)"
        Write-Log "Enabling System Restore on $env:SystemDrive."
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -Confirm:$false -ErrorAction Stop
        $before = Get-RestorePointSnapshot
        if ($before.Failed) {
            Write-Error "System Restore is still unavailable: $($before.Error)"
            exit 1
        }
    }

    $already = @(Get-BaselineRestorePoints -Points $before.Points)
    if ($already.Count -gt 0) {
        $point = $already[0]
        Write-Log "Baseline restore point sequence $([int]$point.SequenceNumber) already exists. Not creating another."
        $script:Session = New-EmptySession -Sequence ([int]$point.SequenceNumber) -FrequencyOriginal $originalFrequency
        Save-RestoreSession
        return
    }

    $createdPoint = $null
    try {
        # Windows skips a new point when one was created in the last 24 hours.
        # Zero allows this one point. The original value is saved and put back.
        Set-SystemRestoreFrequency -Value 0
        for ($attempt = 1; $attempt -le 2 -and -not $createdPoint; $attempt++) {
            if ($attempt -eq 2) {
                Write-Log "No restore point appeared yet. Waiting 5 seconds, then checking once more."
                Start-Sleep -Seconds 5
                $createdPoint = Find-NewRestorePoint -BeforeSnapshot $before
                if ($createdPoint) { break }
                Write-Log "Restarting the System Restore service and trying once more."
                try {
                    $svc = Get-Service -Name srservice -ErrorAction Stop
                    if ($svc.StartType -eq 'Disabled') {
                        Set-Service -Name srservice -StartupType Manual
                    }
                    Restart-Service -Name srservice -Force -ErrorAction Stop
                } catch {
                    Write-Log "Could not restart srservice: $($_.Exception.Message)"
                }
                Set-SystemRestoreFrequency -Value 0
            }
            try {
                Checkpoint-Computer -Description $script:RestorePointDescription -RestorePointType APPLICATION_INSTALL -ErrorAction Stop
            } catch {
                Write-Log "Checkpoint-Computer attempt $attempt failed: $($_.Exception.Message)"
            }
            $createdPoint = Find-NewRestorePoint -BeforeSnapshot $before
        }
    } finally {
        Set-SystemRestoreFrequency -Value $originalFrequency
    }

    if (-not $createdPoint) {
        Write-Error "Could not create the baseline restore point. No apps were installed."
        exit 1
    }

    $seq = [int]$createdPoint.SequenceNumber
    Write-Log "Baseline restore point is sequence $seq ($($createdPoint.Description))."
    $script:Session = New-EmptySession -Sequence $seq -FrequencyOriginal $originalFrequency
    Save-RestoreSession
}

function Initialize-TestRestorePoint {
    $snapshot = Get-RestorePointSnapshot
    if ($snapshot.Failed) {
        Write-Log "Get-ComputerRestorePoint failed: $($snapshot.Error)"
        Write-Log "Enabling System Restore on $env:SystemDrive."
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -Confirm:$false -ErrorAction Stop
        $snapshot = Get-RestorePointSnapshot
        if ($snapshot.Failed) {
            Write-Error "System Restore is still unavailable: $($snapshot.Error)"
            exit 1
        }
    }

    $baseline = @(Get-BaselineRestorePoints -Points $snapshot.Points)
    $session = Read-RestoreSession

    if ($session -and $null -ne $session.sequenceNumber) {
        $seq = [int]$session.sequenceNumber
        $match = $baseline | Where-Object { [int]$_.SequenceNumber -eq $seq } | Select-Object -First 1
        if (-not $match -and $baseline.Count -gt 0) {
            $match = $baseline[0]
            Write-Log "Saved sequence $seq is missing. Reusing oldest baseline sequence $([int]$match.SequenceNumber)."
            $session.sequenceNumber = [int]$match.SequenceNumber
        }
        if ($match) {
            if ($baseline.Count -gt 1) {
                Write-Log "Found $($baseline.Count) baseline restore points. Keeping sequence $([int]$match.SequenceNumber). Not creating another."
            } else {
                Write-Log "Reusing baseline restore point sequence $([int]$match.SequenceNumber)."
            }
            $script:Session = $session
            Save-RestoreSession
            return
        }
        Write-Error "Baseline restore point $seq no longer exists. Not creating another one, because a new point would include apps installed since that baseline. Delete '$($script:SessionPath)' only when this machine is clean, then run the script again."
        exit 1
    }

    if ($baseline.Count -gt 0) {
        $point = $baseline[0]
        if ($baseline.Count -gt 1) {
            Write-Log "Found $($baseline.Count) baseline restore points. Reusing the oldest, sequence $([int]$point.SequenceNumber). Not creating another."
        } else {
            Write-Log "Found existing baseline restore point sequence $([int]$point.SequenceNumber). Not creating another."
        }
        $script:Session = New-EmptySession -Sequence ([int]$point.SequenceNumber) -FrequencyOriginal (Get-SystemRestoreFrequency)
        Save-RestoreSession
        return
    }

    New-BaselineRestorePoint
}

function Test-RestorePendingMarker {
    $value = (Get-ItemProperty -Path $script:MarkerKey -Name $script:MarkerName -ErrorAction SilentlyContinue).$($script:MarkerName)
    return ($null -ne $value)
}

function Set-RestorePendingMarker {
    if (-not (Test-Path -LiteralPath $script:MarkerKey)) {
        New-Item -Path $script:MarkerKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:MarkerKey -Name $script:MarkerName -Value 1 -Type DWord
}

function Invoke-BaselineRestore {
    $seq = [int]$script:Session.sequenceNumber
    Write-Log "Restoring to sequence $seq. Windows will restart."
    Write-Log "Run Invoke-TestRestore.ps1 again after logon. It will not create another restore point."
    Set-RestorePendingMarker
    Save-RestoreSession
    Write-Log ("Time finish: {0}  {1}" -f (Get-ProbeTimeStamp), (Get-RestoreAppLabel))
    Restore-Computer -RestorePoint $seq -Confirm:$false
    Write-Error "Restore-Computer returned without restarting Windows."
    exit 1
}

function Write-RestoreSummary {
    Write-Log ""
    Write-Log "================================================"
    Write-Log "SUMMARY"
    Write-Log "================================================"
    Write-Log "Total apps in list     : $($apps.Count)"
    Write-Log "Next app index         : $([int]$script:Session.nextIndex)"
    Write-Log "Install - success: $([int]$script:Session.installSuccess)  exist: $([int]$script:Session.installExist)  failure: $([int]$script:Session.installFailure)"
    Write-Log "Restore - started: $([int]$script:Session.restoreStarted)  skipped: $([int]$script:Session.restoreSkipped)"
    Write-Log "Baseline sequence      : $([int]$script:Session.sequenceNumber)"
    Write-Log "=== Invoke-TestRestore finished: $(Get-Date) ==="
    Write-Host ""
    Write-Host "Log saved to: $logPath"
}

$mitmCA = "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.pem"
$env:SSL_CERT_FILE = $mitmCA
$env:REQUESTS_CA_BUNDLE = $mitmCA

function Start-Mitmdump {
    param(
        [string]$OutFile,
        [string]$Mode = "local",
        [string[]]$IgnoreHosts = @(),
        [string]$LogFile = ""
    )

    if (-not (Get-Command mitmdump -ErrorAction SilentlyContinue)) {
        throw "mitmdump not found on PATH."
    }

    # Windows Update (*.update.microsoft.com) is signed by Microsoft ECC Update
    # Secure Server CA 2.1, which Windows trusts and mitmproxy's CA bundle does not.
    $mitmArgs = @("--mode", $Mode, "--ssl-insecure", "-w", $OutFile)
    foreach ($pat in $IgnoreHosts) {
        $mitmArgs += @("--ignore-hosts", $pat)
    }

    $quotedArgs = $mitmArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"','""') + '"' } else { $_ }
    }
    $argString = $quotedArgs -join ' '

    Write-Log "  Start-Process mitmdump $argString"

    $startParams = @{
        FilePath     = "mitmdump"
        ArgumentList = $argString
        WindowStyle  = 'Hidden'
        PassThru     = $true
    }

    if ($LogFile) {
        $errPath = [IO.Path]::ChangeExtension($LogFile, ".err.log")
        $startParams.RedirectStandardError  = $errPath
        $startParams.RedirectStandardOutput = $LogFile
    }

    Start-Process @startParams
}

function Wait-MitmdumpReady {
    param(
        $Process,
        [string]$LogFile,
        [int]$TimeoutSeconds = 20
    )

    # Start-Process returns before --mode local has attached WinDivert.
    # Winget's Store request is aborted if that attach happens mid-request.
    if (-not $Process) { return $false }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $Process.Refresh() } catch { }
        if ($Process.HasExited) { return $false }
        if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
            $ready = Select-String -LiteralPath $LogFile -Pattern 'Local redirector started' -Quiet -ErrorAction SilentlyContinue
            if ($ready) { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Stop-Mitmdump {
    param($Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        Start-Sleep -Milliseconds 250
    }
}

function Stop-ScreenRecording {
    $pidFile = Join-Path $env:TEMP "screenrec_ffmpeg.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return }

    $helpersEndRecPath = Join-Path $parentDir "helpers\end_rec.py"
    python $helpersEndRecPath 2>&1 | ForEach-Object {
      Write-Host $_
      if ($script:LogFileStream) {
        try {
          $logLine = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $_
          $script:LogFileStream.WriteLine($logLine)
          $script:LogFileStream.Flush()
        } catch {
          try {
            $sanitized = $_ -replace '[^\x00-\x7F]', '?'
            $script:LogFileStream.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $sanitized)
            $script:LogFileStream.Flush()
          } catch { }
        }
      }
    }
}

function Get-AllProcessIds {
    <#
      .SYNOPSIS
        Returns all current process IDs as an array of integers.
    #>
    $ids = [System.Collections.Generic.List[int]]::new()
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.Id -gt 0) { $ids.Add([int]$p.Id) }
        }
    } catch {
        Warn "Get-AllProcessIds failed: $($_.Exception.Message)"
    }
    # Emit each ID. Callers collect with @(). A leading comma nests the whole
    # list as one element, and [int[]] then fails to bind that Object[].
    return @($ids.ToArray() | Sort-Object -Unique)
}

function Stop-IdsRobust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Ids,
        [string]$AppName = "",
        [string]$PsKillPath = "",
        [switch]$Tree
    )

    $pidList = @()
    foreach ($i in $Ids) {
        if ($null -ne $i) {
            $s = "$i".Trim()
            if ($s -match '^\d+$') {
                $v = [int]$s
                if ($v -gt 0) { $pidList += $v }
            }
        }
    }
    $pidList = @($pidList | Sort-Object -Unique)

    if ($pidList.Count -eq 0) {
        Warn "No related PIDs found to terminate for '$AppName'."
        return
    }

    if ([string]::IsNullOrWhiteSpace($PsKillPath)) {
        $PsKillPath = Join-Path $parentDir "helpers\pskill64.exe"
    }

    try {
        if (Test-Path -LiteralPath $PsKillPath) {
            $killArgs = @()
            if ($Tree.IsPresent) { $killArgs += '-t' }
            $killArgs += $pidList | ForEach-Object { "$_" }

            Write-Log "$([IO.Path]::GetFileName($PsKillPath)) $($killArgs -join ' ')"
            $p = Start-Process -FilePath $PsKillPath -ArgumentList $killArgs -NoNewWindow -PassThru -Wait -ErrorAction Stop
            if ($p.ExitCode -ne 0) {
                Warn "pskill exited with code $($p.ExitCode). Falling back to Stop-Process."
                foreach ($singlePid in $pidList) {
                    try {
                        Stop-Process -Id $singlePid -Force -ErrorAction Stop
                        Write-Log "Stopped process Id $singlePid for '$AppName'."
                    } catch { Warn "Stop-Process($singlePid): $($_.Exception.Message)" }
                }
            }
        } else {
            foreach ($singlePid in $pidList) {
                try {
                    Stop-Process -Id $singlePid -Force -ErrorAction Stop
                    Write-Log "Stopped process Id $singlePid for '$AppName'."
                } catch { Warn "Stop-Process($singlePid): $($_.Exception.Message)" }
            }
        }
    } catch {
        Warn "Stop-IdsRobust failed: $($_.Exception.Message)"
    }
}

function Stop-NewProcesses {
    <#
      .SYNOPSIS
        Stops processes that were created after a baseline snapshot.
      .PARAMETER BaselinePids
        Array of process IDs that existed before the operation.
      .PARAMETER ExcludePids
        Array of process IDs to exclude from termination (the screen recorder).
      .PARAMETER AppName
        Name of the app for logging purposes.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int[]]$BaselinePids,
        [int[]]$ExcludePids = @(),
        [string]$AppName = ""
    )

    try {
        $currentPids = @(Get-AllProcessIds)
        $baselineSet = @{}
        foreach ($id in @($BaselinePids)) { $baselineSet[[int]$id] = $true }

        $newPids = @($currentPids | Where-Object { -not $baselineSet.ContainsKey([int]$_) })
        Write-Log "  Post-ID count: $($currentPids.Count); new since pre-ID: $($newPids.Count)"

        if ($ExcludePids.Count -gt 0) {
            $excludeSet = @{}
            foreach ($id in $ExcludePids) { $excludeSet[[int]$id] = $true }
            $newPids = @($newPids | Where-Object { -not $excludeSet.ContainsKey([int]$_) })
        }

        # Our own host, the recorder, and the Python helper that starts it.
        # rec.py copies ffmpeg to screenrec-recorder.exe so uninstallers that
        # kill every ffmpeg.exe do not end the capture. That copy owns a
        # console; killing its conhost closes the console end_rec.py attaches to.
        # wpr.exe is the network stack trace; killing it drops the ETL.
        $excludeNames = @{
            'powershell' = $true; 'pwsh' = $true; 'python' = $true; 'pythonw' = $true
            'mitmdump' = $true; 'ffmpeg' = $true; 'gdigrab' = $true
            'screenrec-recorder' = $true; 'conhost' = $true; 'wpr' = $true
        }
        $finalPids = @()
        foreach ($processId in $newPids) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc -and -not $excludeNames.ContainsKey($proc.ProcessName.ToLower())) {
                    $finalPids += $processId
                }
            } catch {
                # Process may have already exited.
            }
        }

        $finalPids = @($finalPids | Sort-Object -Unique)
        if ($finalPids.Count -eq 0) {
            Write-Log "  No new processes to terminate for '$AppName'."
            return
        }

        Write-Log "  Terminating new process IDs for '$AppName': $($finalPids -join ', ')"
        Stop-IdsRobust -Ids $finalPids -AppName $AppName
    } catch {
        Warn "Stop-NewProcesses failed: $($_.Exception.Message)"
    }
}

function Stop-NewProcessesExceptRecording {
    param(
        [Parameter(Mandatory=$true)][int[]]$BaselinePids,
        [int]$RecordingPid = 0,
        [int]$MitmPid = 0,
        [string]$AppName = ""
    )

    if (@($BaselinePids).Count -eq 0) {
        Warn "No baseline process IDs; skipping termination for '$AppName'."
        return
    }

    $exclude = [System.Collections.Generic.List[int]]::new()
    $exclude.Add($PID)
    if ($RecordingPid -gt 0) {
        $exclude.Add($RecordingPid)
        Write-Log "  Keeping recording process PID $RecordingPid"
    }
    if ($MitmPid -gt 0) {
        $exclude.Add($MitmPid)
        Write-Log "  Keeping mitmdump process PID $MitmPid"
    }

    $excludeArr = @($exclude | Sort-Object -Unique)
    Stop-NewProcesses -BaselinePids $BaselinePids -ExcludePids $excludeArr -AppName $AppName
}

function Stop-NewAppProcesses {
    param([string]$AppName = "")
    if (@($script:BaselinePids).Count -eq 0) {
        Warn "No baseline process IDs; skipping termination for '$AppName'."
        return
    }
    $recId = 0
    if ($script:RecordingPid) { $recId = [int]$script:RecordingPid }
    $mitmId = 0
    if ($script:MitmProc -and -not $script:MitmProc.HasExited) {
        $mitmId = [int]$script:MitmProc.Id
    }
    Stop-NewProcessesExceptRecording -BaselinePids $script:BaselinePids -RecordingPid $recId -MitmPid $mitmId -AppName $AppName
}

function Stop-MitmCapture {
    if ($script:MitmStopped) { return }
    $script:MitmStopped = $true
    $proc = $script:MitmProc
    if (-not $proc) { return }
    Stop-Mitmdump -Process $proc
    $script:MitmProc = $null
    $dumpFile = $script:MitmDumpFile
    if ($dumpFile -and (Test-Path -LiteralPath $dumpFile)) {
        $dumpSize = (Get-Item -LiteralPath $dumpFile).Length
        Write-Log "  Mitmdump stopped; output saved to $dumpFile (size: $dumpSize bytes)"
    } elseif ($dumpFile) {
        Warn "Mitmdump output file not found at $dumpFile"
    }
}

function Start-NetworkStackCapture {
    param(
        [Parameter(Mandatory=$true)][string]$TempDirectory,
        [Parameter(Mandatory=$true)][string]$EtlFile
    )

    if (-not (Test-Path -LiteralPath $startNetworkStackTrace)) {
        Warn "Start-NetworkStackTrace.ps1 not found: $startNetworkStackTrace"
        return
    }

    try {
        & $startNetworkStackTrace -OutputDirectory $TempDirectory
        $script:NetworkStackEtl = $EtlFile
        $script:NetworkStackStarted = $true
        Write-Log "  Network stack trace recording; will write $EtlFile"
    } catch {
        $script:NetworkStackStarted = $false
        $script:NetworkStackEtl = $null
        Warn "Network stack trace failed to start: $($_.Exception.Message)"
    }
}

function Stop-NetworkStackCapture {
    if (-not $script:NetworkStackStarted) { return }
    $script:NetworkStackStarted = $false
    $etlFile = $script:NetworkStackEtl
    $script:NetworkStackEtl = $null

    if (-not (Test-Path -LiteralPath $stopNetworkStackTrace)) {
        Warn "Stop-NetworkStackTrace.ps1 not found: $stopNetworkStackTrace"
        return
    }

    try {
        # wpr -stop refuses to replace an existing file. -Force only skips the script's own check.
        if ($etlFile -and (Test-Path -LiteralPath $etlFile)) {
            Remove-Item -LiteralPath $etlFile -Force
        }
        if ($etlFile) {
            & $stopNetworkStackTrace -OutputFile $etlFile -Force
        } else {
            & $stopNetworkStackTrace -Force
        }
        if ($etlFile -and (Test-Path -LiteralPath $etlFile)) {
            $etlSize = (Get-Item -LiteralPath $etlFile).Length
            Write-Log "  Network stack trace stopped; output saved to $etlFile (size: $etlSize bytes)"
        } elseif ($etlFile) {
            Warn "Network stack trace output file not found at $etlFile"
        }
    } catch {
        Warn "Network stack trace failed to stop: $($_.Exception.Message)"
    }
}

function Stop-AppLeftoversThenRecording {
    param([string]$AppName = "")
    # The outer finally also calls this. Skip the second process sweep
    # after this app was already cleaned.
    if (-not $script:LeftoversCleared) {
        Stop-NewAppProcesses -AppName $AppName
        $script:LeftoversCleared = $true
    }
    Stop-NetworkStackCapture
    Stop-MitmCapture
    Stop-ScreenRecording
}

# UAC normally runs on the secure desktop, which screen capture cannot read.
# Show prompts on the normal desktop for this run, then put the setting back
# before restore. The baseline point is created before this change.
$script:TweaksEnabled = $false
$script:UacChanged = $false
$script:UacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:UacSecureDesktopOriginal = $null

function Enable-TestSessionTweaks {
    if ($script:TweaksEnabled) { return }
    $script:UacSecureDesktopOriginal = (Get-ItemProperty -Path $script:UacKey -Name PromptOnSecureDesktop -ErrorAction SilentlyContinue).PromptOnSecureDesktop
    if ($null -eq $script:UacSecureDesktopOriginal) { $script:UacSecureDesktopOriginal = 1 }
    $script:UacChanged = $false
    $script:TweaksEnabled = $true
    if ($script:UacSecureDesktopOriginal -ne 0) {
        Set-ItemProperty -Path $script:UacKey -Name PromptOnSecureDesktop -Value 0 -Type DWord
        $script:UacChanged = $true
        Write-Log "UAC prompts will show on the normal desktop during this run (restored at the end)."
    }
    winget settings --enable BypassCertificatePinningForMicrosoftStore
    Write-Log "BypassCertificatePinningForMicrosoftStore enabled."
}

function Disable-TestSessionTweaks {
    if (-not $script:TweaksEnabled) { return }
    $script:TweaksEnabled = $false
    if ($script:UacChanged) {
        Set-ItemProperty -Path $script:UacKey -Name PromptOnSecureDesktop -Value $script:UacSecureDesktopOriginal -Type DWord
        Write-Log "UAC secure desktop setting restored."
        $script:UacChanged = $false
    }
    winget settings --disable BypassCertificatePinningForMicrosoftStore
    Write-Log "BypassCertificatePinningForMicrosoftStore disabled."
}

Write-Log "=== Invoke-TestRestore started: $(Get-Date) ==="
Write-Log "Loaded $($apps.Count) app(s) from $jsonPath"

Initialize-TestRestorePoint
Repair-RestoreSession

if (Test-RestorePendingMarker) {
    Write-Host "Previous restore did not finish, start to restore" -ForegroundColor Yellow
    Add-Content -Path $logPath -Value "Previous restore did not finish, start to restore"
    Invoke-BaselineRestore
}

if ($script:Session.pendingRestore -eq $true) {
    $doneIndex = [int]$script:Session.pendingIndex
    Write-Log "Restore completed. Next app index is $($doneIndex + 1)."
    $script:Session.nextIndex = $doneIndex + 1
    $script:Session.pendingRestore = $false
    $script:Session.pendingIndex = -1
    Save-RestoreSession
}

Restore-SystemRestoreFrequency

Write-Log "Baseline restore point sequence $([int]$script:Session.sequenceNumber). This script will not create another."
Write-Log "Session file: $($script:SessionPath)"
Write-Log "Next app index: $([int]$script:Session.nextIndex)"

if ([int]$script:Session.nextIndex -ge $apps.Count) {
    Write-RestoreSummary
    exit 0
}

# ================================================================
# MAIN LOOP - Install then restore per app
# ================================================================
$script:BaselinePids = @()
$script:RecordingPid = $null
$script:MitmProc = $null
$script:MitmDumpFile = $null
$script:MitmStopped = $false
$script:NetworkStackStarted = $false
$script:NetworkStackEtl = $null
$script:LeftoversCleared = $false
$label = ''

try {
    Enable-TestSessionTweaks
    for ($i = [int]$script:Session.nextIndex; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]
        $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

        # Pre-ID: everything already running before this app, including before the recorder starts.
        $script:BaselinePids = @(Get-AllProcessIds)
        $script:RecordingPid = $null
        $script:MitmProc = $null
        $script:MitmDumpFile = $null
        $script:MitmStopped = $false
        $script:NetworkStackStarted = $false
        $script:NetworkStackEtl = $null
        $script:LeftoversCleared = $false

        $helpersRecPath = Join-Path $parentDir "helpers\rec.py"
        $recOutPath = Join-Path $recDir "$($label -replace '[^a-zA-Z0-9]', '_').mp4"
        Write-Log ("Time start: {0}  {1}" -f (Get-ProbeTimeStamp), $label)

        # Start recording and capture the FFmpeg PID
        $recordingPid = $null
        python $helpersRecPath --grab gdigrab --cursor --out $recOutPath 2>&1 | ForEach-Object {
          Write-Host $_
          # Try to extract PID from the output (format: "Recording started (PID 21196)")
          if ($_ -match 'Recording started \(PID (\d+)\)') {
            $recordingPid = [int]$Matches[1]
            Info "Captured recording FFmpeg PID: $recordingPid"
          }
          if ($script:LogFileStream) {
            try {
              $logLine = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $_
              $script:LogFileStream.WriteLine($logLine)
              $script:LogFileStream.Flush()
            } catch {
              # If encoding fails, try to write a sanitized version
              try {
                $sanitized = $_ -replace '[^\x00-\x7F]', '?'
                $script:LogFileStream.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $sanitized)
                $script:LogFileStream.Flush()
              } catch {
                # If even sanitized version fails, skip logging this line
              }
            }
          }
        }

        # If PID wasn't captured from output, try reading from the PID file
        if (-not $recordingPid) {
          $pidFile = Join-Path $env:TEMP "screenrec_ffmpeg.pid"
          if (Test-Path -LiteralPath $pidFile) {
            try {
              $recordingPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
              Info "Read recording FFmpeg PID from file: $recordingPid"
            } catch {
              Warn "Failed to read recording PID from file: $($_.Exception.Message)"
            }
          }
        }
        $script:RecordingPid = $recordingPid

        $stem = ($label -replace '[^a-zA-Z0-9]', '_')
        $dumpFile = Join-Path $netdumpDir "$stem.mitm"
        $etlFile = Join-Path $etlDir "$stem.etl"
        $mitmLogPath = Join-Path $mitmLogDir "$stem.mitmdump.log"
        $script:MitmDumpFile = $dumpFile
        if (Test-Path -LiteralPath $mitmLogPath) {
            Remove-Item -LiteralPath $mitmLogPath -Force -ErrorAction SilentlyContinue
        }
        try {
            $script:MitmProc = Start-Mitmdump -OutFile $dumpFile -Mode local -IgnoreHosts @(
                '(^|\.)generativelanguage\.googleapis\.com$', '(^|\.)gradio\.live$'
            ) -LogFile $mitmLogPath
            if ($script:MitmProc) {
                Write-Log "  mitmdump PID $($script:MitmProc.Id) writing to $dumpFile"
            } else {
                Warn "mitmdump failed to start; no process object returned."
            }
            $mitmReady = Wait-MitmdumpReady -Process $script:MitmProc -LogFile $mitmLogPath
            if ($script:MitmProc -and $script:MitmProc.HasExited) {
                $code = $script:MitmProc.ExitCode
                Warn "mitmdump exited immediately with code $code"
                if (Test-Path -LiteralPath $mitmLogPath) {
                    $tail = Get-Content -LiteralPath $mitmLogPath -Tail 20 -ErrorAction SilentlyContinue
                    foreach ($line in $tail) { Warn "mitmdump: $line" }
                }
            } elseif ($script:MitmProc -and -not $mitmReady) {
                Warn "mitmdump local redirector was not ready after 20s. Store install may be aborted."
            } elseif ($mitmReady) {
                Write-Log "  mitmdump local redirector is ready."
            }
            if ($script:MitmProc -and -not $script:MitmProc.HasExited) {
                $stackTemp = Join-Path $networkStackTempDir $stem
                Start-NetworkStackCapture -TempDirectory $stackTemp -EtlFile $etlFile
            }
        } catch {
            Warn "mitmdump failed to start: $($_.Exception.Message)"
            $script:MitmProc = $null
        }

        Write-Log ""
        Write-Log "------------------------------------------------"
        Write-Log "[$($i + 1)/$($apps.Count)] $label"
        Write-Log "------------------------------------------------"
        Write-Log "  Pre-ID count: $(@($script:BaselinePids).Count)"

        $restoreThisApp = $false
        try {
            # -- STEP 1: INSTALL (same approach as scripts/install.ps1) --
            Write-Host "  Installing..."

            $startTime   = Get-Date
            $outputLines  = @()
            $errorText    = $null

            try {
                # These ids are Microsoft Store product ids. Search msstore only so a
                # failure in the community "winget" source cannot abort the install.
                $null = & winget install --id $app.ID --source msstore --accept-source-agreements --accept-package-agreements 2>&1 |
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
                $script:Session.installFailure = [int]$script:Session.installFailure + 1
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
                $script:Session.installExist = [int]$script:Session.installExist + 1
            } else {
                $script:Session.installSuccess = [int]$script:Session.installSuccess + 1
            }

            Write-Log $installLog

            # -- STEP 2: RESTORE (only if the install succeeded) --
            if ($status -eq 'exist' -or $status -eq 'failure') {
                Write-Log "  Skipping restore - app already existed or installation failed."
                $script:Session.restoreSkipped = [int]$script:Session.restoreSkipped + 1
                $script:Session.nextIndex = $i + 1
                Save-RestoreSession
                continue
            }

            # Marker first: a crash while stopping the capture must still restore
            # on the next run, and must not look like a finished restore.
            Set-RestorePendingMarker
            $script:Session.pendingRestore = $true
            $script:Session.pendingIndex = $i
            $script:Session.restoreStarted = [int]$script:Session.restoreStarted + 1
            Save-RestoreSession
            Write-Host "Installation finish, start to restore" -ForegroundColor Yellow
            Add-Content -Path $logPath -Value "Installation finish, start to restore"
            $restoreThisApp = $true
        } finally {
            Stop-AppLeftoversThenRecording -AppName $label
        }

        if ($restoreThisApp) {
            Disable-TestSessionTweaks
            Invoke-BaselineRestore
        }
    }
}
finally {
    Stop-AppLeftoversThenRecording -AppName $label
    Disable-TestSessionTweaks
}

Write-RestoreSummary
