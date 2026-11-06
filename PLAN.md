# GhostParty — virtual party for WoW: Forever

## Status (2026-11-05)
v0.1.0 written in `GhostParty/` (M1–M4 done, M5 partly: slash options only, no options panel / channel mode).
Decisions since the plan: everyone is a Battle.net friend, so transport is Battle.net only
(`C_BattleNet.SendGameData`), members keyed by BattleTag, interface 16001 (client 1.60.1).
Learned from the installed Kinship addon: Forever runs the Retail client, stats are secret in combat,
and Battle.net reports Forever under its own wowProjectID.
**Not yet tested in game.** Next: `/gp sim` solo test, then a 2-player test.

Goal: friends who are **not grouped** see each other as if they were: party-style frames
(HP/power/level/status) and near-realtime map + minimap pins.

## 1. Analysis

### Constraints
| Area | Fact | Consequence |
|---|---|---|
| Data source | Ungrouped players' units aren't queryable | Every member runs the addon and **broadcasts their own state** |
| Throttle | ~10-msg burst per prefix, refills ~1/s | Budget ≈ 1 msg/s per prefix → coalesce, send on change only |
| Transport | `WHISPER` = same/connected realm; `BNSendGameData` = BNet friends, any realm; custom channel = 1 msg reaches all | Support WHISPER + BN in v1; channel mode for 3+ members in v2 |
| Trial accounts | Can't send addon messages on Forever | Invite-A-Friend/trial users are receive-only — show a warning |
| Midnight "secret values" | Some unit values may be secret in combat/instances | Wrap reads in `issecretvalue()` checks; send last-known value or omit |
| Instances | No map coordinates inside dungeons/raids | Fall back to "in <instance name>" |
| Game mechanics | No shared tags/quest kill credit when ungrouped | Out of scope; document for users |

### Bandwidth budget (per sender, 1 prefix)
- `P` position: on move ≥ 3 yd, max 1/s (~20 B)
- `S` status: HP/power/dead/combat on change, max 1 per 2 s, merged into `P` when possible
- `H` hello/heartbeat: every 10 s (level, class, zone, version)
- `B` bye on logout
Worst case ≈ 1.1 msg/s → fits. With N members over WHISPER, cost is N×; above 2 friends, rotate sends
across 2–3 prefixes or switch to channel mode.

### Protocol (v1, plain text, `|`-separated)
```
GP1|P|mapID|x|y|facing|hp%|pw%|flags     x,y = 0..9999, facing = 0..359, flags = dead/ghost/combat/afk bits
GP1|H|level|classFile|zoneText|addonVer
GP1|B
```
Receiver accepts only from roster names, validates every field, ignores unknown versions.

### Rendering
- **Frames:** plain (non-secure) StatusBar frames styled like party frames; class color, level,
  stale (grey after 10 s) / offline (30 s) / dead states; draggable. Click-to-target via a
  `SecureActionButtonTemplate` with `/target Name`, attributes set only out of combat.
- **Pins:** HereBeDragons-2.0 (+ Pins) for world map and minimap; **dead reckoning** in `OnUpdate`
  (velocity from last two samples, clamp at 2 s) so movement looks continuous.

## 2. Plan

| # | Milestone | Done when |
|---|---|---|
| 0 | **In-game spike** (you + 1 friend, ~30 min): `/dump select(4,GetBuildInfo())`, test whisper + BN addon messages, `C_Map.GetPlayerMapPosition("player")`, `UnitHealth("player")` in combat (secret?) | We know interface number and which APIs work |
| 1 | **Core:** `.toc`, SavedVariables, roster (`/gp add/remove/list`), comms layer with token-bucket throttle, protocol encode/decode, `/gp debug` | Two clients log each other's decoded messages |
| 2 | **Frames:** party-style frames, states, drag/lock, click-to-target | Friend's HP/level visible and updating |
| 3 | **Map pins:** minimap + world map pins, interpolation, instance fallback | Friend glides smoothly on minimap |
| 4 | **Solo test mode:** `/gp sim` fakes a friend walking circles + taking damage | Can develop/test without a second client |
| 5 | **Polish:** options panel, channel mode for 3+, trial-account warning, distance text | Ready to share with the group |

Order of work: 1 → 4 → 2 → 3 → 5 (sim mode early so most testing is solo).
Offline: protocol + throttle unit-tested with plain Lua and a small WoW API stub.

### File layout
```
GhostParty/
  GhostParty.toc
  Libs/ (LibStub, HereBeDragons-2.0)
  Core.lua      -- init, saved vars, slash commands, roster
  Comm.lua      -- transports, throttle, protocol
  State.lua     -- local state sampling + change detection
  Frames.lua    -- party-style frames
  Pins.lua      -- map/minimap pins + interpolation
  Sim.lua       -- fake member for testing
```

## 3. Open questions (answer before / during M1)
1. How many friends, same realm/guild, or Battle.net friends across realms?
2. Frame look: Blizzard-party-like or minimal bars?
3. Any member on a trial / Invite-A-Friend code?
