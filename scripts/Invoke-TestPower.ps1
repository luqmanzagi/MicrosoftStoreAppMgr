# Invoke-TestPower.ps1
# For each app in result/app_1.json:
#   1. Snapshot pre-ID, start recording, start mitm
#   2. Install it  (same logic as scripts/install.ps1)
#   3. Stop new processes (except recorder and mitm), then uninstall
#      if it was NOT already installed ('exist')
#      using scripts/Remove-SingleApplication.ps1
#   4. While that runs, click Uninstall / Remove / Next on dialogs
#      that normal winget leaves on screen
#   5. Wait until the uninstall window is gone
#   6. Stop leftover processes, stop mitm, then stop recording
# Then move on to the next app.

# -- Path setup --
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$jsonPath          = Join-Path $parentDir 'results\app_test.json'
$uninstallScript   = Join-Path $scriptDir 'Remove-SingleApplication.new.ps1'

# Validate required files
if (-not (Test-Path $jsonPath)) {
    Write-Error "JSON file not found: $jsonPath"
    exit 1
}
if (-not (Test-Path $uninstallScript)) {
    Write-Error "Uninstall script not found: $uninstallScript"
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

$mitmLogDir = Join-Path $parentDir 'results\logs\mitmdump'
if (-not (Test-Path -LiteralPath $mitmLogDir)) {
    New-Item -ItemType Directory -Path $mitmLogDir -Force | Out-Null
}

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
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [INFO ] $msg"
    Write-Host "[INFO ] $msg" -ForegroundColor Cyan
    if ($script:LogFileStream) {
        $script:LogFileStream.WriteLine($logMsg)
        $script:LogFileStream.Flush()
    }
}

