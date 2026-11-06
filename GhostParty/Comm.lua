local _, ns = ...

-- Addon messaging with a client-side throttle.
--
-- Friends are reached over Battle.net (C_BattleNet.SendGameData), or by addon
-- whisper to their character when they "Appear Offline" (see Roster:Route).
-- The server allows a small burst per prefix, then about one message per
-- second. We spread sends over several prefixes (each with its own token
-- bucket) and keep only the LATEST state update per friend, so when the
-- budget is tight friends simply get fewer, always-fresh updates.
local C = {}
ns.Comm = C

local PREFIXES = { "GhostPty1", "GhostPty2", "GhostPty3", "GhostPty4" }
local PREFIX_SET = {}
for _, p in ipairs(PREFIXES) do PREFIX_SET[p] = true end

local BUCKET_MAX = 8      -- stay under the server's burst of 10
local REFILL_PER_SEC = 1  -- per prefix
local PUMP_INTERVAL = 0.05
local PROBE_EVERY = 20    -- seconds between whisper probes to unreachable members
local PROBE_CHARS = 3     -- most recent characters probed per member

local buckets = {}
local urgent = {}         -- FIFO of { kind, target, msg }: hellos, byes, probes
local latest = {}         -- tag -> { kind, target, msg }: newest state update
local lastStateSent = {}  -- tag -> GetTime()
local order = {}          -- round-robin over tags
local rr = 0
local probed = {}         -- lowercased character name -> GetTime() of the probe

C.stats = { sent = 0, received = 0, failed = 0, dropped = 0, whisper = 0 }

local THROTTLED = {}
if Enum and Enum.SendAddonMessageResult then
  THROTTLED[Enum.SendAddonMessageResult.AddonMessageThrottle or -1] = true
  THROTTLED[Enum.SendAddonMessageResult.ChannelThrottle or -1] = true
end

local function Refill(now)
  for _, p in ipairs(PREFIXES) do
    local b = buckets[p]
    b.tokens = math.min(BUCKET_MAX, b.tokens + (now - b.t) * REFILL_PER_SEC)
    b.t = now
  end
end

local function TakePrefix()
  local best
  for _, p in ipairs(PREFIXES) do
    if buckets[p].tokens >= 1 and (not best or buckets[p].tokens > buckets[best].tokens) then best = p end
  end
  if best then buckets[best].tokens = buckets[best].tokens - 1 end
  return best
end

