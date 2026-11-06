local _, ns = ...

-- What we know about each friend, built from their messages, plus position
-- prediction so pins move smoothly between updates.
local M = {}
ns.Members = M

M.STALE_AFTER = 10    -- seconds without a message: shown greyed out
M.HIDE_AFTER = 180    -- ...and then dropped from the frames
local MAX_EXTRAPOLATE = 0.75  -- seconds of prediction past the last update
local EASE_SECONDS = 0.25     -- how quickly the drawn pin catches up
local SNAP_YARDS = 40         -- further than this: jump instead of sliding
local MAX_SPEED = 30          -- yards/second cap on predicted speed

local recs = {}       -- tag -> record
local noticed = {}    -- non-members we've already told you about

function M:Get(tag, noCreate)
  local r = recs[tag]
  if not r and not noCreate then
    r = { tag = tag }
    recs[tag] = r
  end
  return r
end

function M:Forget(tag) recs[tag] = nil end

function M:MarkOffline(tag)
  local r = recs[tag]
  if r then r.gone = true; r.live = false; ns.Frames:Refresh() end
end

-- Members to show, in your list's order (sim member last).
function M:Visible()
  local out, now = {}, GetTime()
  local function consider(r)
    if r and r.heardAt and not r.gone and now - r.heardAt < M.HIDE_AFTER then
      r.live = now - r.heardAt < M.STALE_AFTER
      out[#out + 1] = r
    end
  end
  for _, tag in ipairs(ns.db.members) do consider(recs[tag]) end
  for _, r in pairs(recs) do
    if r.sim then consider(r) end
  end
  return out
end

local function OnState(r, m, now)
  r.hp, r.hpMax = m.hp or r.hp, m.hpMax or r.hpMax
  r.pw, r.pwMax, r.pwType = m.pw or r.pw, m.pwMax or r.pwMax, m.pwType or r.pwType
  r.flags = m.flags
  r.speed = m.speed
  r.facing = m.facing

  if m.x then
    local prev = r.pos
    local pos = { map = m.map, x = m.x, y = m.y, t = now, vx = 0, vy = 0 }
    local w, h = ns.Call(C_Map.GetMapWorldSize, m.map)
    local moving = m.speed == nil or m.speed > 0

    if moving then
      local vx, vy
      -- Velocity from the last two positions, when they're far enough apart in
      -- time to trust (messages can arrive bunched together).
      if prev and prev.map == pos.map then
        local dt = now - prev.t
        if dt >= 0.35 and dt <= 3 then vx, vy = (pos.x - prev.x) / dt, (pos.y - prev.y) / dt end
      end
      -- Otherwise from their facing and speed (facing 0 = north, counter-clockwise).
      if not vx and m.facing and m.speed and w and w > 0 then
        vx = -math.sin(m.facing) * m.speed / w
        vy = -math.cos(m.facing) * m.speed / h
      end
      if vx then
        -- Light low-pass so one odd sample doesn't fling the pin.
        if prev and prev.map == pos.map and (prev.vx ~= 0 or prev.vy ~= 0) then
          vx, vy = (vx + prev.vx) / 2, (vy + prev.vy) / 2
        end
        -- Never predict faster than a fast mount.
        if w and w > 0 then
          local yps = math.sqrt((vx * w) ^ 2 + (vy * h) ^ 2)
          if yps > MAX_SPEED then vx, vy = vx * MAX_SPEED / yps, vy * MAX_SPEED / yps end
        end
        pos.vx, pos.vy = vx, vy
      end
    end
    pos.w, pos.h = w, h
    r.pos = pos
  else
    r.pos = nil  -- in an instance (no coordinates)
  end
end

-- tag: BattleTag (or the sim's fake tag); msg: decoded protocol message.
function M:OnMessage(tag, msg, isSim)
  if not isSim and not ns.Roster:IsMember(tag) then
    if msg.type == "H" and not noticed[tag] then
      noticed[tag] = true
      ns.Print(("%s (%s) is sharing with you. Type /gp add %s to see them."):format(tag, msg.name or "?", tag))
    end
    return
  end

  local r = self:Get(tag)
  local now = GetTime()
  r.heardAt = now
  r.sim = isSim or nil

  if msg.type == "H" then
    r.gone = false
    r.name, r.level, r.class, r.zone = msg.name, msg.level, msg.class, msg.zone
    -- A character to whisper if they later Appear Offline.
    if not isSim and #ns.Roster:Chars(tag) == 0 then ns.Roster:RememberChar(tag, msg.name) end
    if msg.want and not isSim then ns.State:SendHello(false, tag) end
  elseif msg.type == "S" then
    r.gone = false
    OnState(r, msg, now)
  elseif msg.type == "B" then
    r.gone = true
  end

  -- Name before the first hello: fall back to what Battle.net tells us.
  if not r.name then
    local o = ns.Roster:Online(tag)
    r.name = o and o.name or tag:match("^[^#]+")
  end
  ns.Frames:Refresh()
end

-- Smoothed, predicted map position: map, x, y (or nil).
function M:Position(r, now)
  local p = r.pos
  if not p then return nil end
  -- Predict a little ahead (about one update interval), then hold, so the
  -- pin never runs far past where they really are and has to snap back.
  local dt = math.min(now - p.t, MAX_EXTRAPOLATE)
  local tx, ty = p.x + p.vx * dt, p.y + p.vy * dt

  -- One pin, eased toward the prediction: no jumps, no trail.
  local d = r.drawn
  local far = false
  if d and d.map == p.map and p.w and p.w > 0 then
    local ex, ey = (tx - d.x) * p.w, (ty - d.y) * p.h
    far = ex * ex + ey * ey > SNAP_YARDS * SNAP_YARDS -- teleport, flight, hearthstone
  end
  if not d or d.map ~= p.map or not d.at or far then
    d = { map = p.map, x = tx, y = ty, at = now }
    r.drawn = d
  elseif now > d.at then
    local k = 1 - math.exp(-(now - d.at) / EASE_SECONDS)
    d.x, d.y, d.at = d.x + (tx - d.x) * k, d.y + (ty - d.y) * k, now
  end
  return d.map, d.x, d.y
end
