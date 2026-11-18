# Start-NetworkStackTrace.ps1
# Record the process, its parent, and the call stack of each TCP connection
# and each UDP send or connect, so a mitmproxy capture can be attributed to
# the application and library that opened it.
#
# logman can enable the TCPIP provider, but logman create trace has no
# stack switch, so it cannot record the caller. This script uses wpr.exe,
# which can. The session is machine-wide and must run elevated.
#
# correlate.py matches mitmproxy's client 4-tuple to a Microsoft-Windows-TCPIP
# connect event, or a UDP destination to a Winsock datagram event, then
# resolves that event's stack against loader events. Process events supply
# the process name, command line, and parent.
# Winsock is limited to datagram sockets and to the events that carry a
# destination address. TCP stream sends stay on the TCPIP connect path.
# UDP port 443 is QUIC and is not one of those events' useful results;
# read_etl.py drops it. A connected QUIC socket's per-packet AfdSend is not
# enabled.
#
# Stop the session with Stop-NetworkStackTrace.ps1 when the test ends.
# In-progress traces go to %TEMP%. That script deletes them after wpr -stop.

#Requires -RunAsAdministrator

param(
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$parentDir = Split-Path -Parent $scriptDir
if (-not $parentDir) { $parentDir = (Get-Location).Path }

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $env:TEMP 'MicrosoftStoreAppMgr\network-stacks'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory
}

$wpr = Join-Path $env:SystemRoot 'System32\wpr.exe'
if (-not (Test-Path -LiteralPath $wpr)) {
    throw "wpr.exe was not found at $wpr."
}

$stateDir = Join-Path $env:LOCALAPPDATA 'MicrosoftStoreAppMgr'
$stateFile = Join-Path $stateDir 'network-stack-trace.json'
$profilePath = Join-Path $stateDir 'NetworkCallerStacks.wprp'

$status = & $wpr -status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "wpr -status failed with exit code ${LASTEXITCODE}: $status"
}
if ($status -notmatch 'WPR is not recording') {
    throw "WPR is already recording. Stop that session before starting a new one.`n$status"
}

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

# Keyword masks are the bits from `logman query providers <name>`.
# Stack="true" is EVENT_ENABLE_PROPERTY_STACK_TRACE.
# Loader maps stack addresses to DLL paths. ProcessThread supplies the
# process name, command line, and parent.
# ImageId is omitted. It records a PDB path per loaded module for WPA
# and was most of a short, idle trace. Module names come from Loader.
$profileXml = @'
<WindowsPerformanceRecorder Version="1.0" Author="MicrosoftStoreAppMgr">
  <Profiles>
    <SystemCollector Id="SystemCollector_NetworkCallerStacks" Name="NT Kernel Logger">
      <BufferSize Value="1024" />
      <Buffers Value="64" />
    </SystemCollector>
    <EventCollector Id="EventCollector_NetworkCallerStacks" Name="NetworkCallerStacks">
      <BufferSize Value="1024" />
      <Buffers Value="128" />
    </EventCollector>
    <SystemProvider Id="SystemProvider_NetworkCallerStacks">
      <Keywords>
        <Keyword Value="ProcessThread" />
        <Keyword Value="Loader" />
      </Keywords>
    </SystemProvider>
    <EventProvider Id="EventProvider_Tcpip" Name="Microsoft-Windows-TCPIP" Level="4" NonPagedMemory="true" Stack="true">
      <!-- ProcessIdHint | ConnectPath. Level 4 stays off the per-packet summary. -->
      <Keywords>
        <Keyword Value="0x0000000400000200" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_Udp" Name="Microsoft-Windows-Winsock-AFD" Level="4" Stack="true">
      <!-- AFD_KW_DATAGRAM. Runtime events also carry the winsock-source bit. -->
      <Keywords>
        <Keyword Value="0x1" />
      </Keywords>
      <!-- SendTo / SendMessage / Connect / ConnectEx that include an address.
           AfdSend (1003) is every datagram on a connected socket, which is the QUIC flood. -->
      <EventFilters FilterIn="true">
        <EventId Value="1007" />
        <EventId Value="1013" />
        <EventId Value="1018" />
        <EventId Value="1021" />
      </EventFilters>
    </EventProvider>
    <Profile Id="NetworkCallerStacks.Verbose.File" Name="NetworkCallerStacks" Description="Process, parent, and call stack of each TCP connection and UDP send" LoggingMode="File" DetailLevel="Verbose">
      <Collectors>
        <SystemCollectorId Value="SystemCollector_NetworkCallerStacks">
          <SystemProviderId Value="SystemProvider_NetworkCallerStacks" />
        </SystemCollectorId>
        <EventCollectorId Value="EventCollector_NetworkCallerStacks">
          <EventProviders>
            <EventProviderId Value="EventProvider_Tcpip" />
            <EventProviderId Value="EventProvider_Udp" />
          </EventProviders>
        </EventCollectorId>
      </Collectors>
      <TraceMergeProperties>
        <TraceMergeProperty Id="NetworkCallerStacksMerge" Name="NetworkCallerStacksMerge">
          <DeletePreMergedTraceFiles Value="true" />
        </TraceMergeProperty>
      </TraceMergeProperties>
    </Profile>
  </Profiles>
</WindowsPerformanceRecorder>
'@

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($profilePath, $profileXml.Trim(), $utf8)

Write-Host "Starting network caller stack trace."
Write-Host "  Profile: $profilePath"
Write-Host "  Temp:    $OutputDirectory"

& $wpr -start "$profilePath!NetworkCallerStacks.Verbose" -filemode -recordtempto $OutputDirectory
if ($LASTEXITCODE -ne 0) {
    throw "wpr -start failed with exit code $LASTEXITCODE."
}

$state = [ordered]@{
    StartedUtc       = [DateTime]::UtcNow.ToString('o')
    OutputDirectory  = $OutputDirectory
    ProfilePath      = $profilePath
}
$state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8

Write-Host ""
Write-Host "Recording. Run Stop-NetworkStackTrace.ps1 when the test ends."
Write-Host "The stack above ws2_32 / wininet / winhttp / webio / dnsapi is the caller."
Write-Host "The app's own binaries are first-party. Another vendor's DLL, WebView, or helper process is third-party."
