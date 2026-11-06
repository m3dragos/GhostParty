<#
  GhostParty updater.
  Keeps Interface\AddOns\GhostParty in sync with the GitHub repo. A new version is installed only when
  the Version line in GhostParty/GhostParty.toc on the repo is higher than the installed one, so pushing
  work in progress without bumping the version ships nothing.

  Friends install it once (copies itself to %LOCALAPPDATA%\GhostParty and adds a scheduled task that
  checks every 30 minutes):
    Install-GhostParty.cmd   (double-click)
  or
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((iwr -UseBasicParsing https://raw.githubusercontent.com/m3dragos/GhostParty/main/updater/GhostPartyUpdater.ps1).Content)) -Install"

  Other uses:
    GhostPartyUpdater.ps1             check now, update if newer
    GhostPartyUpdater.ps1 -Force      reinstall the repo version even if it is not newer
    GhostPartyUpdater.ps1 -Uninstall  remove the scheduled task and %LOCALAPPDATA%\GhostParty (keeps the addon)

  Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
#>
[CmdletBinding()]
param(
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Force,
  [switch]$Quiet,
  [string]$AddOnsPath,
  [string]$Repo = 'm3dragos/GhostParty',
  [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the PS 5.1 progress bar makes downloads very slow
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$AddonName  = 'GhostParty'
$TaskName   = 'GhostParty Updater'
$AppDir     = Join-Path $env:LOCALAPPDATA 'GhostParty'
$ConfigFile = Join-Path $AppDir 'config.json'
$LogFile    = Join-Path $AppDir 'update.log'
$SelfFile   = Join-Path $AppDir 'GhostPartyUpdater.ps1'

function Write-Log([string]$Message) {
  if (-not $Quiet) { Write-Host $Message }
  try {
    if (-not (Test-Path $AppDir)) { return }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { Move-Item -Force $LogFile "$LogFile.old" }
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
  } catch {}
}

# ---------------------------------------------------------------- config

function Read-Config {
  if (Test-Path $ConfigFile) {
    try { return Get-Content -Raw $ConfigFile | ConvertFrom-Json } catch {}
  }
  return $null
}

function Save-Config([string]$AddOns) {
  if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Force $AppDir | Out-Null }
  [pscustomobject]@{ AddOnsPath = $AddOns; Repo = $Repo; Branch = $Branch } |
    ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding ASCII
}

# ---------------------------------------------------------------- finding the game

# Accepts the WoW root, _forever_, Interface or AddOns folder and returns the AddOns folder (or $null).
function Resolve-AddOns([string]$Path) {
  if (-not $Path) { return $null }
  $p = $Path.Trim().Trim('"').TrimEnd('\')
  if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
  $leaf = Split-Path $p -Leaf
  if ($leaf -ieq 'AddOns') { return $p }
  if ($leaf -ieq 'Interface') { return (Join-Path $p 'AddOns') }
  if ($leaf -ieq '_forever_') { return (Join-Path $p 'Interface\AddOns') }
  if ($leaf -like '_*_') { $p = Split-Path $p }  # someone picked _retail_ etc.
  if (Test-Path -LiteralPath (Join-Path $p '_forever_')) { return (Join-Path $p '_forever_\Interface\AddOns') }
  return $null
}

function Find-AddOns {
  $roots = New-Object System.Collections.Generic.List[string]
  $keys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    Get-ItemProperty $k -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -like 'World of Warcraft*' -and $_.InstallLocation } |
      ForEach-Object { $roots.Add([string]$_.InstallLocation) }
  }
  $common = 'World of Warcraft', 'Games\World of Warcraft', 'Program Files (x86)\World of Warcraft',
            'Program Files\World of Warcraft', 'Blizzard\World of Warcraft', 'Games\Blizzard\World of Warcraft',
            'Battle.net\World of Warcraft', 'Games\Battle.net\World of Warcraft'
  foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    foreach ($rel in $common) { $roots.Add((Join-Path $d.Root $rel)) }
  }
  foreach ($r in ($roots | Select-Object -Unique)) {
    $a = Resolve-AddOns $r
    if ($a) { return $a }
  }
  return $null
}

function Select-AddOnsFolder {
  Add-Type -AssemblyName System.Windows.Forms
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'Pick your World of Warcraft folder (the one that contains _forever_)'
  $dlg.ShowNewFolderButton = $false
  while ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $a = Resolve-AddOns $dlg.SelectedPath
    if ($a) { return $a }
    [void][System.Windows.Forms.MessageBox]::Show("No _forever_ folder found in:`n$($dlg.SelectedPath)", 'GhostParty')
  }
  return $null
}

# ---------------------------------------------------------------- versions

function Get-TocVersion([string]$Text) {
  $m = [regex]::Match($Text, '(?m)^##\s*Version:\s*(\S+)')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Test-Newer([string]$Remote, [string]$Local) {
  if (-not $Local) { return $true }
  $r = $null; $l = $null
  if ([version]::TryParse($Remote, [ref]$r) -and [version]::TryParse($Local, [ref]$l)) { return $r -gt $l }
  return $Remote -ne $Local
}

function Get-RemoteVersion {
  $url = "https://raw.githubusercontent.com/$Repo/$Branch/$AddonName/$AddonName.toc"
  $text = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30).Content
  if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
  $v = Get-TocVersion $text
  if (-not $v) { throw "No version line in $url" }
  return $v
}

