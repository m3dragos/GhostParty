# GhostParty

A World of Warcraft: Forever addon that shows Battle.net friends as if you were in a party
(party frames, minimap and world map pins) **without actually grouping**, so there is no shared loot or XP split.
Everyone involved runs the addon and broadcasts their own state.

Client: WoW Forever 1.60.1 (interface 16001). Current version: 0.3.0.

## Repository layout
```
GhostParty/        the addon itself (this folder goes into Interface\AddOns)
tools/check.js     quick Lua structure check (block/bracket balance), runs with Node
install.ps1        copies the addon into your Forever install
updater/           friends' auto-updater (GhostPartyUpdater.ps1) and its double-click installer
PLAN.md            original analysis and plan, with status notes
AGENTS.md          notes for AI coding agents / contributors
```

## Install for friends (auto-updates)
Download [`updater/Install-GhostParty.cmd`](updater/Install-GhostParty.cmd) and double-click it (Windows, no admin needed).
It finds your WoW Forever folder (or asks), installs the addon, and adds a hidden scheduled task that checks
this repo at logon and every 30 minutes. New versions land on disk; `/reload` or relog in game to load them.
Log: `%LOCALAPPDATA%\GhostParty\update.log`. To remove the updater:
`powershell -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\GhostParty\GhostPartyUpdater.ps1" -Uninstall`.

## Releasing a new version
Bump `## Version` in `GhostParty/GhostParty.toc` (and `Core.lua`), commit, push to `main`.
Friends' updaters install it only when the repo version is **higher** than theirs, so pushes without a
version bump ship nothing.

## Install by hand (development)
```powershell
.\install.ps1                      # default: G:\Games\World of Warcraft\_forever_
.\install.ps1 -WowPath "D:\World of Warcraft\_forever_"
```
Or copy the `GhostParty` folder to `World of Warcraft\_forever_\Interface\AddOns\` by hand, then `/reload`.

## Using it
1. `/gp friends` lists Battle.net friends online in Forever.
2. `/gp add <number>` for each friend; they add you back.
3. `/gp unlock`, drag the frames, `/gp lock`.
4. `/gp sim` adds a fake friend to test alone.

Minimap button: left-click shows/hides frames, right-click stops/starts sharing.
`/gp stop` / `/gp start` pauses sharing. Full command list: `/gp help` and [GhostParty/README.md](GhostParty/README.md).

## Development
- No build step: edit the Lua, run `node tools/check.js GhostParty/*.lua`, then `.\install.ps1` and `/reload` in game.
- Bump the version in both `GhostParty/GhostParty.toc` and `GhostParty/Core.lua`.
- See [AGENTS.md](AGENTS.md) for architecture, client quirks and conventions.
