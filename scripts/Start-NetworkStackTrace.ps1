# Start-NetworkStackTrace.ps1
# Record call stacks for network API calls so a mitmproxy capture can be
# attributed to the module that sent the request.
#
# logman can enable these ETW providers, but logman create trace has no
# stack switch, so it cannot record the caller. This script uses wpr.exe,
# which can. The session is machine-wide and must run elevated.
#
# Stop the session with Stop-NetworkStackTrace.ps1 when the test ends.
# Winsock events are logged for every process, so the ETL grows quickly.

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
    $OutputDirectory = Join-Path $parentDir 'results\logs\network-stacks'
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
# Loader + ProcessThread are what turn stack addresses into process and DLL names.
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
    <EventProvider Id="EventProvider_WinsockAfd" Name="Microsoft-Windows-Winsock-AFD" Level="5" Stack="true">
      <!-- datagram | stream | Winsock-initiated. Excludes transport completions. -->
      <Keywords>
        <Keyword Value="0x7" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_WinHttp" Name="Microsoft-Windows-WinHttp" Level="5" Stack="true">
      <!-- API | SEND | L3_CONNECT | ADDRESS -->
      <Keywords>
        <Keyword Value="0x0000080500000001" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_WinINet" Name="Microsoft-Windows-WinINet" Level="5" Stack="true">
      <!-- HTTP | CONNECTION | HTTPS -->
      <Keywords>
        <Keyword Value="0x16" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_WebIO" Name="Microsoft-Windows-WebIO" Level="5" Stack="true">
      <!-- API | SEND | L3_CONNECT | ADDRESS -->
      <Keywords>
        <Keyword Value="0x0000080500000001" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_DnsClient" Name="Microsoft-Windows-DNS-Client" Level="4" Stack="true">
      <!-- GenericEvent | SendPath | Address -->
      <Keywords>
        <Keyword Value="0x0000080100000100" />
      </Keywords>
    </EventProvider>
    <EventProvider Id="EventProvider_Tcpip" Name="Microsoft-Windows-TCPIP" Level="4" NonPagedMemory="true" Stack="true">
      <!-- ProcessIdHint | ConnectPath. Level 4 stays off the per-packet summary. -->
      <Keywords>
        <Keyword Value="0x0000000400000200" />
      </Keywords>
    </EventProvider>
    <Profile Id="NetworkCallerStacks.Verbose.File" Name="NetworkCallerStacks" Description="Call stacks of the code that issued network calls" LoggingMode="File" DetailLevel="Verbose">
      <Collectors>
        <SystemCollectorId Value="SystemCollector_NetworkCallerStacks">
          <SystemProviderId Value="SystemProvider_NetworkCallerStacks" />
        </SystemCollectorId>
        <EventCollectorId Value="EventCollector_NetworkCallerStacks">
          <EventProviders>
            <EventProviderId Value="EventProvider_WinsockAfd" />
            <EventProviderId Value="EventProvider_WinHttp" />
            <EventProviderId Value="EventProvider_WinINet" />
            <EventProviderId Value="EventProvider_WebIO" />
            <EventProviderId Value="EventProvider_DnsClient" />
            <EventProviderId Value="EventProvider_Tcpip" />
          </EventProviders>
        </EventCollectorId>
      </Collectors>
      <TraceMergeProperties>
        <TraceMergeProperty Id="NetworkCallerStacksMerge" Name="NetworkCallerStacksMerge">
          <DeletePreMergedTraceFiles Value="true" />
          <CustomEvents>
            <CustomEvent Value="ImageId" />
            <CustomEvent Value="BuildInfo" />
            <CustomEvent Value="EventMetadata" />
          </CustomEvents>
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