local function RawSend(prefix, kind, target, msg)
  local ok, res
  if kind == "WHISPER" then
    ok, res = pcall(C_ChatInfo.SendAddonMessage, prefix, msg, "WHISPER", target)
    if ok and THROTTLED[res] then ok, res = false, "throttled" end
  else
    local send = (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
    if not send then return false end
    ok, res = pcall(send, target, prefix, msg)
  end
  if not ok then
    C.stats.failed = C.stats.failed + 1
    ns.Debug("send failed:", res)
    return false
  end
  C.stats.sent = C.stats.sent + 1
  if kind == "WHISPER" then C.stats.whisper = C.stats.whisper + 1 end
  return true
end

local function Pump()
  local now = GetTime()
  Refill(now)

  while #urgent > 0 do
    local prefix = TakePrefix()
    if not prefix then return end
    local item = table.remove(urgent, 1)
    RawSend(prefix, item.kind, item.target, item.msg)
  end

  local n = #order
  local minInterval = ns.db and ns.db.minInterval or 0.5
  for _ = 1, n do
    rr = rr % n + 1
    local tag = order[rr]
    local item = latest[tag]
    if item and now - (lastStateSent[tag] or 0) >= minInterval then
      local prefix = TakePrefix()
      if not prefix then return end
      latest[tag] = nil
      lastStateSent[tag] = now
      RawSend(prefix, item.kind, item.target, item.msg)
    end
  end
end

local function Targets(tag)
  if tag then
    local kind, target = ns.Roster:Route(tag)
    return kind and { { tag = tag, kind = kind, target = target } } or {}
  end
  return ns.Roster:OnlineMembers()
end

function C:HasTargets()
  return #ns.Roster:OnlineMembers() > 0
end

-- Hello/bye: queued in order, sent before any state update.
function C:SendUrgent(msg, tag)
  for _, t in ipairs(Targets(tag)) do
    urgent[#urgent + 1] = { kind = t.kind, target = t.target, msg = msg }
  end
end

-- State: replaces any not-yet-sent state for each reachable member.
function C:SendState(msg)
  wipe(order)
  for _, t in ipairs(Targets()) do
    latest[t.tag] = { kind = t.kind, target = t.target, msg = msg }
    order[#order + 1] = t.tag
  end
  if rr > #order then rr = 0 end
end

-- Drop any state updates not yet sent (after /gp stop).
function C:ClearState()
  wipe(latest)
end

-- On logout there is no next frame: send immediately, ignoring the throttle.
function C:SendNow(msg)
  for i, t in ipairs(Targets()) do
    RawSend(PREFIXES[(i - 1) % #PREFIXES + 1], t.kind, t.target, msg)
  end
end

-- Whisper a hello to a member's recent characters. If one is online (even
-- while Appearing Offline on Battle.net) it answers, and that sets up a
-- whisper route. Offline characters make the server say "No player named...",
-- which the chat filter below hides.
function C:Probe(tag)
  if not (ns.db.sharing and C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  local chars = ns.Roster:Chars(tag)
  local msg = ns.State:HelloText(true)
  for i = 1, math.min(PROBE_CHARS, #chars) do
    probed[chars[i]:lower()] = GetTime()
    probed[(chars[i]:match("^([^%-]+)") or chars[i]):lower()] = GetTime()
    urgent[#urgent + 1] = { kind = "WHISPER", target = chars[i], msg = msg }
  end
  if #chars > 0 then ns.Debug("probing", tag, "by whisper") end
end

function C:PrintStatus()
  Refill(GetTime())
  local tokens = {}
  for _, p in ipairs(PREFIXES) do tokens[#tokens + 1] = ("%.1f"):format(buckets[p].tokens) end
  ns.Print(("Battle.net friends in Forever: %d, ghost party reachable: %d"):format(
    ns.Roster:CountOnline(), #ns.Roster:OnlineMembers()))
  ns.Print(("Messages sent %d (%d by whisper), received %d, failed %d, ignored %d"):format(
    self.stats.sent, self.stats.whisper, self.stats.received, self.stats.failed, self.stats.dropped))
  ns.Print("Throttle tokens per prefix: " .. table.concat(tokens, " / "))
end

local function Drop(why)
  C.stats.dropped = C.stats.dropped + 1
  ns.Debug("ignored message:", why)
end

local function Deliver(tag, text)
  local msg = ns.Protocol.Decode(text)
  if not msg then return Drop("malformed or other version, from " .. tag) end
  ns.Members:OnMessage(tag, msg)
end

ns:On("BN_CHAT_MSG_ADDON", function(prefix, text, _, senderID)
  if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(senderID)) then return end
  if not PREFIX_SET[prefix] then return end
  C.stats.received = C.stats.received + 1
  local tag = ns.Roster:TagForGameAccount(senderID)
  if not tag then return Drop("from an unknown Battle.net account") end
  ns.Roster:HeardViaBattleNet(tag, senderID)
  Deliver(tag, text)
end)

-- Only the first four arguments: the fifth is the target, not a flag.
ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
  if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then return end
  if not PREFIX_SET[prefix] or channel ~= "WHISPER" or not sender then return end
  if sender == UnitName("player") or (sender:match("^([^%-]+)")) == UnitName("player") then return end
  C.stats.received = C.stats.received + 1
  local tag = ns.Roster:TagForCharacter(sender)
  if not tag then return Drop("whisper from " .. sender .. ", not a known character of your ghost party") end
  ns.Roster:HeardViaWhisper(tag, sender)
  Deliver(tag, text)
end)

-- Hide "No player named 'X' is currently playing." for characters we just probed.
local notFound
if ERR_CHAT_PLAYER_NOT_FOUND_S then
  notFound = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%s", "(.-)") .. "$"
end

local function SystemFilter(_, _, text, ...)
  if not notFound or type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return false end
  local name = text:match(notFound)
  local at = name and probed[name:lower()]
  if at and GetTime() - at < 10 then return true end
  return false
end

ns:On("PLAYER_LOGIN", function()
  local now = GetTime()
  for _, p in ipairs(PREFIXES) do
    buckets[p] = { tokens = BUCKET_MAX, t = now }
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix(p)
    end
  end
  local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
  if addFilter then pcall(addFilter, "CHAT_MSG_SYSTEM", SystemFilter) end
  C_Timer.NewTicker(PUMP_INTERVAL, Pump)
  C_Timer.NewTicker(PROBE_EVERY, function()
    for _, tag in ipairs(ns.Roster:Unreachable()) do C:Probe(tag) end
  end)
end)
