# Invoke-CheckCapture.ps1
# Compare one mitmproxy flow dump with one network-stack ETL.
# Both paths are arguments, so each run can point at a different pair.
#
#   .\check\Invoke-CheckCapture.ps1 -FlowFile .\capture.mitm -EtlFile .\network.etl
#   .\check\Invoke-CheckCapture.ps1 -FlowFile .\capture.mitm -EtlFile .\network.etl -ReportFile .\report.txt

param(
    [Parameter(Mandatory = $true)]
    [string]$FlowFile,

    [Parameter(Mandatory = $true)]
    [string]$EtlFile,

    [string]$ReportFile
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }
$script = Join-Path $here 'correlate.py'

if (-not (Test-Path -LiteralPath $FlowFile)) {
    throw "Flow file not found: $FlowFile"
}
if (-not (Test-Path -LiteralPath $EtlFile)) {
    throw "ETL file not found: $EtlFile"
}
if (-not (Test-Path -LiteralPath $script)) {
    throw "Checker not found: $script"
}

$flowPath = (Resolve-Path -LiteralPath $FlowFile).Path
$etlPath = (Resolve-Path -LiteralPath $EtlFile).Path

$pyArgs = @('-u', $script, '--flow', $flowPath, '--etl', $etlPath)
if ($ReportFile) {
    $reportParent = Split-Path -Parent $ReportFile
    if ($reportParent -and -not (Test-Path -LiteralPath $reportParent)) {
        New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
    }
    $pyArgs += @('--report', $ReportFile)
}

& python @pyArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
