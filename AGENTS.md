# AGENTS.md

Notes for AI agents and contributors working on GhostParty.

## What this is
A WoW: Forever addon. Friends who are **not grouped** see each other: a friend roster with statuses,
a party feed and party chat in a native chat tab, plus minimap/world map pins. Each client broadcasts
its own state; nothing is read from other players' units (impossible when ungrouped). Owner plays with
Battle.net friends only.

**Display name: "Angura"** (`ns.NAME`): use it in every player-visible string. The project, folder,
saved variables (`GhostPartyDB`), frame names and message prefixes stay `GhostParty` / `GhostPty`.
Slash: `/angura` (same as `/gp`, `/ghostparty`); party chat `/an`.

## Client facts (verified 2026-11 against the live install and other Forever addons)
- Forever = `wowf` product, client **1.60.1.70790**, TOC `## Interface: 16001`.
- It runs on the **Retail (12.x) client**: Retail APIs (`C_Map`, `C_BattleNet`, `C_ChatInfo`, atlases),
  Classic globals are gone. Midnight-era restrictions apply.
- **Secret values**: the player's own health/power (`UnitHealth`, `UnitPower`, their `*Max` and `*Percent`)
  are secret **always**, in and out of combat (owner checked with `/gp status`, 0.3.2). We don't send them
  (S fields are `-`). Other unit stats can be secret too. Never compare or send a secret: wrap reads with
  `ns.Plain` / `ns.Call` (returns nil for secrets). `issecretvalue` may not exist: guard it.
- **Readable** (in-game probe 2026-11-07, open world): mounted, flying, swimming, taxi, resting, AFK, DND,
  PvP, group size, `GetInstanceInfo`, subzone, race, guild, home (`GetBindLocation`), `PLAYER_DEAD`,
  `PLAYER_LEVEL_UP`, the XP kill line and your own loot lines (item ID and quality). Details and sources:
  `docs/roster-redesign.md`.
- The **combat log is off limits** (registering `COMBAT_LOG_EVENT_UNFILTERED` shows players a "blocked"
  popup). Kills come from `CHAT_MSG_COMBAT_XP_GAIN` ("X dies, you gain N experience", may go on with a
  group/rested bonus); a rare's classification is cached by name on target/mouseover, because the target is
  often gone when the line arrives and `UnitClassification` of no unit says "normal".
- Chat-line text (`CHAT_MSG_*`) is secret during **boss encounters** (Midnight narrowed it from whole
  instances): skip secret lines. Addon sends may be refused then: `E`/`C` messages are held between
  `ENCOUNTER_START` and `ENCOUNTER_END`, and urgent sends refused for lockdown are retried (up to 5 min).
- Global strings: `DUEL_WINNER_RETREAT` is `%2$s has fled from %1$s` (positional, reversed): match
  captures by position (`Feed.lua` `Pattern`). Loot links use the new `|cnIQ<quality>:` colour tag.
- `SOUNDKIT` has no plain level-up sound: milestones use `UI_GARRISON_COMMAND_TABLE_FOLLOWER_LEVEL_UP`.
- Atlases present: `Dungeon`, `Raid`, `socialqueuing-icon-group`, `poi-graveyard-neutral`, `XMarksTheSpot`,
  `Waypoint-MapPin-Untracked`, `groupfinder-icon-friend`, `UI-HUD-UnitFrame-Party-PortraitOn`.
- Character names can contain spaces ("Dumil Angura"); realms look like `CAMWOWEU5Realm6PvP`.
  Friends play on different realms, so a custom chat channel can't reach them: party chat goes over addon messages.
- `C_PartyInfo.InviteUnit` / `UninviteUnit` and the user waypoint + `C_SuperTrack` work from insecure code
  (EllesmereUI and ForeverPlusPlus do it), so those buttons work in combat.
- Battle.net reports Forever with its **own `wowProjectID`**, while the client's `WOW_PROJECT_ID` is 1.
  Compare friends against our own entry (`C_BattleNet.GetGameAccountInfoByGUID(UnitGUID("player"))`).
