local _, ns = ...

-- Addon messaging with a client-side throttle.
--
-- Friends are reached over Battle.net (C_BattleNet.SendGameData), or by addon
-- whisper to their character when they "Appear Offline" (see Roster:Route).
-- The server allows a small burst per prefix, then about one message per
-- second. We spread sends over several prefixes (each with its own token
-- bucket) and keep only the LATEST state update per friend, so when the
-- budget is tight friends simply get fewer, always-fresh updates.
--
-- Priority: urgent (hellos, byes, feed events, party chat) first, then info
-- updates, then state updates, then whisper probes (probes only use spare
-- tokens, so they never slow down live friends).
--
-- Feed events and chat are "held" during a boss encounter (Midnight can refuse
-- addon sends then) and sent when it ends; an urgent send refused for lockdown
-- is retried rather than dropped.
--
-- Chat messaging lockdown is NOT a reason to stop: on Forever it shows up in
-- the open world too, and pausing on it (0.3.1) made friends go "No signal"
-- while 0.3.0 clients, which never paused, kept getting through. We always
-- try, and the per-send result decides (a refused message is simply dropped;
-- state is latest-only, so the next update replaces it).
local C = {}
ns.Comm = C

local PREFIXES = { "GhostPty1", "GhostPty2", "GhostPty3", "GhostPty4" }
local PREFIX_SET = {}
for _, p in ipairs(PREFIXES) do PREFIX_SET[p] = true end

local BUCKET_MAX = 8      -- stay under the server's burst of 10
local REFILL_PER_SEC = 1  -- per prefix
local PUMP_INTERVAL = 0.05
local PROBE_CHARS = 3     -- most recent characters probed per member
local PROBE_TICK = 10     -- how often we look for members due a probe
local PROBE_FIRST = 20    -- seconds until the first retry, doubling each time...
local PROBE_MAX = 300     -- ...up to one probe round every 5 minutes
local PROBE_RESERVE = 4   -- probes only use a prefix with at least this many tokens

local buckets = {}
local URGENT_MAX_AGE = 300 -- seconds a refused urgent message keeps being retried

local urgent = {}         -- FIFO of { kind, target, msg, hold, at }: hellos, byes, events, chat
local latest = {}         -- tag -> { kind, target, msg }: newest state update
local latestInfo = {}     -- tag -> { kind, target, msg }: newest info update
local inEncounter = false -- between ENCOUNTER_START and ENCOUNTER_END
local lastStateSent = {}  -- tag -> GetTime()
local order = {}          -- round-robin over tags
local rr = 0
local probes = {}         -- FIFO of { tag, target, msg }: whisper probes
local backoff = {}        -- tag -> { at = GetTime() next probe is due, delay = seconds }
local probed = {}         -- lowercased character name -> GetTime() of the probe

