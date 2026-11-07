local _, ns = ...
ns = ns or {}

-- Wire format. Plain text, ':'-separated, "-" for unknown/secret values.
-- Pure Lua (no WoW API) so it can be unit-tested outside the game.
--
--   1:S:map:x:y:facing:speed:hp:hpMax:pw:pwMax:pwType:flags
--       x, y      map position * 10000 (0..10000)
--       facing    degrees 0..359
--       speed     yards/second * 10
--       hp..pwType are always "-" since 0.4.0 (secret on Forever)
--   1:H:want:level:class:name:zone      want = 1 asks the receiver to answer with its own H
--   1:B[:reason]                        leaving: reason 1 (or none) logout, 2 stopped sharing
--   1:I:status:group:instType:subzone:race:guild:home
--       status    ST_* bits (flying, taxi, resting, ...), group = real group size (0 = solo)
--   1:E:kind[:arg...]                   feed event: lvl, dead, inst, rare, loot, duel
--   1:C:text                            party chat line (text may contain ':')
--
-- 0.3.x clients drop I, E and C as malformed ("ignored") and accept "1:B:2" as a bye.

local P = {}
ns.Protocol = P

P.VERSION = 1

P.FLAG_DEAD = 1
P.FLAG_GHOST = 2
P.FLAG_COMBAT = 4
P.FLAG_AFK = 8
P.FLAG_INSTANCE = 16

-- Info status bits (I message, not S flags: old clients reject S flags > 255).
P.ST_MOUNTED = 1    -- not sent since 0.4.0 (owner: unnecessary); bit reserved
P.ST_FLYING = 2
P.ST_SWIMMING = 4   -- not sent either; bit reserved
P.ST_TAXI = 8
P.ST_RESTING = 16
P.ST_DND = 32
P.ST_PVP = 64

P.BYE_LOGOUT = 1
P.BYE_STOPPED = 2
P.CHAT_MAX = 230   -- bytes of chat text per message (addon messages max out at 255)

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

function P.EncodeBye(reason)
  if reason and reason ~= P.BYE_LOGOUT then return P.VERSION .. ":B:" .. reason end
  return P.VERSION .. ":B"
end

-- i: { status, group, instType, subzone, race, guild, home }
function P.EncodeInfo(i)
  return table.concat({
    P.VERSION, "I",
    enc(int(i.status or 0, 0, 65535)),
    enc(i.group and int(i.group, 0, 99)),
    clean(i.instType, 12),
    clean(i.subzone, 64),
    clean(i.race, 24),
    clean(i.guild, 48),
    clean(i.home, 64),
  }, ":")
end

-- Arguments are text or numbers; ':' and '|' are stripped from each.
function P.EncodeEvent(kind, ...)
  local out = { P.VERSION, "E", clean(kind, 8) }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    out[#out + 1] = v == nil and "-" or clean(v, 64)
  end
  return table.concat(out, ":")
end

-- Chat text goes as is (the receiver sanitizes it); only trimmed to CHAT_MAX.
function P.EncodeChat(text)
  return P.VERSION .. ":C:" .. (tostring(text or ""):gsub("%c", " ")):sub(1, P.CHAT_MAX)
end

-- Splits long chat text into CHAT_MAX pieces, at spaces where possible.
function P.SplitChat(text)
  local out = {}
  text = tostring(text or "")
  while #text > P.CHAT_MAX do
    local cut = P.CHAT_MAX
    local space = text:sub(1, P.CHAT_MAX):match(".*() ")
    if space and space > P.CHAT_MAX / 2 then cut = space - 1 end
    out[#out + 1] = text:sub(1, cut)
    text = text:sub(cut + 1):gsub("^ +", "")
  end
  if text ~= "" then out[#out + 1] = text end
  return out
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
    return { type = "B", reason = tonumber(f[3]) or P.BYE_LOGOUT }

  elseif kind == "C" then
    local body = text:match("^%d+:C:(.*)$")
    if not body or body == "" then return nil end
    return { type = "C", text = body }

  elseif kind == "E" then
    f = split(text, ":")
    if not f[3] or f[3] == "" then return nil end
    local args = {}
    for i = 4, #f do
      if f[i] ~= "-" then args[i - 3] = f[i] end
    end
    return { type = "E", kind = f[3], args = args, n = #f - 3 }

  elseif kind == "I" then
    f = split(text, ":")
    if #f < 9 then return nil end
    local status, group = num(f[3], 0, 65535), num(f[4], 0, 99)
    if status == false or group == false then return nil end
    local function txt(v) return v ~= "" and v or nil end
    return { type = "I", status = status or 0, group = group, instType = txt(f[5]), subzone = txt(f[6]),
      race = txt(f[7]), guild = txt(f[8]), home = txt(f[9]) }

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
