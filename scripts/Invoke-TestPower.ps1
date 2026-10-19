# Invoke-TestPower.ps1
# For each app in result/app_1.json:
#   1. Install it  (same logic as scripts/install.ps1)
#   2. Immediately uninstall it if it was NOT already installed ('exist')
#      using scripts/Remove-SingleApplication.ps1
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

# -- Logging --
$logDir = Join-Path $parentDir 'logs\test'
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

# UAC normally runs on the secure desktop, which screen capture cannot read:
# gdigrab fails with "Failed to capture image (error 5)" and FFmpeg exits.
# Show prompts on the normal desktop for this run, then restore the setting.
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uacSecureDesktopOriginal = $null
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $uacSecureDesktopOriginal = (Get-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -ErrorAction SilentlyContinue).PromptOnSecureDesktop
    if ($null -eq $uacSecureDesktopOriginal) { $uacSecureDesktopOriginal = 1 }
    if ($uacSecureDesktopOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -Value 0 -Type DWord
        Write-Log "UAC prompts will show on the normal desktop during this run (restored at the end)."
    }
} else {
    Write-Log "WARNING: not running as administrator; UAC prompts stay on the secure desktop and will stop the recording."
}

# ================================================================
# MAIN LOOP - Install then Uninstall per app
# ================================================================
try {
for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $label = if ($app.Name) { "$($app.Name) [$($app.ID)]" } else { $app.ID }

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

    Write-Log ""
    Write-Log "------------------------------------------------"
    Write-Log "[$($i + 1)/$($apps.Count)] $label"
    Write-Log "------------------------------------------------"

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

    # -- STEP 2: UNINSTALL (only if NOT 'exist') --
    if ($status -eq 'exist') {
        Write-Log "  Skipping uninstall - app already existed."
        $totalSkipped++
        Stop-ScreenRecording
        continue
    }

    Write-Host "  Uninstalling via Remove-SingleApplication..."

    # Remove-SingleApplication.ps1 expects -ApplicationName (display name)
    $appName = $app.Name
    if (-not $appName) {
        Write-Log "  Skipping uninstall - no display name available for registry lookup."
        $totalUninstallFailure++
        Add-UninstallMethodCount -Method 'no display name' -Status 'failure'
        Stop-ScreenRecording
        continue
    }

    $startTime = Get-Date
    $uniOutput = $null
    $uniExit   = 0
    $uiBefore  = Get-VisibleWindowMap

    try {
        $uniOutput = & $uninstallScript -ApplicationName $appName -Id $app.ID 2>&1
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

    # Check for errors in the output as well (Remove-SingleApplication uses Write-Error + exit 1)
    $uniText = ($uniOutput | Out-String)
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
    Stop-ScreenRecording
}
}
finally {
    Stop-ScreenRecording
    if ($isAdmin -and $null -ne $uacSecureDesktopOriginal -and $uacSecureDesktopOriginal -ne 0) {
        Set-ItemProperty -Path $uacKey -Name PromptOnSecureDesktop -Value $uacSecureDesktopOriginal -Type DWord
        Write-Log "UAC secure desktop setting restored."
    }
}

# -- Summary --
Write-Log ""
Write-Log "================================================"
Write-Log "SUMMARY"
Write-Log "================================================"
Write-Log "Total apps processed : $($apps.Count)"
Write-Log "Install   - exist: $totalExist  success: $totalSuccess  failure: $totalFailure"
Write-Log "Uninstall - success: $totalUninstallSuccess  failure: $totalUninstallFailure  skipped (exist): $totalSkipped"
Write-Log "Uninstall methods:"
foreach ($name in $uniMethodNames) {
    $n = $uniMethodTotal[$name]
    if ($n -eq 0 -and $name -eq 'unknown') { continue }
    Write-Log ("  {0,-22} : {1}  (success: {2}  failure: {3})" -f $name, $n, $uniMethodSuccess[$name], $uniMethodFailure[$name])
}
Write-Log "=== Invoke-TestPower finished: $(Get-Date) ==="
Write-Host ""
Write-Host "Log saved to: $logPath"
