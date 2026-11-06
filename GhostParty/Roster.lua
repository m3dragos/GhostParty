local _, ns = ...

-- Who you share with. Members are Battle.net friends, stored by BattleTag
-- (stable across characters). Online ones are found by scanning the
-- Battle.net friends list for game accounts playing Forever.
local R = {}
ns.Roster = R

local online = {}     -- battleTag -> { gameAccountID, name, level, className, area, accountName }
local byGameID = {}   -- gameAccountID -> battleTag
local elsewhere = {}  -- battleTag -> true: visible on Battle.net, but not in any WoW client
local lastListing = {} -- index -> battleTag, from the last /gp friends

-- On Forever the client reports WOW_PROJECT_ID 1 (like Retail), but Battle.net
-- labels Forever as its own project. Compare against our own Battle.net entry.
local myProject
local function MyProject()
  if myProject then return myProject end
  if C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID and UnitGUID then
    local g = ns.Call(C_BattleNet.GetGameAccountInfoByGUID, UnitGUID("player"))
    if type(g) == "table" and g.wowProjectID then
      myProject = g.wowProjectID
      return myProject
    end
  end
  return WOW_PROJECT_ID
end

local function SameGame(g)
  return g.wowProjectID == nil or g.wowProjectID == MyProject()
end

local function Key(s) return s and s:lower() end

function R:Scan()
  wipe(online)
  wipe(byGameID)
  wipe(elsewhere)
  if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return end
  local total = ns.Call(BNGetNumFriends)
  for i = 1, (total or 0) do
    local a = ns.Call(C_BattleNet.GetFriendAccountInfo, i)
    local tag = type(a) == "table" and ns.Plain(a.battleTag)
    if tag then
      local n = ns.Call(C_BattleNet.GetFriendNumGameAccounts, i) or 0
      local inWow, visible = false, false
      for j = 1, n do
        local g = ns.Call(C_BattleNet.GetFriendGameAccountInfo, i, j)
        if type(g) == "table" and g.isOnline then
          visible = true
          if g.clientProgram == BNET_CLIENT_WOW then inWow = true end
        end
        if type(g) == "table" and g.isOnline and g.clientProgram == BNET_CLIENT_WOW
          and g.gameAccountID and g.characterName and g.characterName ~= "" and SameGame(g) then
          local realm = g.realmName and g.realmName ~= "" and g.realmName:gsub("%s", "") or nil
          online[tag] = {
            gameAccountID = g.gameAccountID,
            name = g.characterName,
            full = realm and (g.characterName .. "-" .. realm) or g.characterName,
            level = g.characterLevel,
            className = g.className,
            area = g.areaName,
            accountName = a.accountName,
          }
          byGameID[g.gameAccountID] = tag
        end
      end
      -- Appear Offline hides the whole account, so someone visibly online in
      -- the Battle.net app or another game can't be in Forever: don't probe.
      if visible and not inWow then elsewhere[tag] = true end
    end
  end
  -- Use Battle.net's spelling for members typed by hand ("bob#1234" -> "Bob#1234"),
  -- so the list, messages and frames all use the same key.
  if ns.db then
    for i, t in ipairs(ns.db.members) do
      for tag in pairs(online) do
        if tag ~= t and Key(tag) == Key(t) then ns.db.members[i] = tag end
      end
    end
    -- Remember members' characters: needed to reach them by whisper when
    -- they set Battle.net to "Appear Offline".
    for _, t in ipairs(ns.db.members) do
      if online[t] then self:RememberChar(t, online[t].full) end
    end
  end
  ns.Debug("scanned Battle.net:", self:CountOnline(), "friend(s) in Forever")
end

---------------------------------------------------------------------------
-- Characters and routes
--
-- Normally we reach a friend over Battle.net. When they "Appear Offline",
-- Battle.net hides their game account, so we fall back to addon whispers
-- to the character names we've seen them play (any message from them by
-- whisper or Battle.net also tells us they're reachable that way).
---------------------------------------------------------------------------
local ROUTE_FRESH = 60       -- a route learned from a received message lasts this long
local MAX_CHARS = 5

local lastBN = {}            -- tag -> { id = gameAccountID, at = GetTime() }
local lastWhisper = {}       -- tag -> { name = "Name-Realm", at = GetTime() }