function Get-LocalVersion([string]$AddOns) {
  $toc = Join-Path $AddOns "$AddonName\$AddonName.toc"
  if (Test-Path -LiteralPath $toc) { return Get-TocVersion (Get-Content -Raw -LiteralPath $toc) }
  return $null
}

# ---------------------------------------------------------------- update

function Update-Addon([string]$AddOns, [bool]$Always) {
  $local = Get-LocalVersion $AddOns
  $remote = Get-RemoteVersion
  if (-not $Always -and -not (Test-Newer $remote $local)) {
    Write-Log "Up to date (installed $local, repo $remote)."
    return
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('GhostParty-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'repo.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -OutFile $zip `
      -Uri "https://codeload.github.com/$Repo/zip/refs/heads/$Branch"
    $out = Join-Path $tmp 'x'
    Expand-Archive -LiteralPath $zip -DestinationPath $out
    $top = Get-ChildItem -LiteralPath $out -Directory | Select-Object -First 1
    if (-not $top) { throw 'Downloaded archive is empty.' }
    $src = Join-Path $top.FullName $AddonName
    if (-not (Test-Path -LiteralPath (Join-Path $src "$AddonName.toc"))) { throw "Downloaded archive has no $AddonName folder." }
    $got = Get-TocVersion (Get-Content -Raw -LiteralPath (Join-Path $src "$AddonName.toc"))

    if (-not (Test-Path -LiteralPath $AddOns)) { New-Item -ItemType Directory -Force $AddOns | Out-Null }
    $dst = Join-Path $AddOns $AddonName
    $new = "$dst.new"
    $old = "$dst.old"
    foreach ($p in $new, $old) { if (Test-Path -LiteralPath $p) { Remove-Item -Recurse -Force -LiteralPath $p } }
    Copy-Item -Recurse -LiteralPath $src -Destination $new
    if (Test-Path -LiteralPath $dst) { Rename-Item -LiteralPath $dst -NewName (Split-Path $old -Leaf) }
    try {
      Rename-Item -LiteralPath $new -NewName $AddonName
    } catch {
      if (Test-Path -LiteralPath $old) { Rename-Item -LiteralPath $old -NewName $AddonName }
      throw
    }
    if (Test-Path -LiteralPath $old) { Remove-Item -Recurse -Force -LiteralPath $old -ErrorAction SilentlyContinue }

    # Keep the installed updater current too.
    $upd = Join-Path $top.FullName 'updater\GhostPartyUpdater.ps1'
    if ((Test-Path -LiteralPath $upd) -and (Test-Path -LiteralPath $AppDir)) { Copy-Item -Force -LiteralPath $upd -Destination $SelfFile }

    if ($local) { Write-Log "Updated GhostParty $local -> $got. Type /reload in game if it is running." }
    else { Write-Log "Installed GhostParty $got into $dst. Type /reload in game if it is running." }
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- scheduled task

function Register-UpdaterTask {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfFile`" -Quiet"
  $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
  # conhost --headless runs PowerShell without flashing a console window.
  if (Test-Path $conhost) { $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" $psArgs" }
  else { $action = New-ScheduledTaskAction -Execute $ps -Argument $psArgs }

  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $user),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30))
  )
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description "Keeps the GhostParty WoW addon up to date from github.com/$Repo" -Force | Out-Null
}

# ---------------------------------------------------------------- main

try {
  if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $AppDir) { Remove-Item -Recurse -Force $AppDir }
    Write-Host 'GhostParty updater removed. The addon itself is still installed.'
    return
  }

  $cfg = Read-Config
  if ($cfg) {
    if (-not $PSBoundParameters.ContainsKey('Repo') -and $cfg.Repo) { $Repo = $cfg.Repo }
    if (-not $PSBoundParameters.ContainsKey('Branch') -and $cfg.Branch) { $Branch = $cfg.Branch }
  }

  $addons = $null
  if ($AddOnsPath) {
    $addons = Resolve-AddOns $AddOnsPath
    if (-not $addons) { throw "Not a WoW Forever folder: $AddOnsPath" }
  } elseif ($cfg -and $cfg.AddOnsPath) {
    $addons = $cfg.AddOnsPath
  } else {
    $addons = Find-AddOns
    if (-not $addons -and $Install) { $addons = Select-AddOnsFolder }
    if (-not $addons) { throw 'Could not find WoW Forever. Run again with -AddOnsPath "<WoW folder>".' }
  }

  if ($Install) {
    Save-Config $addons
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $SelfFile)) {
      Copy-Item -Force -LiteralPath $PSCommandPath -Destination $SelfFile
    } elseif (-not $PSCommandPath) {
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -OutFile $SelfFile `
        -Uri "https://raw.githubusercontent.com/$Repo/$Branch/updater/GhostPartyUpdater.ps1"
    }
    Write-Log "WoW Forever AddOns folder: $addons"
    Update-Addon $addons $Force.IsPresent
    Register-UpdaterTask
    Write-Log 'Updater installed: checks for a new GhostParty version at logon and every 30 minutes.'
    return
  }

  if ($PSBoundParameters.ContainsKey('AddOnsPath') -and (Test-Path $AppDir)) { Save-Config $addons }
  Update-Addon $addons $Force.IsPresent
} catch {
  Write-Log "Error: $($_.Exception.Message)"
  if (-not $Quiet) { exit 1 }
}
