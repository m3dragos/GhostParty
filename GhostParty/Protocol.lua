local _, ns = ...
ns = ns or {}

-- Wire format. Plain text, ':'-separated, "-" for unknown/secret values.
-- Pure Lua (no WoW API) so it can be unit-tested outside the game.
--
--   1:S:map:x:y:facing:speed:hp:hpMax:pw:pwMax:pwType:flags
--       x, y      map position * 10000 (0..10000)
--       facing    degrees 0..359
--       speed     yards/second * 10
--   1:H:want:level:class:name:zone      want = 1 asks the receiver to answer with its own H
--   1:B                                 logging out

local P = {}
ns.Protocol = P

P.VERSION = 1

P.FLAG_DEAD = 1
P.FLAG_GHOST = 2
P.FLAG_COMBAT = 4
P.FLAG_AFK = 8
P.FLAG_INSTANCE = 16

function P.HasFlag(flags, bit)
  return math.floor((flags or 0) / bit) % 2 == 1
end

local function enc(v)
  if v == nil then return "-" end
  return tostring(v)
end

local function int(v, lo, hi)
  if v == nil then return nil end
  v = math.floor(v + 0.5)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

-- s: { map, x, y (0..1), facing (radians), speed (yd/s), hp, hpMax, pw, pwMax, pwType, flags }
function P.EncodeState(s)
  local facing = s.facing and int(math.deg(s.facing) % 360, 0, 359)
  return table.concat({
    P.VERSION, "S",
    enc(s.map),
    enc(s.x and int(s.x * 10000, 0, 10000)),
    enc(s.y and int(s.y * 10000, 0, 10000)),
    enc(facing),
    enc(s.speed and int(s.speed * 10, 0, 9999)),
    enc(s.hp and int(s.hp, 0)),
    enc(s.hpMax and int(s.hpMax, 0)),
    enc(s.pw and int(s.pw, 0)),
    enc(s.pwMax and int(s.pwMax, 0)),
    enc(s.pwType and int(s.pwType, 0, 99)),
    enc(int(s.flags or 0, 0, 255)),
  }, ":")
end

local function clean(text, maxLen)
  return (tostring(text or ""):gsub("[:|\r\n]", "")):sub(1, maxLen)
end

function P.EncodeHello(h)
  return table.concat({
    P.VERSION, "H",
    h.want and 1 or 0,
    enc(h.level and int(h.level, 1, 999)),
    clean(h.class, 20),
    clean(h.name, 48),
    clean(h.zone, 64),
  }, ":")
end

function P.EncodeBye()
  return P.VERSION .. ":B"
end

-- Optional number field: "-" -> nil; garbage -> false (reject message).
local function num(s, lo, hi)
  if s == "-" then return nil end
  local v = tonumber(s)
  if not v or v ~= math.floor(v) then return false end
  if (lo and v < lo) or (hi and v > hi) then return false end
  return v
end

local function split(text, sep, limit)
  local out, start = {}, 1
  while true do
    if limit and #out == limit - 1 then
      out[#out + 1] = text:sub(start)
      return out
    end
    local i = text:find(sep, start, true)
    if not i then
      out[#out + 1] = text:sub(start)
      return out
    end
    out[#out + 1] = text:sub(start, i - 1)
    start = i + 1
  end
end

-- Returns a message table, or nil if malformed / other protocol version.
function P.Decode(text)
  if type(text) ~= "string" or #text > 400 then return nil end
  local f = split(text, ":", 7)
  if tonumber(f[1]) ~= P.VERSION then return nil end
  local kind = f[2]

  if kind == "B" then
    return { type = "B" }

  elseif kind == "H" then
    if #f ~= 7 then return nil end
    local level = num(f[4], 1, 999)
    if level == false then return nil end
    local class = f[5] ~= "" and f[5] or nil
    if class and not class:match("^%u+$") then return nil end
    if f[6] == "" then return nil end
    return { type = "H", want = f[3] == "1", level = level, class = class, name = f[6], zone = f[7] }

  elseif kind == "S" then
    f = split(text, ":")
    if #f ~= 13 then return nil end
    local m = { type = "S" }
    local spec = {
      { "map", 0, 999999 }, { "x", 0, 10000 }, { "y", 0, 10000 }, { "facing", 0, 359 },
      { "speed", 0, 9999 }, { "hp", 0, 1e9 }, { "hpMax", 0, 1e9 }, { "pw", 0, 1e9 },
      { "pwMax", 0, 1e9 }, { "pwType", 0, 99 }, { "flags", 0, 255 },
    }
    for i, s in ipairs(spec) do
      local v = num(f[i + 2], s[2], s[3])
      if v == false then return nil end
      m[s[1]] = v
    end
    if m.x then m.x = m.x / 10000 end
    if m.y then m.y = m.y / 10000 end
    if m.facing then m.facing = math.rad(m.facing) end
    if m.speed then m.speed = m.speed / 10 end
    m.flags = m.flags or 0
    -- A position needs all three parts.
    if not (m.map and m.x and m.y) then m.x, m.y = nil, nil end
    return m
  end
end

return P