- `BN_CHAT_MSG_ADDON` args: `prefix, text, channel, gameAccountID`. Send with
  `C_BattleNet.SendGameData(gameAccountID, prefix, text)` (fallback `BNSendGameData`).
- `CHAT_MSG_ADDON` 5th arg is the target, not a flag: only use the first four.
- No map coordinates inside instances (`C_Map.GetPlayerMapPosition` returns nil).
- Trial / Invite-A-Friend accounts cannot send addon messages.
- Throttle: ~10-message burst per prefix, ~1/s refill. We assume the same for Battle.net game data.
- `C_ChatInfo.InChatMessagingLockdown()` exists on Forever and also turns on in the open world.
  **Don't pause sending on it**: 0.3.1 did and friends flickered to "No signal", while 0.3.0 clients
  (never paused) got through. Always try the send; the per-send result decides. Show it in `/gp status` only.
  `SendAddonMessage` returns `Enum.SendAddonMessageResult`: anything but `Success` is a failure, throttle codes mean retry.
  The owner still has an open "No signal" question from 0.3.1+: `signalLog` (Members.lua) records gaps for it.
- "Appear Offline" hides a friend's game account from Battle.net: fall back to addon `WHISPER` to known characters.
- Local install (owner's machine): `G:\Games\World of Warcraft\_forever_\Interface\AddOns\`.
  Other installed addons there (Kinship, EllesmereUI, LoreForever, ForeverPlusPlus) are useful **read-only**
  API references. Never edit them. Saved variables: `WTF\Account\134696910#1\SavedVariables\GhostParty.lua`.

## Architecture (`GhostParty/`, load order = TOC order)
| File | Role |
|---|---|
| `Core.lua` | namespace, `ns.NAME`, event bus `ns:On`, saved vars `GhostPartyDB` (defaults table), helpers, slash commands (`/angura`, `/gp`, `/an`), `ns.SetSharing`, `ns.SetFramesShown` |
| `Protocol.lua` | pure-Lua wire format (no WoW API): `EncodeState/Hello/Bye/Info/Event/Chat`, `SplitChat`, `Decode`, `FLAG_*` and `ST_*` bits |
| `Roster.lua` | Battle.net scan, members by BattleTag, remembered characters, **routing** (`Route(tag)` → BN or WHISPER) |
| `Comm.lua` | token buckets over 4 prefixes; priority urgent FIFO (hellos, byes, events, chat; `hold` during encounters; lockdown retry) > latest-info-per-friend > latest-state-per-friend > whisper probes (spare tokens only); BN + whisper send/receive; probe backoff; "No player named" chat filter |
| `State.lua` | samples own character every 0.1 s, sends S on change (2.5 yd, start/stop, turn, flags) + 4 s heartbeat; I (statuses, subzone, race, guild, home) on change, at most every 3 s, and with every hello; hellos; `SendEvent` |
| `Members.lua` | per-friend records, staleness, presence (online/offline), velocity estimate, smoothed predicted position, "No signal" gap log |
| `Feed.lua` | own-moment detectors (level, death, instance entry, rare kill, blue+ loot, duel) → E; friends' E/C → lines in the native "Angura" chat tab (`FCF_OpenNewWindow` once; main chat if closed); milestone banner + sound; `/an` party chat; chat sanitizing (item links rebuilt, all other escapes shown literally) |
| `Frames.lua` | the roster: tooltip-style rows made on demand (no cap), one column growing downward; visual layer (insecure) + click layer (secure: left-click `/target`) + insecure Invite / Uninvite / Find buttons above it; Find = user waypoint, refreshed every 3 s while tracked |
| `Pins.lua` | `ns.Geo` map math (distance), minimap pins, world map pins |
| `Sim.lua` | `/angura sim` fake friend through the real encode/decode path (state, info, news, chat) |
| `Button.lua` | minimap button (left: roster, right: sharing) |

Protocol v1:
- `1:S:map:x:y:facing:speed:hp:hpMax:pw:pwMax:pwType:flags` (hp..pwType always `-` since 0.4.0)
- `1:H:want:level:class:name:zone`, `1:B[:reason]` (2 = stopped sharing)
- since 0.4.0: `1:I:status:group:instType:subzone:race:guild:home`, `1:E:kind:args...`, `1:C:text`
  (0.3.x drops I/E/C as malformed and reads `1:B:2` as a plain bye).

`-` = unknown. Changing S/H field counts breaks older clients: bump `P.VERSION` and tell the owner everyone
must update. New statuses go in I (`ST_*`), **never** in S flags: 0.3.x rejects S flags > 255 and drops the
whole message.

## Rules that are easy to break
- **Combat lockdown**: secure click buttons can't be shown, hidden, moved or re-attributed in combat.
  Visual frames must not be anchor targets of secure frames (click buttons are anchored to the anchor frame).
  Defer with `pendingSecure` and apply on `PLAYER_REGEN_ENABLED`. A slot's secure button is created
  lazily out of combat (`EnsureSlot`); a friend appearing mid-combat gets a row but no click until combat ends.
  The row's Invite/Uninvite/Find buttons are insecure and sit above the click layer (higher frame level).
- More members = same total send budget split thinner (4 prefixes × ~1 msg/s). Don't "fix" by raising rates.
  Party chat and news share it.
- Every WoW API call that can fail or return secrets goes through `ns.Call` or `pcall`.
- `a and f()` keeps only f's first result: never use it for multi-value calls.
- Lua 5.1: no `goto`, no `//`, no `+=`, use `math.floor`, not bit ops (Protocol must stay WoW-free).
- Keep traffic low: the owner explicitly does **not** want higher polling/send rates; improve display
  (prediction/easing) instead.
- Feed = rare moments only. The owner rejected quest completions, zone changes outside instances, boss kills
  and flights as too spammy, and doesn't want progress bars. Presence: a bye waits 25 s (a /reload sends one
  and says hello again); "came online" needs a hello with `want` (they just logged in) or an earlier
  "went offline". Re-entering the same instance within 30 min of leaving isn't news.
