local _, ns = ...

-- Samples YOUR character and decides when to broadcast it.
-- State (S): sent when you move a few yards, start/stop moving, turn, or your
-- flags change, plus a heartbeat so friends know you're live.
-- Info (I): statuses and tooltip details, sent when they change (checked once
-- a second, at most every few seconds) and with every hello.
-- Health and power are not sent: they are always secret on Forever.
local S = {}
ns.State = S

local Call, Plain = ns.Call, ns.Plain
local P = ns.Protocol

local TICK = 0.1
local MOVE_YARDS = 2.5
local TURN_DEGREES = 25
local HEARTBEAT = 4
local HELLO_EVERY = 30
local INFO_CHECK = 1      -- seconds between info samples
local INFO_MIN_GAP = 3    -- seconds between info sends (statuses settle first)

local last          -- last state sent
local lastSentAt = 0
local lastInfo      -- last info text sent
local lastInfoAt, lastInfoCheck = 0, 0

local function MapSize(mapID)
  if not (C_Map and C_Map.GetMapWorldSize) then return nil end
  local w, h = Call(C_Map.GetMapWorldSize, mapID)
  if w and h and w > 0 and h > 0 then return w, h end
end

function S:Sample()
  local s = { flags = 0 }
  local inInstance = Call(IsInInstance)

  if not inInstance and C_Map and C_Map.GetBestMapForUnit then
    local map = Call(C_Map.GetBestMapForUnit, "player")
    local pos = map and Call(C_Map.GetPlayerMapPosition, map, "player")
    if pos then
      local x, y = pos:GetXY()
      s.map, s.x, s.y = map, Plain(x), Plain(y)
    end
  end
  s.facing = Call(GetPlayerFacing)
  s.speed = Call(GetUnitSpeed, "player")

  local f = 0
  if Call(UnitIsGhost, "player") then f = f + P.FLAG_GHOST
  elseif Call(UnitIsDead, "player") then f = f + P.FLAG_DEAD end
  if Call(UnitAffectingCombat, "player") then f = f + P.FLAG_COMBAT end
  if Call(UnitIsAFK, "player") then f = f + P.FLAG_AFK end
  if inInstance then f = f + P.FLAG_INSTANCE end
  s.flags = f
  return s
end

function S:SampleInfo()
  local st = 0
  local function bit(on, b) if on then st = st + b end end
  -- Mounted and swimming aren't sent (owner: unnecessary): fewer info updates too.
  bit(Call(IsFlying), P.ST_FLYING)
  bit(Call(UnitOnTaxi, "player"), P.ST_TAXI)
  bit(Call(IsResting), P.ST_RESTING)
  bit(Call(UnitIsDND, "player"), P.ST_DND)
  bit(Call(UnitIsPVP, "player"), P.ST_PVP)
  local instType
  if Call(IsInInstance) then
    local _, kind = Call(GetInstanceInfo)
    if kind and kind ~= "none" then instType = kind end
  end
  return {
    status = st,
    group = Call(GetNumGroupMembers) or 0,
    instType = instType,
    subzone = Call(GetSubZoneText),
    race = Call(UnitRace, "player"),
    guild = Call(GetGuildInfo, "player"),
    home = Call(GetBindLocation),
  }
end

function S:InfoText() return P.EncodeInfo(self:SampleInfo()) end

local function Moved(a, b)
  if a.map ~= b.map or (a.x == nil) ~= (b.x == nil) then return true end
  if not a.x then return false end
  local w, h = MapSize(a.map)
  if not w then return math.abs(a.x - b.x) + math.abs(a.y - b.y) > 0.001 end
  local dx, dy = (a.x - b.x) * w, (a.y - b.y) * h
  return dx * dx + dy * dy >= MOVE_YARDS * MOVE_YARDS
end

local function Turned(a, b)
  if not (a.facing and b.facing) then return false end
  local d = math.abs(math.deg(a.facing - b.facing)) % 360
  if d > 180 then d = 360 - d end
  return d >= TURN_DEGREES and (a.speed or 0) > 0
end

local function StartedOrStopped(a, b)
  return ((a.speed or 0) > 0) ~= ((b.speed or 0) > 0)
end

function S:Tick()
  if not ns.db.sharing or not ns.Comm:HasTargets() then return end
  local s = self:Sample()
  local now = GetTime()
  local changed = not last or Moved(s, last) or Turned(s, last) or StartedOrStopped(s, last) or s.flags ~= last.flags
  if changed or now - lastSentAt >= HEARTBEAT then
    ns.Comm:SendState(P.EncodeState(s))
    last, lastSentAt = s, now
  end

  if now - lastInfoCheck >= INFO_CHECK and now - lastInfoAt >= INFO_MIN_GAP then
    lastInfoCheck = now
    local text = self:InfoText()
    if text ~= lastInfo then
      ns.Comm:SendInfo(text)
      lastInfo, lastInfoAt = text, now
    end
  end
end

function S:PrintSelf()
  ns.Print("Last state sent: " .. (last and P.EncodeState(last) or "nothing yet"))
  ns.Print("Last info sent: " .. (lastInfo or "nothing yet"))
end

function S:HelloText(want)
  local _, class = UnitClass("player")
  return P.EncodeHello({
    want = want,
    level = Call(UnitLevel, "player"),
    class = class,
    name = UnitName("player"),
    zone = Call(GetRealZoneText) or Call(GetZoneText) or "",
  })
end

function S:SendHello(want, tag)
  if not ns.db.sharing then return end
  ns.Comm:SendUrgent(self:HelloText(want), tag)
  -- Make sure whoever we greet also gets a full state and info soon.
  lastSentAt = 0
  local text = self:InfoText()
  ns.Comm:SendInfo(text, tag)
  if not tag then lastInfo, lastInfoAt = text, GetTime() end
end

-- Feed events go through the urgent queue, held during boss encounters.
function S:SendEvent(kind, ...)
  if not ns.db.sharing or not ns.Comm:HasTargets() then return end
  ns.Comm:SendUrgent(P.EncodeEvent(kind, ...), nil, true)
end

ns:On("PLAYER_LOGIN", function()
  C_Timer.NewTicker(TICK, function() S:Tick() end)
  C_Timer.NewTicker(HELLO_EVERY, function()
    if ns.Comm:HasTargets() then S:SendHello(false) end
  end)
  -- Battle.net needs a moment after login before friends are listed.
  C_Timer.After(5, function()
    ns.Roster:Scan()
    S:SendHello(true)
    -- Members not on Battle.net may be Appearing Offline: try their characters.
    for _, tag in ipairs(ns.Roster:Unreachable()) do ns.Comm:Probe(tag) end
  end)
  if not ns.db.sharing then
    C_Timer.After(6, function()
      ns.Print("Sharing is stopped: friends can't see you. /angura start to resume.")
    end)
  end
end)

ns:On("PLAYER_LEVEL_UP", function() C_Timer.After(1, function() S:SendHello(false) end) end)
ns:On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, function() S:SendHello(false) end) end)
ns:On("PLAYER_LOGOUT", function()
  if ns.db.sharing then ns.Comm:SendNow(ns.Protocol.EncodeBye(P.BYE_LOGOUT)) end
end)