local function ShortName(n) return n and (n:match("^([^%-]+)") or n) end

function R:RememberChar(tag, full)
  if not (tag and full and full ~= "") then return end
  ns.db.chars[tag] = ns.db.chars[tag] or {}
  local list = ns.db.chars[tag]
  for i = #list, 1, -1 do
    if Key(list[i]) == Key(full) then table.remove(list, i) end
  end
  table.insert(list, 1, full)
  while #list > MAX_CHARS do table.remove(list) end
end

function R:Chars(tag) return ns.db.chars[tag] or {} end

-- Which member a character belongs to ("Name-Realm" or just "Name").
function R:TagForCharacter(name)
  if not name then return nil end
  local k, short = Key(name), Key(ShortName(name))
  local hasRealm = name:find("-", 1, true) ~= nil
  for _, tag in ipairs(ns.db.members) do
    local o = online[tag]
    if o and Key(o.full) == k then return tag end
    for _, c in ipairs(self:Chars(tag)) do
      if Key(c) == k then return tag end
    end
  end
  -- One side has no realm part: match on the character name alone.
  for _, tag in ipairs(ns.db.members) do
    local o = online[tag]
    if o and Key(o.name) == short then return tag end
    for _, c in ipairs(self:Chars(tag)) do
      if (not hasRealm or not c:find("-", 1, true)) and Key(ShortName(c)) == short then return tag end
    end
  end
end

function R:HeardViaBattleNet(tag, id) lastBN[tag] = { id = id, at = GetTime() } end
function R:HeardViaWhisper(tag, name)
  lastWhisper[tag] = { name = name, at = GetTime() }
  self:RememberChar(tag, name)
end

-- How to reach a member right now: "BN", gameAccountID | "WHISPER", name | nil.
function R:Route(tag)
  local now = GetTime()
  local w = lastWhisper[tag]
  if w and now - w.at < ROUTE_FRESH then return "WHISPER", w.name end
  local o = online[tag]
  if o then return "BN", o.gameAccountID end
  local b = lastBN[tag]
  if b and now - b.at < ROUTE_FRESH then return "BN", b.id end
end