function Warn($msg) {
    Write-Log "[WARN ] $msg" -ForegroundColor Yellow
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

Write-Log "=== Invoke-TestPower started: $(Get-Date) ==="
Write-Log "Loaded $($apps.Count) app(s) from $jsonPath"

# Counters for final summary
$totalExist   = 0
$totalSuccess = 0
$totalFailure = 0
$totalUninstallSuccess = 0
$totalUninstallFailure = 0
$totalSkipped = 0

# Uninstall method counters (attempts / success / failure)
$uniMethodNames = @(
    'Remove-AppxPackage',
    'QuietUninstallString',
    'msiexec',
    'UninstallString',
    'winget',
    'not found',
    'no uninstall string',
    'no display name',
    'unknown'
)
$uniMethodTotal   = @{}
$uniMethodSuccess = @{}
$uniMethodFailure = @{}
foreach ($name in $uniMethodNames) {
    $uniMethodTotal[$name]   = 0
    $uniMethodSuccess[$name] = 0
    $uniMethodFailure[$name] = 0
}

function Get-UninstallMethod {
    param([string]$Text)
    $m = [regex]::Match($Text, 'UNINSTALL_METHOD=([^\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    if ($Text -match 'Using Remove-AppxPackage') { return 'Remove-AppxPackage' }
    if ($Text -match 'Using QuietUninstallString:.*msiexec') { return 'msiexec' }
    if ($Text -match 'Using QuietUninstallString') { return 'QuietUninstallString' }
    if ($Text -match 'Using UninstallString') { return 'UninstallString' }
    if ($Text -match 'Using winget uninstall' -or $Text -match 'Falling back to winget') { return 'winget' }
    if ($Text -match 'No application found matching') { return 'not found' }
    if ($Text -match 'No uninstall string available') { return 'no uninstall string' }
    return 'unknown'
}

function Add-UninstallMethodCount {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Status
    )
    if (-not $uniMethodTotal.ContainsKey($Method)) {
        $uniMethodTotal[$Method]   = 0
        $uniMethodSuccess[$Method] = 0
        $uniMethodFailure[$Method] = 0
        $script:uniMethodNames += $Method
    }
    $uniMethodTotal[$Method] = $uniMethodTotal[$Method] + 1
    if ($Status -eq 'success') {
        $uniMethodSuccess[$Method] = $uniMethodSuccess[$Method] + 1
    } else {
        $uniMethodFailure[$Method] = $uniMethodFailure[$Method] + 1
    }
}

# Visible top-level windows, used to notice an uninstall dialog that outlives winget.
if (-not ('ScreenRecWindowEnum' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ScreenRecWindowEnum {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static string[] GetVisibleWindows() {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            if (GetWindowText(h, sb, sb.Capacity) <= 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            list.Add(h.ToInt64().ToString() + "\t" + pid.ToString() + "\t" + sb.ToString());
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@
}

$script:UiIgnoreProcs = @{
    'powershell' = $true; 'pwsh' = $true; 'cmd' = $true; 'conhost' = $true
    'cursor' = $true; 'code' = $true; 'explorer' = $true; 'ffmpeg' = $true
    'python' = $true; 'pythonw' = $true; 'windowsterminal' = $true
    'openconsole' = $true; 'searchhost' = $true; 'shellexperiencehost' = $true
    'startmenuexperiencehost' = $true; 'textinputhost' = $true
    'applicationframehost' = $true; 'systemsettings' = $true; 'lockapp' = $true
    'dwm' = $true; 'sihost' = $true; 'taskhostw' = $true; 'ctfmon' = $true
    'securityhealthsystray' = $true; 'widgets' = $true; 'widgetservice' = $true
    'phoneexperiencehost' = $true; 'runtimebroker' = $true; 'dllhost' = $true
    'backgroundtaskhost' = $true; 'svchost' = $true; 'smartscreen' = $true
    'comppkgsrv' = $true
}

function Get-VisibleWindowMap {
    $map = @{}
    foreach ($line in [ScreenRecWindowEnum]::GetVisibleWindows()) {
        $parts = $line -split "`t", 3
        $procName = $null
        try {
            $procName = (Get-Process -Id ([int]$parts[1]) -ErrorAction Stop).ProcessName
        } catch { }
        $map[[int64]$parts[0]] = [pscustomobject]@{
            Handle      = [int64]$parts[0]
            Pid         = [int]$parts[1]
            ProcessName = $procName
            Title       = $parts[2]
        }
    }
    # Comma keeps the hashtable intact. PowerShell would otherwise enumerate it.
    return ,$map
}

function Test-UninstallUiCandidate {
    param($Window, [string]$AppName)
    $proc = [string]$Window.ProcessName
    $title = [string]$Window.Title
    if (-not $proc -and -not $title) { return $false }
    if ($Window.Pid -eq $PID) { return $false }
    if ($proc -and $script:UiIgnoreProcs.ContainsKey($proc.ToLower())) { return $false }

    $compact = ($AppName -replace '[^A-Za-z0-9]', '')
    if ($AppName -and $title -like "*$AppName*") { return $true }
    if ($compact.Length -ge 3 -and $proc -like "*$compact*") { return $true }
    if ($title -match '(?i)uninstall|uninstaller|\bsetup\b|installer|user account control|windows installer') { return $true }
    if ($proc -match '(?i)^(unins\d*|uninstall.*|setup|msiexec|consent|winget|appinstaller)$') { return $true }
    return $false
}

function Get-UninstallBlockers {
    param(
        [hashtable]$Before,
        [string]$AppName,
        [datetime]$StartedAt
    )
    $hits = @()
    $now = Get-VisibleWindowMap
    foreach ($handle in @($now.Keys)) {
        $win = $now[$handle]
        if (-not (Test-UninstallUiCandidate -Window $win -AppName $AppName)) { continue }
        $isNew = -not $Before.ContainsKey($handle)
        $titleChanged = $false
        if (-not $isNew -and $Before[$handle].Title -ne $win.Title) { $titleChanged = $true }
        if ($isNew -or $titleChanged) { $hits += $win }
    }

    $since = $StartedAt.AddSeconds(-2)
    $seenPid = @{}
    foreach ($hit in $hits) { $seenPid[$hit.Pid] = $true }
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($seenPid.ContainsKey($_.Id)) { return }
        $name = [string]$_.ProcessName
        if (-not $name) { return }
        if ($script:UiIgnoreProcs.ContainsKey($name.ToLower())) { return }
        $started = $null
        try { $started = $_.StartTime } catch { return }
        if ($started -lt $since) { return }
        # Windowless leftovers of the app itself are ignored. These are the
        # tools that keep an uninstall dialog alive after winget has returned.
        if ($name -match '(?i)^(unins\d*|uninstall.*|setup|msiexec|consent|winget|appinstaller)$') {
            $hits += [pscustomobject]@{
                Handle = 0; Pid = $_.Id; ProcessName = $name; Title = ''
            }
        }
    }
    return @($hits)
}

function Wait-UninstallUi {
    param(
        [hashtable]$Before,
        [string]$AppName,
        [datetime]$StartedAt,
        [int]$AppearSeconds = 8,
        [int]$QuietSeconds = 3,
        [int]$TimeoutSeconds = 600
    )
    # winget often returns while the product's uninstall dialog is still open.
    # Keep the screen recording running until that dialog is gone.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $graceUntil = (Get-Date).AddSeconds($AppearSeconds)
    $saw = $false
    $clearSince = $null
    $lastDesc = ''

    while ((Get-Date) -lt $deadline) {
        $blockers = @(Get-UninstallBlockers -Before $Before -AppName $AppName -StartedAt $StartedAt)
        if ($blockers.Count -gt 0) {
            $saw = $true
            $clearSince = $null
            $graceUntil = (Get-Date).AddSeconds($AppearSeconds)
            $desc = @(
                $blockers | ForEach-Object {
                    if ($_.Title) { "$($_.ProcessName): $($_.Title)" }
                    else { "$($_.ProcessName) is still running" }
                } | Select-Object -Unique
            ) -join '; '
            if ($desc -ne $lastDesc) {
                Write-Log "  Uninstall still in progress: $desc"
                $lastDesc = $desc
            }
        } elseif ($saw) {
            if (-not $clearSince) { $clearSince = Get-Date }
            $quiet = ((Get-Date) - $clearSince).TotalSeconds -ge $QuietSeconds
            if ($quiet -and (Get-Date) -gt $graceUntil) {
                Write-Log "  Uninstall window closed."
                return
            }
        } elseif ((Get-Date) -gt $graceUntil) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Log "  Timed out waiting for the uninstall window to close."
}

# Clicks Uninstall, Remove, Next, and the other progress buttons on wizard
# dialogs while winget is blocked. pywinauto helper based on uni4.py.
# A form selects Uninstall first. Runs as a separate process so the
# uninstall script can stay synchronous.
$script:UninstallUiProc = $null
$uninstallUiScript = Join-Path $parentDir 'helpers\drive_uninstall_ui.py'

function ConvertTo-ProcessArgList {
    param([string[]]$Parts)
    ($Parts | ForEach-Object {
        $s = [string]$_
        if ($s -notmatch '[\s"]') { return $s }
        '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"'
    }) -join ' '
}

function Start-UninstallDialogDriver {
    param([string]$AppName)
    Stop-UninstallDialogDriver
    if (-not (Test-Path -LiteralPath $uninstallUiScript)) {
        Warn "Uninstall UI helper not found: $uninstallUiScript"
        return
    }
    $argString = ConvertTo-ProcessArgList @(
        '-u'
        $uninstallUiScript
        '--watch'
        '--app-name'
        $AppName
        '--log'
        $logPath
        '--ignore-pid'
        "$PID"
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'python'
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:UninstallUiProc = [System.Diagnostics.Process]::Start($psi)
        Write-Log "  Watching for uninstall dialogs (pywinauto PID $($script:UninstallUiProc.Id))."
    } catch {
        Warn "Could not start uninstall dialog driver: $($_.Exception.Message)"
    }
}

function Stop-UninstallDialogDriver {
    $proc = $script:UninstallUiProc
    $script:UninstallUiProc = $null
    if (-not $proc) { return }
    try { $proc.Refresh() } catch { }
    try {
        if ($proc.HasExited) { return }
    } catch { }
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Write-Log "  Stopped uninstall dialog watcher."
    } catch {
        Warn "Could not stop uninstall dialog driver: $($_.Exception.Message)"
    }
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

    $mitmArgs = @("--mode", $Mode, "-w", $OutFile)
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
        $excludeNames = @{
            'powershell' = $true; 'pwsh' = $true; 'python' = $true; 'pythonw' = $true
            'mitmdump' = $true; 'ffmpeg' = $true; 'gdigrab' = $true
            'screenrec-recorder' = $true; 'conhost' = $true
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

function Stop-AppLeftoversThenRecording {
    param([string]$AppName = "")
    # Always run leftover cleanup after uninstall. The outer finally also calls
    # this; skip only that second pass after this app was already cleaned.
    if (-not $script:LeftoversCleared) {
        Stop-NewAppProcesses -AppName $AppName
        $script:LeftoversCleared = $true
    }
    Stop-MitmCapture
    Stop-ScreenRecording
}

# UAC normally runs on the secure desktop, which screen capture cannot read:
# gdigrab fails with "Failed to capture image (error 5)" and FFmpeg exits.
# Show prompts on the normal desktop for this run, then restore the setting.
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacSecureDesktopOriginal = $null
$uacConsentPromptAdminOriginal = $null
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $uacConsentPromptAdminOriginal = (Get-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
    if ($null -eq $uacConsentPromptAdminOriginal) { $uacConsentPromptAdminOriginal = 5 }
    $uacSecureDesktopOriginal = (Get-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -ErrorAction SilentlyContinue).PromptOnSecureDesktop
    if ($null -eq $uacSecureDesktopOriginal) { $uacSecureDesktopOriginal = 1 }
    if ($uacSecureDesktopOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -Value 0 -Type DWord
        Write-Log "UAC prompts will show on the normal desktop during this run (restored at the end)."
    }
} else {
    Write-Log "WARNING: not running as administrator; UAC prompts stay on the secure desktop and will stop the recording."
}
winget settings --enable BypassCertificatePinningForMicrosoftStore
Write-Log "BypassCertificatePinningForMicrosoftStore enabled."

# ================================================================
# MAIN LOOP - Install then Uninstall per app
# ================================================================
$script:BaselinePids = @()
$script:RecordingPid = $null
$script:MitmProc = $null
$script:MitmDumpFile = $null
$script:MitmStopped = $false
$script:LeftoversCleared = $false
$label = ''

try {
for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

    # Pre-ID: everything already running before this app, including before the recorder starts.
    $script:BaselinePids = @(Get-AllProcessIds)
    $script:RecordingPid = $null
    $script:MitmProc = $null
    $script:MitmDumpFile = $null
    $script:MitmStopped = $false
    $script:LeftoversCleared = $false

    $helpersRecPath = Join-Path $parentDir "helpers\rec.py"
    $recOutPath = Join-Path $recDir "$($label -replace '[^a-zA-Z0-9]', '_').mp4"
    
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
    } catch {
        Warn "mitmdump failed to start: $($_.Exception.Message)"
        $script:MitmProc = $null
    }

    Write-Log ""
    Write-Log "------------------------------------------------"
    Write-Log "[$($i + 1)/$($apps.Count)] $label"
    Write-Log "------------------------------------------------"
    Write-Log "  Pre-ID count: $(@($script:BaselinePids).Count)"

    Start-UninstallDialogDriver -AppName $(if ($app.Name) { $app.Name } else { $label })
    try {

    # -- STEP 1: INSTALL (same approach as scripts/install.ps1) --
    Write-Host "  Installing..."

    $startTime   = Get-Date
    $outputLines  = @()
    $errorText    = $null

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
        $totalFailure++
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
        $totalExist++
    } else {
        $totalSuccess++
    }

    Write-Log $installLog

    # -- STEP 2: UNINSTALL (only if NOT 'exist' or 'failure') --
    if ($status -eq 'exist' -or $status -eq 'failure') {
        Write-Log "  Skipping uninstall - app already existed or installation failed."
        $totalSkipped++
        Stop-AppLeftoversThenRecording -AppName $label
        continue
    }

    Write-Host "  Uninstalling via Remove-SingleApplication..."

    # Remove-SingleApplication.ps1 expects -ApplicationName (display name)
    $appName = $app.Name
    if (-not $appName) {
        Write-Log "  Skipping uninstall - no display name available for registry lookup."
        $totalUninstallFailure++
        Add-UninstallMethodCount -Method 'no display name' -Status 'failure'
        Stop-AppLeftoversThenRecording -AppName $label
        continue
    }

    $startTime = Get-Date
    $uniOutput = $null
    $uniExit   = 0
    $uiBefore  = Get-VisibleWindowMap

    # Some apps refuse to uninstall while they are still running.
    Write-Log "  Stopping new processes before uninstall."
    Stop-NewAppProcesses -AppName $appName

    if ($isAdmin -and $null -ne $uacConsentPromptAdminOriginal -and $uacConsentPromptAdminOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord
        Write-Log "UAC Consent Prompt Behavior Admin will be restored at the end."
    }

    try {
        # *>&1 captures Write-Host (information stream) as well as success and error output.
        $uniOutput = & $uninstallScript -ApplicationName $appName -Id $app.ID *>&1
        $uniExit   = $LASTEXITCODE
    }
    catch {
        $uniOutput = $_.Exception.Message
        $uniExit   = 1
    }
    finally {
        $endTime = Get-Date
        $elapsed = New-TimeSpan -Start $startTime -End $endTime
    }

    $uniLines = @(
        foreach ($item in @($uniOutput)) {
            if ($null -eq $item) { continue }
            $line = if ($item -is [System.Management.Automation.ErrorRecord]) {
                $item.ToString()
            } elseif ($item -is [System.Management.Automation.InformationRecord]) {
                [string]$item.MessageData
            } elseif ($item -is [System.Management.Automation.WarningRecord]) {
                $item.Message
            } else {
                [string]$item
            }
            if ($line -match '\S') { Write-Log "    $line" }
            $line
        }
    )

    # Check for errors in the output as well (Remove-SingleApplication uses Write-Error + exit 1)
    $uniText = ($uniLines -join "`n")
    $uniMethod = Get-UninstallMethod -Text $uniText
    if ($uniExit -ne 0) {
        $uniStatus = 'failure'
    } elseif ($uniMethod -eq 'winget') {
        $uniStatus = 'success'
    } elseif ($uniText -match '(?i)(error|not found|no application found)') {
        $uniStatus = 'failure'
    } else {
        $uniStatus = 'success'
    }

    if ($uniStatus -eq 'success') { $totalUninstallSuccess++ } else { $totalUninstallFailure++ }

    Add-UninstallMethodCount -Method $uniMethod -Status $uniStatus

    $uninstallLog = "  Uninstall {0} took {1} => {2} ({3})" -f $label, $elapsed.ToString("mm\:ss"), $uniStatus, $uniMethod
    if ($uniStatus -eq 'failure' -and $uniText) {
        $errDetail = ($uniText -split "`n" |
            Where-Object {
                $_.Trim().Length -gt 0 -and
                $_ -match '(?i)(failed|exit code|no installed package|no application|not found|error)' -and
                $_ -notmatch 'CategoryInfo|FullyQualifiedErrorId|WriteErrorException'
            } |
            Select-Object -First 2) -join '; '
        if ($errDetail) {
            if ($errDetail.Length -gt 200) { $errDetail = $errDetail.Substring(0, 197) + '...' }
            $uninstallLog += " - $errDetail"
        }
    }
    Write-Log $uninstallLog

    Wait-UninstallUi -Before $uiBefore -AppName $appName -StartedAt $startTime
    } finally {
        Stop-UninstallDialogDriver
    }
    Stop-AppLeftoversThenRecording -AppName $label
}
}
finally {
    Stop-UninstallDialogDriver
    Stop-AppLeftoversThenRecording -AppName $label
    if ($isAdmin -and $null -ne $uacSecureDesktopOriginal -and $uacSecureDesktopOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -Value $uacSecureDesktopOriginal -Type DWord
        Write-Log "UAC secure desktop setting restored."
    }
    if ($isAdmin -and $null -ne $uacConsentPromptAdminOriginal -and $uacConsentPromptAdminOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name ConsentPromptBehaviorAdmin -Value $uacConsentPromptAdminOriginal -Type DWord
        Write-Log "UAC consent prompt behavior admin setting restored."
    }
}

# -- Summary --
Write-Log ""
Write-Log "================================================"
Write-Log "SUMMARY"
Write-Log "================================================"
Write-Log "Total apps processed : $($apps.Count)"
Write-Log "Install   - success: $totalSuccess exist: $totalExist    failure: $totalFailure"
Write-Log "Uninstall - success: $totalUninstallSuccess  failure: $totalUninstallFailure  skipped: $totalSkipped"
Write-Log "Uninstall methods:"
foreach ($name in $uniMethodNames) {
    $n = $uniMethodTotal[$name]
    if ($n -eq 0 -and $name -eq 'unknown') { continue }
    Write-Log ("  {0,-22} : {1}  (success: {2}  failure: {3})" -f $name, $n, $uniMethodSuccess[$name], $uniMethodFailure[$name])
}
Write-Log "=== Invoke-TestPower finished: $(Get-Date) ==="
Write-Host ""
winget settings --disable BypassCertificatePinningForMicrosoftStore
Write-Log "BypassCertificatePinningForMicrosoftStore disabled."
Write-Host "Log saved to: $logPath"

