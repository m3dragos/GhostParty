@echo off
rem Installs GhostParty and its auto-updater for the current Windows user. No admin needed.
rem Double-click this file. Run it again any time to reinstall.
echo Installing GhostParty...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; $ProgressPreference = 'SilentlyContinue'; & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/m3dragos/GhostParty/main/updater/GhostPartyUpdater.ps1).Content)) -Install"
echo.
pause
