# Angura (GhostParty) for WoW: Forever

A friend roster, party feed, party chat and live map pins for Battle.net friends **without being in a
group** (no shared loot, no XP split). Everyone needs the addon. In game it's called **Angura**; the
project, folder and saved variables are still `GhostParty`.

## Install
Copy the `GhostParty` folder to `World of Warcraft\_forever_\Interface\AddOns\`.

## Setup (each player)
1. `/angura friends` lists Battle.net friends online in Forever, numbered.
2. `/angura add 2` (or `/angura add Name#1234`) for each friend. Both sides must add each other.
3. `/angura unlock`, drag the gold handle to move the roster (the grip at its right end sets the width), `/angura lock`.

Try it alone first: `/angura sim` adds a fake friend who runs circles around you, changes status,
posts news and says hello on party chat. `/gp` works the same as `/angura`.

## Commands
| Command | |
|---|---|
| `/an <message>` | party chat with everyone you share with who is online; sticky like `/p` (the chat box opens with `/an ` until you send something else) |
| `/angura friends`, `add`, `remove`, `list` | manage who you share with (no limit) |
| `/angura lock` / `unlock` / `reset` / `scale 1.2` | roster position and size (unlocked: drag the handle's grip to change the width) |
| `/angura stop` / `start` | stop / resume sharing; also hides map pins (remembered across reloads) |
| `/angura frames` / `pins` | toggle the roster / map pins |
| `/angura chat` | reopen the Angura chat tab if you closed it |
| `/angura button` | show/hide the minimap button |
| `/angura sim` | fake friend for testing |
| `/angura status` / `debug` | messages sent/received, throttle state |

**Minimap button:** left-click shows/hides the roster, right-click stops/starts sharing, drag to move it.

## What you see
- **Roster**, one row per friend: class icon, level, name, zone and subzone, distance, and status
  icons (combat, dead, ghost, AFK, DND, dungeon/raid/battleground, flight,
  resting, in a group, PvP). "No signal" when updates stop.
  - Click a row to target that friend (when nearby).
  - **+** invites, **-** removes them from your group (when you lead), the **pin** button puts
    Blizzard's map pin and arrow on them (click again to stop).
  - Hover for race, guild, home inn and more.
- **Angura chat tab** (made once, then yours to move, dock or close): friends' news and party chat.
  Party chat also shows in your main chat window, as `[Angura] [Name]: ...` in party colours.
  Your own news shows there too (everyone sees the same history), and the last 150 lines come back
  after a reload or restart, with their times.
  - News: level-ups (every 10th level gets a banner and sound), deaths, entering a dungeon, raid or
    battleground, rare kills, blue-or-better loot (hover the link), duels, coming online / going offline.
- **Map pins**: class-coloured pins on the minimap (clamped to the edge when far) and the world map.
  Friends who are also in your real party/raid get no minimap pin; on the world map only their name is
  drawn, over Blizzard's own marker.

## Appear Offline
If a friend sets Battle.net to Appear Offline, Angura switches to addon whispers to the characters it has
seen them play (up to 5 per friend), with checks backing off from 20 s to 5 minutes, and hides the game's
"No player named ..." messages those checks cause. `/angura list` shows "via whisper" for such friends.

## Known limits
- Health and power are always secret to addons on Forever, so they aren't shown.
- No coordinates inside dungeons/raids: the roster shows "<instance> (inside)" and pins hide.
- Rare kills are seen from the "X dies, you gain N experience" line: no XP (max level, grey mobs) means no news.
- During boss fights chat lines are hidden from addons and sends can be refused: news and party chat
  wait until the fight ends; loot or kill lines that arrive hidden are skipped.
- The send budget is fixed (about 4 messages/second total), so each friend gets fewer position updates
  as the group grows. Party chat uses the same budget.
- Trial / Invite-A-Friend accounts can't send addon messages (they still see others).
- Click-to-target assignments only update out of combat.
- Friends on 0.3.x still show up, without statuses or news.
