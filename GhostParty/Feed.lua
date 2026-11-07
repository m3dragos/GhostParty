local _, ns = ...

-- The party feed and party chat.
--
-- Sender side: we watch our OWN character for rare moments and broadcast them
-- as E messages (level up, death, entering an instance, rare kill, blue+ loot,
-- duel). Receiver side: friends' E and C messages become lines in a native
-- chat tab named after the addon (created once; the player may move, dock or
-- close it; closed means lines go to the main chat window), plus a banner
-- and sound for big level milestones.
--
-- Chat lines (CHAT_MSG_*) are secret during boss encounters on Midnight-era
-- clients: anything secret or unmatched is simply skipped.
local Feed = {}
ns.Feed = Feed

local P = ns.Protocol
local Call, Plain = ns.Call, ns.Plain

local MIN_LOOT_QUALITY = 3          -- 3 rare (blue), 4 epic, 5 legendary
local INSTANCE_REPEAT = 30 * 60     -- re-entering the same instance within this is not news
local RARE_REPEAT = 120
local DUEL_REPEAT = 10              -- both duelists may report the same duel

local function Secret(v) return issecretvalue and issecretvalue(v) end

---------------------------------------------------------------------------
-- Output: the addon's chat tab, or the main chat window
---------------------------------------------------------------------------
local function TabName() return ns.NAME end

local function FindTab()
  if not GetChatWindowInfo then return nil end
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local ok, name, _, _, _, _, _, shown, _, docked = pcall(GetChatWindowInfo, i)
    if ok and name == TabName() and (shown or docked) then return _G["ChatFrame" .. i] end
  end
end

function Feed:Frame()
  return FindTab()
end

-- News goes to the Angura tab (or the main window if it's closed). Party chat
-- (alsoMain) goes to the main chat window as well, like real party chat.
local function Say(text, r, g, b, alsoMain)
  local frame = FindTab()
  if frame then frame:AddMessage(text, r, g, b) end
  if (not frame or alsoMain) and frame ~= DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("[" .. ns.NAME .. "] " .. text, r, g, b)
  end
end

-- Opens the tab (once; /angura chat brings it back). Out of combat only.
function Feed:MakeTab(loud)
  if FindTab() then
    if loud then ns.Print("The " .. TabName() .. " chat tab is already open.") end
    return
  end
  if InCombatLockdown() or not FCF_OpenNewWindow then
    if loud then ns.Print("Can't open a chat tab right now (in combat?). Try again in a moment.") end
    return
  end
  local ok, frame = pcall(FCF_OpenNewWindow, TabName(), true)
  if ok and frame then
    -- Only our lines: no say/yell/system/channels in this tab.
    local rmGroups = ChatFrame_RemoveAllMessageGroups or (ChatFrameUtil and ChatFrameUtil.RemoveAllMessageGroups)
    local rmChannels = ChatFrame_RemoveAllChannels or (ChatFrameUtil and ChatFrameUtil.RemoveAllChannels)
    if rmGroups then pcall(rmGroups, frame) end
    if rmChannels then pcall(rmChannels, frame) end
    frame:AddMessage(ns.NAME .. ": your friends' news and party chat. Type /an <message> to talk.", 1, 0.82, 0)
  end
  ns.db.chatTab = true
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function Hex(r, g, b)
  return ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- A friend's name in class colour; clickable (whisper) for real friends.
local function Who(rec)
  local name = rec.name or rec.tag
  local colored = "|cff" .. Hex(ns.ClassColor(rec.class)) .. name .. "|r"
  local full = not rec.sim and ns.Roster:Chars(rec.tag)[1]
  if full then return "|Hplayer:" .. full .. "|h" .. colored .. "|h" end
  return colored
end

-- A character name from a system line: coloured if it's a friend or you.
local function NameOf(name)
  if not name then return "?" end
  local short = name:match("^([^%-]+)") or name
  if short == UnitName("player") then
    local _, class = UnitClass("player")
    return "|cff" .. Hex(ns.ClassColor(class)) .. short .. "|r"
  end
  for _, rec in ipairs(ns.Members:Visible()) do
    if rec.name == short then return Who(rec) end
  end
  return short
end

local function QualityHex(q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.r then return Hex(c.r, c.g, c.b) end
  return "ffffff"
end

-- Calls fn(link) once the item is known (the item cache may need a moment).
local function WithItem(id, fn)
  id = tonumber(id)
  if not id then return end
  if Item and Item.CreateFromItemID then
    local ok, item = pcall(Item.CreateFromItemID, Item, id)
    if ok and item and not item:IsItemEmpty() then
      item:ContinueOnItemLoad(function()
        local link = item:GetItemLink()
        if link then fn(link) end
      end)
      return
    end
  end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local _, link = Call(getInfo, id)
  fn(link or ("item " .. id))
end

-- Chat text from a friend: item links are rebuilt by us, every other escape
-- sequence is shown literally (so nobody can hide text, fake links or icons).
local function Sanitize(text)
  local links = {}
  local function keep(itemString, name)
    links[#links + 1] = { itemString, name }
    return "\001" .. #links .. "\001"
  end
  text = text:gsub("[%c]", " ")
  text = text:gsub("|c[^|]*|H(item:[%-%d:]+)|h%[([^%]|]+)%]|h|r", keep)
  text = text:gsub("|H(item:[%-%d:]+)|h%[([^%]|]+)%]|h", keep)
  text = text:gsub("|", "||")
  text = text:gsub("\001(%d+)\001", function(i)
    local l = links[tonumber(i)]
    if not l then return "" end
    local id = tonumber(l[1]:match("^item:(%d+)"))
    local q = id and C_Item and C_Item.GetItemQualityByID and Call(C_Item.GetItemQualityByID, id)
    return "|cff" .. QualityHex(q) .. "|H" .. l[1] .. "|h[" .. l[2] .. "]|h|r"
  end)
  return text
end

---------------------------------------------------------------------------
-- Milestone banner (levels 10, 20, ... 60)
---------------------------------------------------------------------------
local banner
local function Banner(text)
  if not banner then
    banner = CreateFrame("Frame", nil, UIParent)
    banner:SetSize(640, 64)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -170)
    banner:SetFrameStrata("HIGH")
    banner.band = banner:CreateTexture(nil, "BACKGROUND")
    banner.band:SetAllPoints()
    banner.band:SetColorTexture(0, 0, 0, 0.45)
    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    banner.title:SetPoint("CENTER", 0, 6)
    banner.title:SetTextColor(1, 0.82, 0)
    banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -4)
    banner.sub:SetText(ns.NAME)
    local ag = banner:CreateAnimationGroup()
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.4); fadeIn:SetOrder(1)
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0); fadeOut:SetDuration(1.2); fadeOut:SetStartDelay(4); fadeOut:SetOrder(2)
    ag:SetScript("OnFinished", function() banner:Hide() end)
    banner.anim = ag
  end
  banner.title:SetText(text)
  banner:Show()
  banner.anim:Stop()
  banner.anim:Play()
  local sound = SOUNDKIT and (SOUNDKIT.UI_GARRISON_COMMAND_TABLE_FOLLOWER_LEVEL_UP or SOUNDKIT.UI_ADVENTURES_ADVENTURER_LEVEL_UP)
  if sound then pcall(PlaySound, sound, "Master") end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local GOLD = { 1, 0.82, 0 }
