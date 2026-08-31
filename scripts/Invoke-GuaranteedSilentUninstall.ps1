param(
  [Parameter(Mandatory=$true)]
  $App
)
function Get-UninstallExeAndBaseArgs {
    param([Parameter(Mandatory)] [string]$UninstallString)
  
    if ($UninstallString -match '^\s*"(.*?)"\s*(.*)$') {
      return @{ Exe = $matches[1]; Base = $matches[2] }
    }
    $parts = $UninstallString.Split(' ',2)
    return @{ Exe = $parts[0]; Base = if ($parts.Count -gt 1) { $parts[1] } else { "" } }
  }
  
  function Test-UninstallGone {
    param(
      [Parameter(Mandatory)] [string]$RegistryPath,
      [string]$InstallLocation
    )
  
    if ($RegistryPath -match '^Microsoft\.PowerShell\.Core\\Registry::(.+)$') {
      $keyPath = $matches[1]
      if (-not (Test-Path ("Registry::$keyPath"))) { return $true }
    }
    if ($InstallLocation -and (Test-Path $InstallLocation)) { return $false }
    return $false
  }
  
  function Invoke-GuaranteedSilentUninstall {
    param(
      [Parameter(Mandatory)] [pscustomobject]$App,
      [int]$InteractiveTimeoutSeconds = 8
    )
  
    if (-not $App.UninstallString) { throw "No UninstallString in registry." }
  
    $parsed = Get-UninstallExeAndBaseArgs -UninstallString $App.UninstallString
    $exe  = $parsed.Exe
    $base = $parsed.Base
  
    if (-not (Test-Path $exe)) { throw "Uninstaller not found: $exe" }
  
    # Candidate silent args (order matters)
    $candidates = @(
      "$base /S",  # NSIS (worked for you)
      "$base /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-", # Inno
      "$base /quiet /norestart", # Burn / some bootstrapper
      "$base /qn /norestart"      # rare EXE wrapper
    ) | Select-Object -Unique
  
    foreach ($args in $candidates) {
      # If already removed, stop
      if (Test-UninstallGone -RegistryPath $App.RegistryPath -InstallLocation $App.InstallLocation) {
        Write-Host "Already uninstalled."
        return $true
      }
  
      Write-Host "Trying (silent): $exe $args"
  
      $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden
  
      # If it doesn't exit quickly, it’s likely waiting on UI (or long-running). We treat as interactive.
      if (-not $p.WaitForExit($InteractiveTimeoutSeconds * 1000)) {
        Write-Host "Looks interactive/blocked (still running after $InteractiveTimeoutSeconds s). Killing and trying next..."
        try { $p.Kill() } catch {}
        continue
      }
  
      Write-Host "ExitCode: $($p.ExitCode)"
      Start-Sleep -Seconds 2
  
      if (Test-UninstallGone -RegistryPath $App.RegistryPath -InstallLocation $App.InstallLocation) {
        Write-Host "Uninstall verified (silent)."
        return $true
      }
  
      Write-Host "Not removed; trying next method..."
    }
  
    Write-Host "No silent method succeeded for this uninstaller."
    return $false
  }
  
Invoke-GuaranteedSilentUninstall -App $App
