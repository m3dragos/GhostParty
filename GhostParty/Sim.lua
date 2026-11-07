local _, ns = ...

-- /angura sim: a fake friend who runs circles around where you stood, goes
-- in and out of combat, cycles through statuses, posts feed news and party
-- chat, and occasionally dies. Its messages go through the real encoder and
-- decoder and the same code path as a real friend's, at a real-world rate
-- (2 updates/second), so the roster, feed, chat tab and pins can be tested alone.
local Sim = {}
ns.Sim = Sim

local TAG = "Simbuddy#0000"
local NAME = "Simbuddy"
local RADIUS = 30      -- yards
local SPEED = 7        -- yards/second (running)
local RATE = 0.5       -- seconds between updates
local NEWS_EVERY = 15  -- seconds between feed events

local ticker, origin, t0, lastNews, newsIndex

local function Deliver(text)
  local msg = ns.Protocol.Decode(text)
  if msg then ns.Members:OnMessage(TAG, msg, true) end
end

local NEWS = {
  function(P) return P.EncodeEvent("lvl", 29) end,
  function(P) return P.EncodeEvent("lvl", 30) end,            -- milestone: banner and sound
  function(P) return P.EncodeEvent("rare", "Mor'Ladim", "rareelite") end,
  function(P) return P.EncodeEvent("loot", 19019, 1) end,      -- an item link that loads from the server
  function(P) return P.EncodeEvent("duel", NAME, UnitName("player") or "you") end,
  function(P) return P.EncodeChat("Hi! This is " .. NAME .. " on party chat. Try /an to answer.") end,
  function(P) return P.EncodeEvent("inst", "The Deadmines", "party") end,
  function(P) return P.EncodeEvent("dead", "Duskwood", "Darkshire") end,
}

local function Step()
  local P = ns.Protocol
  local t = GetTime() - t0
  local s = { flags = 0 }

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

  local cycle = t % 60
  if cycle > 50 and cycle < 56 then
    s.flags, s.speed = P.FLAG_DEAD, 0
  elseif cycle < 15 then
    s.flags = P.FLAG_COMBAT
  end
  Deliver(P.EncodeState(s))

  -- Statuses change every few seconds.
  local phase = math.floor(t / 6) % 4
  local status = ({ P.ST_TAXI, P.ST_RESTING + P.ST_DND, P.ST_PVP, 0 })[phase + 1]
  Deliver(P.EncodeInfo({ status = status, group = phase == 3 and 3 or 0, subzone = "Darkshire",
    race = "Human", guild = "Ghosts of Azeroth", home = "Goldshire" }))

  if t - lastNews >= NEWS_EVERY then
    lastNews = t
    newsIndex = newsIndex % #NEWS + 1
    Deliver(NEWS[newsIndex](P))
  end
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
  t0, lastNews, newsIndex = GetTime(), 0, 0
  Deliver(ns.Protocol.EncodeHello({
    want = true, level = UnitLevel("player"), class = "PRIEST", name = NAME,
    zone = GetRealZoneText() or "",
  }))
  Step()
  ticker = C_Timer.NewTicker(RATE, Step)
  ns.Print("Simulated friend added" .. (origin and ", running circles around this spot." or " (no map position here, so no pins).")
    .. " News every " .. NEWS_EVERY .. " s in the " .. ns.NAME .. " chat tab. /angura sim again to remove.")
end
