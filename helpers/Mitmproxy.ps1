# Mitmproxy.ps1
# Dot-source this file. It only defines functions.
# Start-Mitmdump, Wait-MitmdumpReady, and Stop-Mitmdump run mitmdump.
# Start-MitmCapture and Stop-MitmCapture are the per-app start and stop.
# They use $script:MitmProc, $script:MitmDumpFile, and $script:MitmStopped.
# Callers must define Write-Log and Warn before calling them.
#
# $MitmIgnoreHostsCommon is the short ignore list.
# $MitmIgnoreHostsStore also skips Store CDN and Windows Update hosts.

$mitmCA = "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.pem"
$env:SSL_CERT_FILE = $mitmCA
$env:REQUESTS_CA_BUNDLE = $mitmCA

$MitmIgnoreHostsCommon = @(
    '(^|\.)generativelanguage\.googleapis\.com$',
    '(^|\.)gradio\.live$'
)

$MitmIgnoreHostsStore = @(
    '(^|\.)generativelanguage\.googleapis\.com(:\d+)?$',
    '(^|\.)gradio\.live(:\d+)?$',
    '(^|\.)delivery\.mp\.microsoft\.com(:\d+)?$',
    '(^|\.)update\.microsoft\.com(:\d+)?$',
    '(^|\.)windowsupdate\.com(:\d+)?$',
    '(^|\.)licensing\.mp\.microsoft\.com(:\d+)?$',
    '(^|\.)dsx\.mp\.microsoft\.com(:\d+)?$',
    '(^|\.)collections\.mp\.microsoft\.com(:\d+)?$',
    '(^|\.)md\.mp\.microsoft\.com(:\d+)?$',
    '(^|\.)commerce\.microsoft\.com(:\d+)?$',
    '(^|\.)dsp\.mp\.microsoft\.com(:\d+)?$'
)

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

function Start-MitmCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Stem,
        [Parameter(Mandatory = $true)][string]$NetdumpDir,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [string]$Mode = "local",
        [string[]]$IgnoreHosts = @(),
        [int]$TimeoutSeconds = 20
    )

    $dumpFile = Join-Path $NetdumpDir "$Stem.mitm"
    $mitmLogPath = Join-Path $LogDir "$Stem.mitmdump.log"
    $script:MitmDumpFile = $dumpFile
    if (Test-Path -LiteralPath $mitmLogPath) {
        Remove-Item -LiteralPath $mitmLogPath -Force -ErrorAction SilentlyContinue
    }

    try {
        $script:MitmProc = Start-Mitmdump -OutFile $dumpFile -Mode $Mode -IgnoreHosts $IgnoreHosts -LogFile $mitmLogPath
        if ($script:MitmProc) {
            Write-Log "  mitmdump PID $($script:MitmProc.Id) writing to $dumpFile"
        } else {
            Warn "mitmdump failed to start; no process object returned."
        }
        $mitmReady = Wait-MitmdumpReady -Process $script:MitmProc -LogFile $mitmLogPath -TimeoutSeconds $TimeoutSeconds
        if ($script:MitmProc -and $script:MitmProc.HasExited) {
            $code = $script:MitmProc.ExitCode
            Warn "mitmdump exited immediately with code $code"
            if (Test-Path -LiteralPath $mitmLogPath) {
                $tail = Get-Content -LiteralPath $mitmLogPath -Tail 20 -ErrorAction SilentlyContinue
                foreach ($line in $tail) { Warn "mitmdump: $line" }
            }
        } elseif ($script:MitmProc -and -not $mitmReady) {
            Warn "mitmdump local redirector was not ready after ${TimeoutSeconds}s. Store install may be aborted."
        } elseif ($mitmReady) {
            Write-Log "  mitmdump local redirector is ready."
        }
    } catch {
        Warn "mitmdump failed to start: $($_.Exception.Message)"
        $script:MitmProc = $null
    }

    return [bool]($script:MitmProc -and -not $script:MitmProc.HasExited)
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
