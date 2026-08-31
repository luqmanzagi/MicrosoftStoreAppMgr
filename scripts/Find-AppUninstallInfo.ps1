param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$StoreName
)

$uninstallPaths = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Normalize-Name([string]$s) {
  if (-not $s) { return "" }
  ($s.ToLower() -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' '
}

$apps = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName } |
  Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation,
                UninstallString, QuietUninstallString, WindowsInstaller, PSChildName, PSPath,
                BundleProviderKey, URLInfoAbout

$apps | ForEach-Object {
  $_ | Add-Member -NotePropertyName NormName -NotePropertyValue (Normalize-Name $_.DisplayName) -Force
}

function Find-AppUninstallInfo {
  param([Parameter(Mandatory)][string] $StoreName)

  $n = Normalize-Name $StoreName

  $match = $apps | Where-Object { $_.NormName -eq $n }

  if (-not $match) {
    $match = $apps | Where-Object { $_.NormName -like "*$n*" -or $n -like "*$($_.NormName)*" }
  }

  $match = $match | Sort-Object {
    [int]([string]::IsNullOrEmpty($_.QuietUninstallString))
  }, DisplayName

  $match | ForEach-Object {
    $quiet = $_.QuietUninstallString

    if (-not $quiet -and $_.WindowsInstaller -eq 1 -and $_.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
      $quiet = "msiexec.exe /x $($_.PSChildName) /qn /norestart"
    }

    [pscustomobject]@{
      StoreName            = $StoreName
      DisplayName          = $_.DisplayName
      Publisher            = $_.Publisher
      DisplayVersion       = $_.DisplayVersion
      QuietUninstallString = $quiet
      UninstallString      = $_.UninstallString
      RegistryPath         = $_.PSPath
      WindowsInstaller     = $_.WindowsInstaller
      ProductCode          = if ($_.WindowsInstaller -eq 1) { $_.PSChildName } else { $null }
    }
  }
}

# ---- This is the important part: actually call it ----
Find-AppUninstallInfo -StoreName $StoreName
