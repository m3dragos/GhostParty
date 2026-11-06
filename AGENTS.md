# AGENTS.md

Notes for AI agents and contributors working on GhostParty.

## What this is
A WoW: Forever addon. Friends who are **not grouped** see each other as party members:
party-style frames + minimap/world map pins. Each client broadcasts its own state; nothing is
read from other players' units (impossible when ungrouped). Owner plays with Battle.net friends only.

## Client facts (verified 2026-11 against the live install and the Kinship addon)
- Forever = `wowf` product, client **1.60.1.70790**, TOC `## Interface: 16001`.
- It runs on the **Retail (12.x) client**: Retail APIs (`C_Map`, `C_BattleNet`, `C_ChatInfo`, atlases),
  Classic globals are gone. Midnight-era restrictions apply.
- **Secret values**: unit stats (incl. `UnitHealth("player")`) can be secret in combat. Never compare or
  send a secret: wrap reads with `ns.Plain` / `ns.Call` (returns nil for secrets). `issecretvalue` may not exist: guard it.
- Battle.net reports Forever with its **own `wowProjectID`**, while the client's `WOW_PROJECT_ID` is 1.
  Compare friends against our own entry (`C_BattleNet.GetGameAccountInfoByGUID(UnitGUID("player"))`).
- `BN_CHAT_MSG_ADDON` args: `prefix, text, channel, gameAccountID`. Send with
  `C_BattleNet.SendGameData(gameAccountID, prefix, text)` (fallback `BNSendGameData`).
- `CHAT_MSG_ADDON` 5th arg is the target, not a flag: only use the first four.
- No map coordinates inside instances (`C_Map.GetPlayerMapPosition` returns nil).
- Trial / Invite-A-Friend accounts cannot send addon messages.
- Throttle: ~10-message burst per prefix, ~1/s refill. We assume the same for Battle.net game data.
- `C_ChatInfo.InChatMessagingLockdown()` exists on Forever (Midnight addon-comm restriction); treat a secret result as locked.
  `SendAddonMessage` returns `Enum.SendAddonMessageResult`: anything but `Success` is a failure, throttle codes mean retry.
- "Appear Offline" hides a friend's game account from Battle.net: fall back to addon `WHISPER` to known characters.
- Party frame art: atlas `UI-HUD-UnitFrame-Party-PortraitOn` (+ `-Bar-Health-Mask`, `-Bar-Mana-Mask`,
  `ui-hud-unitframe-party-portraiton-incombat`); fallback `Interface\TargetingFrame\UI-PartyFrame`.
- Local install (owner's machine): `G:\Games\World of Warcraft\_forever_\Interface\AddOns\`.
  Other installed addons there (Kinship, EllesmereUI) are useful **read-only** API references. Never edit them.

## Architecture (`GhostParty/`, load order = TOC order)
| File | Role |
|---|---|
| `Core.lua` | namespace, event bus `ns:On`, saved vars `GhostPartyDB` (defaults table), helpers, slash commands, `ns.SetSharing`, `ns.SetFramesShown` |
| `Protocol.lua` | pure-Lua wire format (no WoW API): `EncodeState/Hello/Bye`, `Decode`, flags |
| `Roster.lua` | Battle.net scan, members by BattleTag, remembered characters, **routing** (`Route(tag)` → BN or WHISPER) |
| `Comm.lua` | token buckets over 4 prefixes; priority urgent FIFO > latest-state-per-friend > whisper probes (spare tokens only); pauses during `InChatMessagingLockdown`; BN + whisper send/receive; probe backoff; "No player named" chat filter |
| `State.lua` | samples own character every 0.1 s, sends on change (2.5 yd, start/stop, turn, stats) + 4 s heartbeat; hellos |
| `Members.lua` | per-friend records, staleness, velocity estimate, smoothed predicted position |
| `Frames.lua` | party-style frames, created on demand (no member cap), one column growing downward (owner's choice: no wrapping); visual layer (insecure) + click layer (secure: left `/target`, right `/invite` unless grouped) |
| `Pins.lua` | `ns.Geo` map math, minimap pins, world map pins |
| `Sim.lua` | `/gp sim` fake friend through the real encode/decode path |
| `Button.lua` | minimap button (left: frames, right: sharing) |

Protocol v1: `1:S:map:x:y:facing:speed:hp:hpMax:pw:pwMax:pwType:flags`, `1:H:want:level:class:name:zone`, `1:B`.
`-` = unknown. Changing field count breaks older clients: bump `P.VERSION` and tell the owner everyone must update.

## Rules that are easy to break
- **Combat lockdown**: secure click buttons can't be shown, hidden, moved or re-attributed in combat.
  Visual frames must not be anchor targets of secure frames (click buttons are anchored to the anchor frame).
  Defer with `pendingSecure` and apply on `PLAYER_REGEN_ENABLED`. A slot's secure button is created
  lazily out of combat (`EnsureSlot`); a friend appearing mid-combat gets a frame but no click until combat ends.
- More members = same total send budget split thinner (4 prefixes × ~1 msg/s). Don't "fix" by raising rates.
- Every WoW API call that can fail or return secrets goes through `ns.Call` or `pcall`.
- Lua 5.1: no `goto`, no `//`, no `+=`, use `math.floor`, not bit ops (Protocol must stay WoW-free).
- Keep traffic low: the owner explicitly does **not** want higher polling/send rates; improve display
  (prediction/easing) instead.
- Whisper probes back off per member (20 s doubling to 5 min, reset when heard from or when they leave
  Battle.net) and skip friends visible on Battle.net outside WoW. Never go back to fixed-rate probing
  of offline characters: it is the one traffic pattern that looks like spam.
- Friends in your real group (`Geo.InMyGroup` returns their unit token, refreshed on `GROUP_ROSTER_UPDATE`):
  no minimap pin; world map shows a name-only label (no dot, mouse disabled) positioned with
  `C_Map.GetPlayerMapPosition(mapID, unit)` so it sits on Blizzard's marker. Their frames stay.
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
- Real testing is in game: `.\install.ps1`, `/reload`, `/gp sim`, `/gp debug`, `/gp status`.
  Turn on "Display Lua Errors". Two-player features need a friend on the same version.
- Be explicit with the owner about what was and wasn't tested in game.

## Owner preferences
- Frames should look like Blizzard party frames.
- Short, concrete plans; then build.
- Installing into the game folder is OK when asked; reinstall after changes so the game copy stays current.
