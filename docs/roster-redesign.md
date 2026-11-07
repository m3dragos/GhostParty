# Roster redesign: features and feasibility

Replaces the party frames (health and power are always secret on Forever, so the bars carried nothing).
Agreed with the owner 2026-11-07. Look: WoW art and icons (Blizzard textures and atlases), no progress bars.

Status key: **OK** = known to work (in use by us or another Forever addon), **PROBE** = API exists but
readability or behaviour on Forever is unproven: check with `/gp probe` and `/gp probe watch` before building.

## 1. Friend roster (replaces the party frames)

| Feature | Data source | Traffic | Status |
|---|---|---|---|
| Name in class colour, level | `H` message (exists) | none new | OK |
| Zone · subzone | `GetSubZoneText` in new `I` message | on change | **OK** (probe 11-07: plain on every `ZONE_CHANGED`; often `""` between named areas: show the zone alone then) |
| Distance | computed locally from `S` position | none | OK (same math as pins). Direction arrow dropped (owner) |
| "inside" when in an instance | `FLAG_INSTANCE` (exists) | none | OK |
| Left-click targets (secure) | existing click layer | none | OK |

## 2. Statuses (icons on the row)

Already sent in `S` flags: **combat, dead, ghost, AFK, in instance**. OK.

New, sent in the `I` message when they change (debounced, one slot per friend like state):

| Status | API | Status |
|---|---|---|
| Mounted | `IsMounted` | **OK** (probe 11-07, `PLAYER_MOUNT_DISPLAY_CHANGED`) |
| Flying | `IsFlying` | **OK** (probe 11-07) |
| Swimming | `IsSwimming` | **OK** (probe 11-07) |
| On a flight path | `UnitOnTaxi("player")` | **OK** (probe 11-07) |
| Resting (inn / city) | `IsResting` | **OK** (probe 11-07, `PLAYER_UPDATE_RESTING` in Thunder Bluff) |
| DND | `UnitIsDND("player")` | **OK** (probe 11-07) |
| PvP flagged | `UnitIsPVP("player")` | **OK** (probe 11-07) |
| In a real group of N | `GetNumGroupMembers` | **OK** (probe 11-07) |
| Instance type (dungeon / raid / battleground) | `GetInstanceInfo` 2nd return | **OK** ("none" outside) (probe 11-07) |

Why not more `S` flags: older clients reject `flags > 255` and would drop the whole state message.

## 3. Party feed

Rare one-shot events (`E` message, urgent queue). Shown in a feed panel; sender detects, everyone displays.

| Event | Detection | Status |
|---|---|---|
| Level up | `PLAYER_LEVEL_UP` | **OK** (probe 11-07: level 23) |
| Big milestone (10/20/30/40/50/60): banner + celebration sound | same | Event **OK**. `SOUNDKIT` has no plain level-up sound; candidates: `UI_ADVENTURES_ADVENTURER_LEVEL_UP`, `UI_GARRISON_COMMAND_TABLE_FOLLOWER_LEVEL_UP`, `HARDCORE_DUEL` (for duels). Pick by ear |
| Death | `PLAYER_DEAD` + zone | **OK** (probe 11-07) |
| Entered a dungeon / raid / battleground (only instances) | `PLAYER_ENTERING_WORLD` + `GetInstanceInfo` | OK in the open world ("Kalimdor / none"); inside an instance still PROBE |
| Came online / logged off | first `H` after being gone / `B` or Battle.net offline; skip the first ~10 s after our own login so existing friends don't spam | OK |
| Killed a rare | `CHAT_MSG_COMBAT_XP_GAIN` ("X dies, you gain N experience") + `UnitClassification("target")` is `rare` / `rareelite` (LoreForever's method; the combat log is blocked on Forever) | Kill line **OK** in the open world (plain text, open-ended pattern needed: "(+8 group bonus)" follows; quest XP "You gain N experience." correctly doesn't match). The target is often already gone when the line arrives and `UnitClassification` of no unit says "normal": remember classification by name on `PLAYER_TARGET_CHANGED`. Rare classification itself still PROBE. Limit: no XP = not seen (max level, grey mobs, AoE kills of an untargeted rare) |
| Looted rare (blue) or epic | `CHAT_MSG_LOOT` matched against `LOOT_ITEM_SELF(_MULTIPLE)`, quality from the item. Send only the item ID; the receiver builds the link (hoverable) | **OK** in the open world (link, item ID and `C_Item.GetItemQualityByID` all plain). Links use the new `|cnIQ1:` colour tag. Blue/epic and inside instances still PROBE |
| Duel won / lost | `CHAT_MSG_SYSTEM` matched against `DUEL_WINNER_KNOCKOUT` / `DUEL_WINNER_RETREAT`. Both duelists may send it: receiver drops duplicates within a few seconds | Strings **exist**. `DUEL_WINNER_RETREAT` is `%2$s has fled from %1$s` (positional, reversed): the matcher must map captures by position. Event not yet seen |

## 4. Tooltip (enhance the existing one)

Adds: race, guild, subzone, status lines (resting, DND, group size, PvP), home inn
(`GetBindLocation`, **OK**: "Thunder Bluff"; race **OK**; guild nil when guildless), last heard. Race/guild/home inn travel in `I` (rarely change).

## 5. Row buttons (insecure, so they work in combat)