-- Members we can't reach and who might be Appearing Offline: candidates for a whisper probe.
function R:Unreachable()
  local out = {}
  for _, tag in ipairs(ns.db.members) do
    if not self:Route(tag) and not elsewhere[tag] then out[#out + 1] = tag end
  end
  return out
end

function R:CountOnline()
  local n = 0
  for _ in pairs(online) do n = n + 1 end
  return n
end

function R:Online(tag) return online[tag] end

function R:TagForGameAccount(id)
  local tag = byGameID[id]
  if not tag then
    self:Scan()
    tag = byGameID[id]
  end
  -- Not listed (e.g. they Appear Offline): identify them by character instead.
  if not tag and C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
    local g = ns.Call(C_BattleNet.GetGameAccountInfoByID, id)
    if type(g) == "table" and g.characterName and g.characterName ~= "" then
      local realm = g.realmName and g.realmName ~= "" and g.realmName:gsub("%s", "") or nil
      tag = self:TagForCharacter(realm and (g.characterName .. "-" .. realm) or g.characterName)
    end
  end
  return tag
end

function R:IsMember(tag)
  if not tag then return false end
  for _, t in ipairs(ns.db.members) do
    if Key(t) == Key(tag) then return true end
  end
  return false
end

-- Reachable members as { tag, kind = "BN"|"WHISPER", target } (for sending).
function R:OnlineMembers()
  local out = {}
  for _, tag in ipairs(ns.db.members) do
    local kind, target = self:Route(tag)
    if kind then out[#out + 1] = { tag = tag, kind = kind, target = target } end
  end
  return out
end

-- Accepts a number from /gp friends, a BattleTag, or a character name.
local function Resolve(arg)
  arg = arg and strtrim(arg) or ""
  if arg == "" then return nil end
  local idx = tonumber(arg)
  if idx then return lastListing[idx] end
  if arg:find("#", 1, true) then
    for tag in pairs(online) do
      if Key(tag) == Key(arg) then return tag end
    end
    for _, tag in ipairs(ns.db.members) do
      if Key(tag) == Key(arg) then return tag end
    end
    return arg
  end
  for tag, o in pairs(online) do
    if Key(o.name) == Key(arg) then return tag end
  end
  for _, tag in ipairs(ns.db.members) do
    if Key(tag:match("^[^#]+")) == Key(arg) then return tag end
  end
end

function R:AddMember(arg)
  self:Scan()
  local tag = Resolve(arg)
  if not tag then
    return ns.Print("Couldn't find that friend. Use /gp friends, then /gp add <number>.")
  end
  if self:IsMember(tag) then return ns.Print(tag, "is already in your ghost party.") end
  table.insert(ns.db.members, tag)
  ns.Print("Added", tag .. ". They need GhostParty too, and need to add you back.")
  if online[tag] then ns.State:SendHello(true, tag) end
  ns.Frames:Refresh()
end

function R:RemoveMember(arg)
  local tag = Resolve(arg)
  for i, t in ipairs(ns.db.members) do
    if tag and Key(t) == Key(tag) then
      table.remove(ns.db.members, i)
      ns.Members:Forget(t)
      ns.Print("Removed", t .. ".")
      ns.Frames:Refresh()
      return
    end
  end
  ns.Print("They aren't in your ghost party. /gp list shows who is.")
end

function R:PrintFriends()
  self:Scan()
  wipe(lastListing)
  local tags = {}
  for tag in pairs(online) do tags[#tags + 1] = tag end
  table.sort(tags)
  if #tags == 0 then return ns.Print("No Battle.net friends are online in Forever right now.") end
  ns.Print("Battle.net friends in Forever:")
  for i, tag in ipairs(tags) do
    lastListing[i] = tag
    local o = online[tag]
    ns.Print(("  %d. %s - %s (level %s %s, %s)%s"):format(i, tag, o.name, tostring(o.level or "?"),
      o.className or "?", o.area or "?", self:IsMember(tag) and "  |cff55ff55[in party]|r" or ""))
  end
  ns.Print("Add one with /gp add <number>.")
end

function R:PrintMembers()
  self:Scan()
  if #ns.db.members == 0 then return ns.Print("Nobody yet. /gp friends, then /gp add <number>.") end
  ns.Print("Your ghost party:")
  for _, tag in ipairs(ns.db.members) do
    local o = online[tag]
    local m = ns.Members:Get(tag, true)
    local state
    local kind = self:Route(tag)
    if m and m.live then state = "|cff55ff55live|r" .. (kind == "WHISPER" and " (via whisper: Appear Offline)" or "")
    elseif o then state = "|cffffd100online, no GhostParty data yet|r"
    else state = "|cff888888offline|r" end
    ns.Print(("  %s%s - %s"):format(tag, o and (" (" .. o.name .. ")") or "", state))
  end
end

-- Rescan on Battle.net changes (debounced: these events come in bursts).
local scanPending = false
local function ScanSoon()
  if scanPending then return end
  scanPending = true
  C_Timer.After(1, function()
    scanPending = false
    local before = {}
    for tag in pairs(online) do before[tag] = true end
    R:Scan()
    for tag in pairs(online) do
      if not before[tag] and R:IsMember(tag) then
        ns.Debug(tag, "came online; saying hello")
        ns.State:SendHello(true, tag)
      end
    end
    -- Gone from Battle.net: they logged off, or switched to Appear Offline.
    -- Probe their character by whisper; only drop the frame if they stay silent.
    for tag in pairs(before) do
      if not online[tag] and R:IsMember(tag) then
        local wentAt = GetTime()
        ns.Comm:ResetProbe(tag)
        ns.Comm:Probe(tag)
        C_Timer.After(20, function()
          local r = ns.Members:Get(tag, true)
          if not online[tag] and r and (r.heardAt or 0) < wentAt then ns.Members:MarkOffline(tag) end
        end)
      end
    end
  end)
end

ns:On("BN_FRIEND_INFO_CHANGED", ScanSoon)
ns:On("BN_FRIEND_ACCOUNT_ONLINE", ScanSoon)
ns:On("BN_FRIEND_ACCOUNT_OFFLINE", ScanSoon)
ns:On("BN_CONNECTED", ScanSoon)
ns:On("PLAYER_LOGIN", ScanSoon)