C.stats = { sent = 0, received = 0, failed = 0, throttled = 0, dropped = 0, whisper = 0, probes = 0,
  unreadable = 0 } -- addon messages (any addon's) that arrived as secret values
C.lockdownSeenAt = 0  -- last GetTime() our own chat lockdown was not "off"

local RESULT = Enum and Enum.SendAddonMessageResult
local SUCCESS = (RESULT and RESULT.Success) or 0
local THROTTLED = {}
local LOCKDOWN = {}
if RESULT then
  THROTTLED[RESULT.AddonMessageThrottle or -1] = true
  THROTTLED[RESULT.ChannelThrottle or -1] = true
  LOCKDOWN[RESULT.AddOnMessageLockdown or -1] = true
  LOCKDOWN[RESULT.AddonMessageLockdown or -1] = true
end

local function Refill(now)
  for _, p in ipairs(PREFIXES) do
    local b = buckets[p]
    b.tokens = math.min(BUCKET_MAX, b.tokens + (now - b.t) * REFILL_PER_SEC)
    b.t = now
  end
end

-- The fullest prefix with at least `need` tokens (default 1); takes one token.
local function TakePrefix(need)
  need = need or 1
  local best
  for _, p in ipairs(PREFIXES) do
    if buckets[p].tokens >= need and (not best or buckets[p].tokens > buckets[best].tokens) then best = p end
  end
  if best then buckets[best].tokens = buckets[best].tokens - 1 end
  return best
end

-- Lockdown state, for /gp status and debug only: "on", "off", "secret" or "missing".
local function Lockdown()
  local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
  if not f then return "missing" end
  local ok, v = pcall(f)
  if not ok then return "missing" end
  if issecretvalue and issecretvalue(v) then return "secret" end
  return v and "on" or "off"
end

-- "ok", "throttled" (keep the message, try later), "lockdown" (refused for
-- chat lockdown: urgent messages retry) or "failed" (give up on it).
local function RawSend(prefix, kind, target, msg)
  local ok, res
  if kind == "WHISPER" then
    ok, res = pcall(C_ChatInfo.SendAddonMessage, prefix, msg, "WHISPER", target)
    res = ns.Plain(res)
  else
    local send = (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
    if not send then return "failed" end
    ok, res = pcall(send, target, prefix, msg)
    res = nil -- no documented result for Battle.net game data
  end
  if ok and THROTTLED[res] then
    buckets[prefix].tokens = 0 -- the server says this prefix is empty
    C.stats.throttled = C.stats.throttled + 1
    ns.Debug("throttled on", prefix)
    return "throttled"
  end
  if ok and LOCKDOWN[res] then
    C.stats.failed = C.stats.failed + 1
    ns.Debug("send refused (lockdown) to", tostring(target))
    return "lockdown"
  end
  if not ok or (res ~= nil and res ~= true and res ~= SUCCESS) then
    C.stats.failed = C.stats.failed + 1
    ns.Debug("send failed:", tostring(res), "to", tostring(target))
    return "failed"
  end
  C.stats.sent = C.stats.sent + 1
  if kind == "WHISPER" then C.stats.whisper = C.stats.whisper + 1 end
  return "ok"
end

local lastLockdown = "off"

local function Pump()
  local now = GetTime()
  Refill(now)

  local lockdown = Lockdown()
  if lockdown ~= "off" and lockdown ~= "missing" then C.lockdownSeenAt = now end
  if lockdown ~= lastLockdown then
    lastLockdown = lockdown
    ns.Debug("chat messaging lockdown:", lockdown, "(still sending)")
  end

  local i = 1
  while urgent[i] do
    local item = urgent[i]
    if item.hold and inEncounter then
      i = i + 1 -- waits for the encounter to end; later messages may go first
    else
      local prefix = TakePrefix()
      if not prefix then return end
      local res = RawSend(prefix, item.kind, item.target, item.msg)
      if res == "throttled" then return end
      if res == "lockdown" and now - item.at < URGENT_MAX_AGE then return end
      table.remove(urgent, i)
    end
  end

  -- Info before state: it's rare (one per few seconds at most) and would
  -- starve behind state when the budget is tight.
  for tag, item in pairs(latestInfo) do
    local prefix = TakePrefix()
    if not prefix then return end
    if RawSend(prefix, item.kind, item.target, item.msg) == "throttled" then return end
    latestInfo[tag] = nil
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
      if RawSend(prefix, item.kind, item.target, item.msg) == "throttled" then return end
      latest[tag] = nil
      lastStateSent[tag] = now
    end
  end

  while #probes > 0 do
    local item = probes[1]
    if ns.Roster:Route(item.tag) then
      table.remove(probes, 1) -- reached them meanwhile
    else
      local prefix = TakePrefix(PROBE_RESERVE)
      if not prefix then return end
      local at = GetTime()
      probed[item.target:lower()] = at
      probed[(item.target:match("^([^%-]+)") or item.target):lower()] = at
      if RawSend(prefix, "WHISPER", item.target, item.msg) == "throttled" then return end
      C.stats.probes = C.stats.probes + 1
      table.remove(probes, 1)
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

-- Hello/bye/event/chat: queued in order, sent before any state update. An
-- identical hello or bye already waiting isn't queued twice (events and chat
-- may repeat on purpose). hold: wait while a boss encounter is in progress.
function C:SendUrgent(msg, tag, hold)
  local now = GetTime()
  for _, t in ipairs(Targets(tag)) do
    local dup = false
    if not hold then
      for _, u in ipairs(urgent) do
        if u.kind == t.kind and u.target == t.target and u.msg == msg then dup = true; break end
      end
    end
    if not dup then urgent[#urgent + 1] = { kind = t.kind, target = t.target, msg = msg, hold = hold, at = now } end
  end
end

-- Info: like state, latest only, but no minimum interval (it changes rarely).
function C:SendInfo(msg, tag)
  for _, t in ipairs(Targets(tag)) do
    latestInfo[t.tag] = { kind = t.kind, target = t.target, msg = msg }
  end
end

function C:InEncounter() return inEncounter end

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
  wipe(latestInfo)
  wipe(probes)
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
--
-- Each probe pushes the next one further out (20 s, 40 s, ... 5 min), so a
-- friend who is simply offline costs a few whispers per 5 minutes, not 9 a
-- minute. Hearing from them, or seeing them leave Battle.net, starts over.
function C:Probe(tag)
  if not (ns.db.sharing and C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  local chars = ns.Roster:Chars(tag)
  if #chars == 0 then return end
  local b = backoff[tag] or { delay = PROBE_FIRST }
  b.at = GetTime() + b.delay
  b.delay = math.min(PROBE_MAX, b.delay * 2)
  backoff[tag] = b
  for i = #probes, 1, -1 do
    if probes[i].tag == tag then table.remove(probes, i) end
  end
  local msg = ns.State:HelloText(true)
  for i = 1, math.min(PROBE_CHARS, #chars) do
    probes[#probes + 1] = { tag = tag, target = chars[i], msg = msg }
  end
  ns.Debug("probing", tag, "by whisper; next try in", b.at - GetTime(), "s")
end

function C:ResetProbe(tag) backoff[tag] = nil end

function C:PrintStatus()
  Refill(GetTime())
  local tokens = {}
  for _, p in ipairs(PREFIXES) do tokens[#tokens + 1] = ("%.1f"):format(buckets[p].tokens) end
  local s = self.stats
  ns.Print(("Battle.net friends in Forever: %d, Angura friends reachable: %d"):format(
    ns.Roster:CountOnline(), #ns.Roster:OnlineMembers()))
  ns.Print(("Messages sent %d (%d by whisper, %d probes), received %d, failed %d, throttled %d, ignored %d"):format(
    s.sent, s.whisper, s.probes, s.received, s.failed, s.throttled, s.dropped))
  ns.Print("Throttle tokens per prefix: " .. table.concat(tokens, " / "))
  ns.Print(("Queued: %d urgent, %d probes. Chat messaging lockdown: %s%s"):format(#urgent, #probes, Lockdown(),
    inEncounter and ", in a boss encounter (feed and chat held)" or ""))
  ns.Print(("Unreadable (secret) addon messages received: %d%s. No-signal gaps logged: %d"):format(
    s.unreadable, C.lastUnreadableAt and (", last %ds ago"):format(GetTime() - C.lastUnreadableAt) or "",
    ns.Members.gaps or 0))
end

local function Drop(why)
  C.stats.dropped = C.stats.dropped + 1
  ns.Debug("ignored message:", why)
end

local function Deliver(tag, text, via)
  C:ResetProbe(tag)
  local msg = ns.Protocol.Decode(text)
  if not msg then return Drop("malformed or other version, from " .. tag) end
  ns.Members:OnMessage(tag, msg, nil, via)
end

-- Secret payloads can't be read or even matched to a prefix: count them, so
-- "No signal" gaps can be checked against them (/gp status, signal log).
local function Unreadable(event)
  C.stats.unreadable = C.stats.unreadable + 1
  C.lastUnreadableAt = GetTime()
  if C.stats.unreadable == 1 or C.stats.unreadable % 50 == 0 then
    ns.Debug(event, "arrived as secret values (unreadable):", C.stats.unreadable, "so far")
  end
end

ns:On("BN_CHAT_MSG_ADDON", function(prefix, text, _, senderID)
  if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(senderID)) then
    return Unreadable("BN_CHAT_MSG_ADDON")
  end
  if not PREFIX_SET[prefix] then return end
  C.stats.received = C.stats.received + 1
  local tag = ns.Roster:TagForGameAccount(senderID)
  if not tag then return Drop("from an unknown Battle.net account") end
  ns.Roster:HeardViaBattleNet(tag, senderID)
  Deliver(tag, text, "BN")
end)

-- Only the first four arguments: the fifth is the target, not a flag.
ns:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
  if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(channel) or issecretvalue(sender)) then
    return Unreadable("CHAT_MSG_ADDON")
  end
  if not PREFIX_SET[prefix] or channel ~= "WHISPER" or not sender then return end
  if sender == UnitName("player") or (sender:match("^([^%-]+)")) == UnitName("player") then return end
  C.stats.received = C.stats.received + 1
  local tag = ns.Roster:TagForCharacter(sender)
  if not tag then return Drop("whisper from " .. sender .. ", not a known character of your Angura friends") end
  ns.Roster:HeardViaWhisper(tag, sender)
  Deliver(tag, text, "whisper")
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

ns:On("ENCOUNTER_START", function() inEncounter = true end)
ns:On("ENCOUNTER_END", function() inEncounter = false end)
-- Leaving the instance (or a wipe and release) ends it too, in case END never came.
ns:On("PLAYER_ENTERING_WORLD", function() inEncounter = false end)

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
  C_Timer.NewTicker(PROBE_TICK, function()
    local t = GetTime()
    for _, tag in ipairs(ns.Roster:Unreachable()) do
      local b = backoff[tag]
      if not b or t >= b.at then C:Probe(tag) end
    end
  end)
end)