local NEWS = { 1, 1, 1 }
local SAD = { 1, 0.45, 0.4 }
local ONLINE = { 0.6, 0.85, 1 }

local recentDuels = {}

function Feed:Presence(rec, online)
  if online then
    Say(Who(rec) .. " has come online.", unpack(ONLINE))
  else
    Say(Who(rec) .. " has gone offline.", 0.6, 0.6, 0.6)
  end
end

function Feed:OnEvent(rec, msg)
  local a = msg.args
  local kind = msg.kind
  if kind == "lvl" then
    local level = tonumber(a[1])
    if not level then return end
    rec.level = level
    Say(Who(rec) .. " reached level " .. level .. "!", unpack(GOLD))
    if level % 10 == 0 then Banner((rec.name or rec.tag) .. " reached level " .. level .. "!") end
  elseif kind == "dead" then
    local zone, sub = a[1], a[2]
    local where = (sub and sub ~= "" and zone and sub ~= zone) and (sub .. ", " .. zone) or zone or "?"
    Say(Who(rec) .. " died in " .. where .. ".", unpack(SAD))
  elseif kind == "inst" then
    if not a[1] then return end
    local what = ({ raid = "the raid", pvp = "the battleground", arena = "the arena" })[a[2] or ""]
    Say(Who(rec) .. " entered " .. (what and (what .. " " .. a[1]) or a[1]) .. ".", unpack(NEWS))
  elseif kind == "rare" then
    if not a[1] then return end
    Say(Who(rec) .. " killed " .. a[1] .. (a[2] == "rareelite" and " (rare elite)!" or " (rare)!"), unpack(GOLD))
  elseif kind == "loot" then
    local count = tonumber(a[2])
    WithItem(a[1], function(link)
      Say(Who(rec) .. " looted " .. link .. ((count and count > 1) and (" x" .. count) or "") .. ".", unpack(NEWS))
    end)
  elseif kind == "duel" then
    local w, l = a[1], a[2]
    if not (w and l) then return end
    local key, now = w .. ">" .. l, GetTime()
    if recentDuels[key] and now - recentDuels[key] < DUEL_REPEAT then return end
    recentDuels[key] = now
    Say(NameOf(w) .. " defeated " .. NameOf(l) .. " in a duel.", unpack(NEWS))
  end