- Text from friends is untrusted: `Feed.lua` `Sanitize` keeps only item links (rebuilt by us) and shows
  every other `|` escape literally.
- Whisper probes back off per member (20 s doubling to 5 min, reset when heard from or when they leave
  Battle.net) and skip friends visible on Battle.net outside WoW. Never go back to fixed-rate probing
  of offline characters: it is the one traffic pattern that looks like spam.
- Friends in your real group (`Geo.InMyGroup` returns their unit token, refreshed on `GROUP_ROSTER_UPDATE`):
  no minimap pin; world map shows a name-only label (no dot, mouse disabled) positioned with
  `C_Map.GetPlayerMapPosition(mapID, unit)` so it sits on Blizzard's marker. Their roster rows stay.
- World map pins sit one strata above `WorldMapFrame` (zone-map layers covered them otherwise) and are
  culled manually against `ScrollContainer`.
- New saved setting → add to `DEFAULTS` in `Core.lua` (merged into existing saves on load).
- Bump version in **both** `GhostParty.toc` and `Core.lua`.
- **Releases = push to `main` with a higher TOC version.** Friends run `updater/GhostPartyUpdater.ps1` as a
  scheduled task; it reads `## Version` from the raw TOC on GitHub and installs only if it is higher
  (`[version]` compare). Keep the addon folder at `GhostParty/` in the repo root, and keep the updater
  ASCII-only (PS 5.1). The updater replaces itself from the downloaded archive, so updater fixes ship too.

## Testing
- No Lua interpreter on the owner's machine. Run `node tools/check.js GhostParty/*.lua` (rough structure check only).
- Real testing is in game: `.\install.ps1`, `/reload`, `/angura sim`, `/angura debug`, `/angura status`.
  Turn on "Display Lua Errors". Two-player features need a friend on the same version.
- To learn what the client allows, write a temporary probe that saves its output into `GhostPartyDB`
  (the game writes the file on /reload or logout) and read the SavedVariables file directly.
- Be explicit with the owner about what was and wasn't tested in game.

## Owner preferences
- WoW look: Blizzard textures, atlases and icons, tooltip-style backdrops. No progress bars.
- Short, concrete plans; then build.
- Installing into the game folder is OK when asked; reinstall after changes so the game copy stays current.
