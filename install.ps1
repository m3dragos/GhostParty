param(
  [string]$WowPath = 'G:\Games\World of Warcraft\_forever_'
)
# Copies the addon into the Forever AddOns folder (replacing the old copy).
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'GhostParty'
$addons = Join-Path $WowPath 'Interface\AddOns'
if (-not (Test-Path $addons)) { throw "AddOns folder not found: $addons" }
$dst = Join-Path $addons 'GhostParty'
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Copy-Item -Recurse $src $dst
Write-Host "Installed GhostParty to $dst. Type /reload in game."
