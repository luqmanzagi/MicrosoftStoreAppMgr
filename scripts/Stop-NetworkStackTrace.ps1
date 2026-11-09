# Stop-NetworkStackTrace.ps1
# Stop the session started by Start-NetworkStackTrace.ps1 and write one .etl file.
#
# Open the ETL in Windows Performance Analyzer. On Winsock-AFD, WinHttp,
# WinINet, WebIO, DNS-Client, and TCPIP events, the frames above the Windows
# network DLLs (ntdll, kernelbase, ws2_32, mswsock, wininet, winhttp, webio,
# dnsapi) are the caller. The app's own binaries are first-party. Another
# vendor's DLL, WebView, or a helper process is third-party. mitmdump.exe
# stacks are the proxy's own outbound connections.
#
# -skipPdbGen keeps this from spending minutes generating NGEN PDBs.
# Module names still resolve. Function names need symbols later in WPA.
# The -recordtempto directory is scratch. It is removed after wpr -stop.

#Requires -RunAsAdministrator

param(
    [string]$OutputFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

$wpr = Join-Path $env:SystemRoot 'System32\wpr.exe'
if (-not (Test-Path -LiteralPath $wpr)) {
    throw "wpr.exe was not found at $wpr."
}

$stateFile = Join-Path $env:LOCALAPPDATA 'MicrosoftStoreAppMgr\network-stack-trace.json'
$state = $null
if (Test-Path -LiteralPath $stateFile) {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
}

$status = & $wpr -status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "wpr -status failed with exit code ${LASTEXITCODE}: $status"
}
if ($status -match 'WPR is not recording') {
    if (Test-Path -LiteralPath $stateFile) {
        Remove-Item -LiteralPath $stateFile -Force
    }
    throw "WPR is not recording. Nothing to stop."
}
if (-not $state -and -not $Force) {
    throw "WPR is recording, but Start-NetworkStackTrace.ps1 did not start it. Re-run with -Force to stop that session anyway.`n$status"
}

$tempDir = $null
if ($state -and $state.OutputDirectory) {
    $tempDir = [string]$state.OutputDirectory
}

if (-not $OutputFile) {
    $dir = Join-Path $parentDir 'results\logs\etl'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $OutputFile = Join-Path $dir "network-stacks_$stamp.etl"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = Join-Path (Get-Location).Path $OutputFile
}

if ([System.IO.Path]::GetExtension($OutputFile) -ne '.etl') {
    $OutputFile = "$OutputFile.etl"
}
if ((Test-Path -LiteralPath $OutputFile) -and -not $Force) {
    throw "Output file already exists: $OutputFile. Pass -Force to overwrite it."
}

$outputDir = Split-Path -Parent $OutputFile
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Write-Host "Stopping network caller stack trace."
Write-Host "  Output: $OutputFile"

& $wpr -stop $OutputFile 'Network caller stacks' -skipPdbGen
if ($LASTEXITCODE -ne 0) {
    throw "wpr -stop failed with exit code $LASTEXITCODE. The session may still be recording."
}
if (-not (Test-Path -LiteralPath $OutputFile)) {
    throw "wpr -stop returned success but did not create $OutputFile."
}

if (Test-Path -LiteralPath $stateFile) {
    Remove-Item -LiteralPath $stateFile -Force
}

if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
    $tempFull = [System.IO.Path]::GetFullPath($tempDir).TrimEnd('\')
    $outputFull = [System.IO.Path]::GetFullPath($OutputFile).TrimEnd('\')
    $outputInside = $outputFull.Equals($tempFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $outputFull.StartsWith($tempFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
    try {
        if (-not $outputInside -and $tempFull.Length -gt 3) {
            Remove-Item -LiteralPath $tempFull -Recurse -Force -ErrorAction Stop
            Write-Host "Removed temporary trace files: $tempFull"
        } elseif ($outputInside -and -not $outputFull.Equals($tempFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Get-ChildItem -LiteralPath $tempFull -Force -ErrorAction Stop | ForEach-Object {
                $child = $_.FullName.TrimEnd('\')
                if (-not $child.Equals($outputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item -LiteralPath $child -Recurse -Force -ErrorAction Stop
                }
            }
            Write-Host "Removed temporary trace files from $tempFull"
        }
    } catch {
        Write-Warning "Could not remove temporary trace files at ${tempFull}: $($_.Exception.Message)"
    }
}

$item = Get-Item -LiteralPath $OutputFile
Write-Host ""
Write-Host "Wrote $($item.FullName) ($([Math]::Round($item.Length / 1MB, 1)) MB)."
