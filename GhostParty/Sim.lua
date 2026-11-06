local _, ns = ...

-- /gp sim: a fake friend who runs circles around where you stood, takes
-- damage, enters combat and occasionally dies. Its messages go through the
-- real encoder/decoder and the same code path as a real friend's, at a
-- real-world rate (2 updates/second), so frames, pins and smoothing can be
-- tested alone.
local Sim = {}
ns.Sim = Sim

local TAG = "Simbuddy#0000"
local RADIUS = 30      -- yards
local SPEED = 7        -- yards/second (running)
local RATE = 0.5       -- seconds between updates

local ticker, origin, t0

local function Deliver(text)
  local msg = ns.Protocol.Decode(text)
  if msg then ns.Members:OnMessage(TAG, msg, true) end
end

local function Step()
  local P = ns.Protocol
  local t = GetTime() - t0
  local s = { flags = 0, pwType = 0 }

  if origin then
    local w, h = ns.Call(C_Map.GetMapWorldSize, origin.map)
    if w and w > 0 then
      local a = t * SPEED / RADIUS
      s.map = origin.map
      s.x = origin.x + math.cos(a) * RADIUS / w
      s.y = origin.y - math.sin(a) * RADIUS / h
      s.facing = (a + math.pi) % (2 * math.pi) -- tangent to the circle, roughly
      s.speed = SPEED
    end
  end

  s.hpMax, s.pwMax = 1450, 2200
  local cycle = t % 60
  if cycle > 50 and cycle < 56 then
    s.hp, s.pw, s.flags, s.speed = 0, 0, P.FLAG_DEAD, 0
  else
    s.hp = math.floor(s.hpMax * (0.6 + 0.4 * math.cos(t / 5)))
    s.pw = math.floor(s.pwMax * (0.5 + 0.5 * math.sin(t / 7)))
    if s.hp < s.hpMax * 0.8 then s.flags = P.FLAG_COMBAT end
  end
  Deliver(P.EncodeState(s))
end

function Sim:Toggle()
  if ticker then
    ticker:Cancel()
    ticker = nil
    ns.Members:Forget(TAG)
    ns.Frames:Refresh()
    return ns.Print("Simulated friend removed.")
  end
  local map, x, y = ns.Geo.Player()
  origin = map and { map = map, x = x, y = y } or nil
  t0 = GetTime()
  Deliver(ns.Protocol.EncodeHello({
    level = UnitLevel("player"), class = "PRIEST", name = "Simbuddy",
    zone = GetRealZoneText() or "",
  }))
  Step()
  ticker = C_Timer.NewTicker(RATE, Step)
  ns.Print("Simulated friend added" .. (origin and ", running circles around this spot." or " (no map position here, so no pins).")
    .. " /gp sim again to remove.")
end