| Button | API | Status |
|---|---|---|
| Invite | `C_PartyInfo.InviteUnit(name)`; hidden when already grouped | OK (EllesmereUI Friends calls it from plain buttons) |
| Uninvite | `C_PartyInfo.UninviteUnit(name)`; only when you lead and they're in your group | OK (EllesmereUI RaidTools) |
| Find | `C_Map.SetUserWaypoint` + `C_SuperTrack.SetSuperTrackedUserWaypoint` at their position; Blizzard draws the arrow. Refreshed every few seconds while tracked; unavailable when they're in an instance or the map refuses (`CanSetUserWaypointOnMap`) | OK (ForeverPlusPlus does exactly this) |

Today right-click invites through the secure layer; the buttons replace that.

## Protocol plan (no version bump)

- `1:I:...` info: subzone, race, guild, home inn, status bits (own number, not the `S` flags). Sent on change, debounced.
- `1:E:kind:...` events: `lvl`, `dead`, `inst`, `rare`, `loot`, `duel`.
- Older clients already drop unknown kinds (`Decode` returns nil, counted as "ignored"). They keep working; they just don't see the new things.
- `S` keeps its fields; hp/pw are sent as `-` from now on.

## Dropped (owner's call)

Progress / XP bar, quest completions, zone changes outside instances, boss kills, flights in the feed,
level difficulty colours, sorting, feed settings beyond on/off.

## Probe results summary (2026-11-07, open world, level 22-23 Tauren)

Readable: all statuses, subzone, race, home, instance info, `PLAYER_DEAD`, `PLAYER_LEVEL_UP`, kill XP line, own loot
lines with item ID and quality. APIs present: `C_PartyInfo.InviteUnit/UninviteUnit`, user waypoint + super track,
`C_Item.GetItemQualityByID`, `Item.CreateFromItemID`, `C_Texture.GetAtlasInfo`. Atlases present: `Dungeon`, `Raid`,
`socialqueuing-icon-group`, `poi-graveyard-neutral`, `XMarksTheSpot`, `Waypoint-MapPin-Untracked`, `groupfinder-icon-friend`.
Not yet observed: anything inside an instance, a duel, a rare, blue+ loot. Build so a secret or unmatched line is skipped.

## Inside instances (research 2026-11-07, not yet seen in game)

- Midnight's rule (Forever inherits it): chat-line text (`CHAT_MSG_*`) is secret only during **chat messaging
  lockdown**, which Blizzard narrowed during the alpha from "whole instance" to **active boss encounters /
  Mythic+ runs**. Dungeon trash, looting after a boss and the open world stay readable. Sources: Icy Veins
  ("Combat Addon Restrictions Eased in Midnight"), DIM and Whisper Messenger addon pages; LibForever-1.0's comment
  (BagWarden) that the chat-line getters carry `SecretInChatMessagingLockdown` while addon sends don't.
- Corroboration on Forever: LoreForever detects dungeon bosses from the same XP kill line **or** `ENCOUNTER_END`
  and de-duplicates a boss "reported both ways", i.e. the kill line works in dungeons but can be missing for a boss.
- What that means for the feed: deaths, level-ups and dungeon entry are events, not chat: unaffected. Rare kills
  and duels are open-world: unaffected. Loot is normally looted after the fight: fine; a line that arrives
  secret is skipped.
- Sending: addon sends can be refused during an encounter (`Enum.SendAddonMessageResult.AddOnMessageLockdown`).
  `Comm` drops "failed" urgent messages today, so feed events would be lost. Plan: hold `E` messages between
  `ENCOUNTER_START` and `ENCOUNTER_END` (encounter-scoped, so the open-world false lockdown doesn't matter) and
  retry a send refused for lockdown instead of dropping it.

## Build plan (0.4.0)

Everyone must update to see the new things; older clients keep working (they ignore `I`, `E`, `C`).

1. **Protocol** (`Protocol.lua`, pure Lua): `I` (info: subzone, race, guild, home, status bits), `E` (event:
   kind + args), `C` (chat text). Sanitize incoming text (strip `|` escapes except item links we rebuild ourselves).
2. **Comm**: a second "latest per friend" slot for `I`; urgent sends refused for lockdown are retried, not dropped;
   `E` and `C` held between `ENCOUNTER_START` and `ENCOUNTER_END`.
3. **State**: sample statuses/info on their events (mount, resting, zone, group, flags...), send `I` on change,
   debounced. Stop sending hp/pw (`-`), drop the percent fallback.
4. **Feed** (`Feed.lua`): detectors for level-up (+ milestone banner and sound), death, instance entry, rare kill,
   blue+ loot, duel, online/offline; receiver turns `E` into lines with class-coloured names and real item links.
5. **Chat window**: a native Blizzard chat tab "GhostParty" (created once, then the player's to move, dock or close;
   if closed, lines go to the main chat frame). Feed lines and party chat both go there.
6. **Party chat**: `/gpc <text>` sends to every friend you share with who is live (Battle.net, whisper fallback).
   Experiment, kept only if it doesn't taint: Enter in the GhostParty tab pre-fills `/gpc `.
7. **Roster** (`Frames.lua` rewrite): rows with class icon, name, level, zone · subzone, distance + arrow, status
   icons; secure left-click target kept; insecure Invite / Uninvite / Find buttons; tooltip enhanced.
8. **Sim, docs, version**: `/gp sim` also sends `I` and some `E`; update `AGENTS.md`; remove the probe; 0.4.0.

## Build status (0.4.0, 2026-11-07)

Built as planned, except: the "Enter in the Angura tab pre-fills `/an `" experiment was left out (hooking
the chat edit box is the fragile part on this client). Display name "Angura", `/angura` = `/gp`, `/an` = party
chat. The probe (`Probe.lua`) is removed. Not yet tested in game.

Mounted and swimming dropped after the first in-game look (owner: unnecessary); their bits stay reserved.
