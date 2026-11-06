# GhostParty (WoW: Forever)

Party frames and live map pins for Battle.net friends **without being in a group**
(no shared loot, no XP split). Everyone in the group needs the addon.

## Install
Copy the `GhostParty` folder to `World of Warcraft\_forever_\Interface\AddOns\`.

## Setup (each player)
1. `/gp friends` lists Battle.net friends online in Forever, numbered.
2. `/gp add 2` (or `/gp add Name#1234`) for each friend. Both sides must add each other.
3. `/gp unlock`, drag the blue handle, `/gp lock`.

Try it alone first: `/gp sim` adds a fake friend running circles around you.

## Commands
| Command | |
|---|---|
| `/gp friends`, `/gp add`, `/gp remove`, `/gp list` | manage who you share with (max 4) |
| `/gp lock` / `unlock` / `reset` / `scale 1.2` | frame position and size |
| `/gp stop` / `start` | stop / resume sharing your position; also hides map pins (remembered across reloads) |
| `/gp frames` / `pins` | toggle frames / map pins |
| `/gp button` | show/hide the minimap button |

**Minimap button:** left-click shows/hides the party frames, right-click stops/starts sharing,
drag to move it. The icon turns grey-red while sharing is stopped.
| `/gp sim` | fake friend for testing |
| `/gp status` / `debug` | messages sent/received, throttle state |

## What you see
- Party-style frame per friend: class portrait, level, health, power, name, combat glow,
  Dead/Ghost/AFK, "No signal" when updates stop, zone and distance underneath.
- Left-click a frame to target that friend (works when they are nearby).
- Class-coloured pins on the minimap (clamped to the edge when far) and the world map.
  Friends who are also in your real party/raid get no GhostParty pin: Blizzard's own marker shows them.

## Appear Offline
If a friend sets Battle.net to Appear Offline, GhostParty switches to addon whispers to the
characters it has seen them play (it remembers up to 5 per friend). It checks every 20 s and hides the
game's "No player named ..." messages those checks cause. `/gp list` shows "via whisper" for such friends.
A friend who has never been seen online by your addon can't be found this way.

## Known limits
- Health/power can be secret in combat on Forever: frames then show the last value from before combat.
- No coordinates inside dungeons/raids: the frame shows "<instance> (inside)" and pins hide.
- Trial / Invite-A-Friend accounts can't send addon messages (they still see others).
- Click-to-target assignments only update out of combat.

## How it works
`State.lua` samples your character 10x/s and sends a ~40-byte update over Battle.net
(`C_BattleNet.SendGameData`) when you move 2.5 yd, start/stop, turn, or your stats change,
plus a 4 s heartbeat. `Comm.lua` spreads messages over 4 prefixes with token buckets and keeps only the
newest update per friend, so a tight budget means fewer updates, never stale ones. `Members.lua`
extrapolates and eases positions so pins glide between updates. Wire format: `Protocol.lua`.