end

function Feed:OnChat(rec, text)
  if type(text) ~= "string" or text == "" then return end
  local c = ChatTypeInfo and ChatTypeInfo.PARTY
  Say("[" .. Who(rec) .. "]: " .. Sanitize(text), c and c.r or 0.67, c and c.g or 0.67, c and c.b or 1, true)
end

---------------------------------------------------------------------------
-- Party chat: /an <message>
---------------------------------------------------------------------------
function Feed:SendChat(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return ns.Print("Usage: /an <message> - talk to your " .. ns.NAME .. " friends.") end
  if not ns.db.sharing then return ns.Print("Sharing is stopped, so friends can't hear you. /angura start to resume.") end
  if #ns.Roster:OnlineMembers() == 0 then return ns.Print("None of your friends are online to hear you.") end
  for _, piece in ipairs(P.SplitChat(text)) do
    ns.Comm:SendUrgent(P.EncodeChat(piece), nil, true)
  end
  local _, class = UnitClass("player")
  local c = ChatTypeInfo and ChatTypeInfo.PARTY
  Say("[|cff" .. Hex(ns.ClassColor(class)) .. UnitName("player") .. "|r]: " .. Sanitize(text),
    c and c.r or 0.67, c and c.g or 0.67, c and c.b or 1, true)
  if ns.Comm:InEncounter() then ns.Print("(Sent when the boss fight ends.)") end
  Feed.sticky = true
end

---------------------------------------------------------------------------
-- Sticky /an: after a line sent with /an, the chat box opens with "/an "
-- already typed (like /p keeps you in party chat), until you send anything
-- else. Only post-hooks and text on the box; nothing of Blizzard's is changed.
---------------------------------------------------------------------------
local STICKY = "/an "
local lastTyped = {}   -- edit box -> last non-empty text typed in it

local function IsAn(text)
  local t = text:lower()
  return t == "/an" or t:sub(1, 4) == "/an "
end

local function BoxText(box)
  local ok, text = pcall(box.GetText, box)
  if ok and type(text) == "string" and not Secret(text) then return text end
end

local function Opened(box)
  lastTyped[box] = false
  if not Feed.sticky then return end
  C_Timer.After(0, function()
    if not (Feed.sticky and box:IsShown() and box:HasFocus()) or BoxText(box) ~= "" then return end
    -- A whisper reply (R, or clicking a name) keeps its own target.
    local okType, chatType = pcall(box.GetAttribute, box, "chatType")
    if okType and (chatType == "WHISPER" or chatType == "BN_WHISPER") then return end
    pcall(box.SetText, box, STICKY)
    pcall(box.SetCursorPosition, box, #STICKY)
  end)
end

local function Closed(box)
  local t = lastTyped[box]
  if t and not IsAn(t) then Feed.sticky = false end
  lastTyped[box] = false
end

local function HookBox(box)
  if not box or lastTyped[box] ~= nil or not box.HookScript then return end
  lastTyped[box] = false
  box:HookScript("OnEditFocusGained", Opened)
  box:HookScript("OnEditFocusLost", Closed)
  box:HookScript("OnTextChanged", function(self)
    local text = BoxText(self)
    if text and text ~= "" then lastTyped[self] = text end
  end)
end

---------------------------------------------------------------------------
-- Sending: our own moments
---------------------------------------------------------------------------
local function Event(kind, ...) ns.State:SendEvent(kind, ...) end

-- A Lua pattern from a global format string, plus which argument each
-- capture is ("%2$s has fled from %1$s" captures argument 2 first).
local function Pattern(fmt, open)
  if type(fmt) ~= "string" or Secret(fmt) then return nil end
  local order = {}
  local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%(%d)%%%$s", function(d) order[#order + 1] = tonumber(d); return "(.-)" end)
  p = p:gsub("%%(%d)%%%$d", function(d) order[#order + 1] = tonumber(d); return "(%d+)" end)
  p = p:gsub("%%s", function() order[#order + 1] = #order + 1; return "(.-)" end)
  p = p:gsub("%%d", function() order[#order + 1] = #order + 1; return "(%d+)" end)
  return "^" .. p .. (open and "" or "$"), order
end

-- Captures of text against a pattern, put back in argument order.
local function Args(text, pat, order)
  if not pat then return nil end
  local caps = { text:match(pat) }
  if #caps == 0 then return nil end
  local out = {}
  for i, v in ipairs(caps) do out[order[i] or i] = v end
  return out
end

local pats
local function Patterns()
  if pats then return pats end
  pats = {}
  pats.kill, pats.killOrder = Pattern(COMBATLOG_XPGAIN_FIRSTPERSON, true)
  pats.lootN, pats.lootNOrder = Pattern(LOOT_ITEM_SELF_MULTIPLE)
  pats.loot, pats.lootOrder = Pattern(LOOT_ITEM_SELF)
  pats.duelK, pats.duelKOrder = Pattern(DUEL_WINNER_KNOCKOUT)
  pats.duelR, pats.duelROrder = Pattern(DUEL_WINNER_RETREAT)
  return pats
end

local function Short(name) return name and (name:match("^([^%-]+)") or name) end

ns:On("PLAYER_LEVEL_UP", function(level)
  level = Plain(level) or Call(UnitLevel, "player")
  if level then Event("lvl", level) end
end)

ns:On("PLAYER_DEAD", function()
  Event("dead", Call(GetRealZoneText) or "", Call(GetSubZoneText) or "")
end)

-- Entering a dungeon, raid or battleground. Dying and running back, or a
-- /reload inside, is the same visit (INSTANCE_REPEAT after you last left).
-- Logging in or reloading inside one is never news.
ns:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  local quiet = Plain(isLogin) or Plain(isReload)
  C_Timer.After(2, function()
    local db = ns.db
    if Call(IsInInstance) then
      local name, kind = Call(GetInstanceInfo)
      if not name or not kind or kind == "none" then return end
      local seen = db.lastInstance
      if not quiet and not (seen and seen.name == name and time() - (seen.at or 0) < INSTANCE_REPEAT) then
        Event("inst", name, kind)
      end
      db.lastInstance = { name = name, at = time() }
    elseif db.lastInstance then
      db.lastInstance.at = time() -- left it now: the repeat window starts here
    end
  end)
end)

-- Rares: the kill line has no classification and the target is often gone by
-- then, so remember rares by name when you target or mouse over them.
local rares, rareSaid = {}, {}
local function NoteRare(unit)
  if not Call(UnitExists, unit) or Call(UnitIsPlayer, unit) then return end
  local cls = Call(UnitClassification, unit)
  if cls == "rare" or cls == "rareelite" then
    local name = Call(UnitName, unit)
    if name then rares[name] = cls end
  end
end
ns:On("PLAYER_TARGET_CHANGED", function() NoteRare("target") end)
ns:On("UPDATE_MOUSEOVER_UNIT", function() NoteRare("mouseover") end)

ns:On("CHAT_MSG_COMBAT_XP_GAIN", function(text)
  if type(text) ~= "string" or Secret(text) then return end
  local p = Patterns()
  local args = Args(text, p.kill, p.killOrder)
  local name = args and args[1]
  local cls = name and rares[name]
  if not cls then return end
  local now = GetTime()
  if rareSaid[name] and now - rareSaid[name] < RARE_REPEAT then return end
  rareSaid[name] = now
  Event("rare", name, cls)
end)

ns:On("CHAT_MSG_LOOT", function(text)
  if type(text) ~= "string" or Secret(text) then return end
  local p = Patterns()
  local args = Args(text, p.lootN, p.lootNOrder) or Args(text, p.loot, p.lootOrder)
  local link = args and args[1]
  local id = link and tonumber(link:match("item:(%d+)"))
  if not id then return end
  local q = tonumber(link:match("|cnIQ(%d)")) or (C_Item and C_Item.GetItemQualityByID and Call(C_Item.GetItemQualityByID, id))
  if q and q >= MIN_LOOT_QUALITY then Event("loot", id, tonumber(args[2]) or 1) end
end)

ns:On("CHAT_MSG_SYSTEM", function(text)
  if type(text) ~= "string" or Secret(text) then return end
  local p = Patterns()
  local args = Args(text, p.duelK, p.duelKOrder) or Args(text, p.duelR, p.duelROrder)
  if not (args and args[1] and args[2]) then return end
  local me = UnitName("player")
  local w, l = Short(args[1]), Short(args[2])
  if w == me or l == me then Event("duel", w, l) end
end)

ns:On("PLAYER_LOGIN", function()
  if not ns.db.chatTab then C_Timer.After(3, function() Feed:MakeTab() end) end
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local cf = _G["ChatFrame" .. i]
    HookBox(_G["ChatFrame" .. i .. "EditBox"] or (cf and cf.editBox))
  end
end)
