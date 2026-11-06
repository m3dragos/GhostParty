local ADDON, ns = ...

-- GhostParty: party frames and live map pins for Battle.net friends who are
-- NOT in your group. Every member runs the addon and broadcasts their own
-- state over Battle.net addon messages; nothing is read from other players.

ns.VERSION = "0.2.0"
ns.PROTOCOL = 1
ns.MAX_SLOTS = 4

local DEFAULTS = {
  members = {},        -- ordered list of BattleTags you share with
  chars = {},          -- BattleTag -> characters seen, newest first (for Appear Offline)
  point = nil,         -- saved frame position { point, relPoint, x, y }
  scale = 1.2,
  locked = false,
  showFrames = true,
  showPins = true,
  sharing = true,      -- false after /gp stop
  hideButton = false,
  buttonAngle = 215,   -- minimap button position, degrees (0 = east)
  minInterval = 0.5,   -- seconds between state updates to one friend
  debug = false,
}

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    -- Unknown events error on registration; never let that break loading.
    pcall(eventFrame.RegisterEvent, eventFrame, event)
  end
  table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do fn(...) end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function ns.Print(...)
  local msg = strjoin(" ", tostringall(...))
  DEFAULT_CHAT_FRAME:AddMessage("|cff9fd8ffGhostParty|r: " .. msg)
end

function ns.Debug(...)
  if ns.db and ns.db.debug then ns.Print("|cff888888[debug]|r", ...) end
end

-- nil for anything missing or secret, so callers never branch on a secret.
function ns.Plain(v)
  if v == nil then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

-- Calls fn safely and returns up to four plain (non-secret) results.
function ns.Call(fn, ...)
  if not fn then return nil end
  local ok, a, b, c, d = pcall(fn, ...)
  if not ok then return nil end
  local P = ns.Plain
  return P(a), P(b), P(c), P(d)
end

function ns.ClassColor(class)
  local c = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
  if c then return c.r, c.g, c.b end
  return 0.6, 0.6, 0.6
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------
ns:On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  GhostPartyDB = GhostPartyDB or {}
  for k, v in pairs(DEFAULTS) do
    if GhostPartyDB[k] == nil then
      GhostPartyDB[k] = type(v) == "table" and CopyTable(v) or v
    end
  end
  ns.db = GhostPartyDB
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
  "/gp friends - list Battle.net friends online in Forever (numbered)",
  "/gp add <number | BattleTag | character> - share with a friend",
  "/gp remove <BattleTag | character> - stop sharing",
  "/gp list - who you share with, and who is live",
  "/gp lock | unlock - lock or move the frames",
  "/gp scale <0.5-2> - frame size",
  "/gp stop | start - stop / resume sharing your position (also hides map pins)",
  "/gp frames | pins - toggle party frames / map pins",
  "/gp button - show or hide the minimap button",
  "/gp reset - move frames back to the default spot",
  "/gp sim - add/remove a fake friend for testing",
  "/gp status - connection and throttle details",
  "/gp debug - toggle debug messages",
}

local commands = {}

commands.help = function() for _, l in ipairs(HELP) do ns.Print(l) end end
commands.friends = function() ns.Roster:PrintFriends() end
commands.add = function(arg) ns.Roster:AddMember(arg) end
commands.remove = function(arg) ns.Roster:RemoveMember(arg) end
commands.list = function() ns.Roster:PrintMembers() end
commands.lock = function() ns.db.locked = true; ns.Frames:ApplySettings(); ns.Print("Frames locked.") end
commands.unlock = function() ns.db.locked = false; ns.Frames:ApplySettings(); ns.Print("Frames unlocked: drag the handle to move them.") end
commands.reset = function() ns.db.point = nil; ns.Frames:ApplySettings(); ns.Print("Frame position reset.") end
commands.sim = function() ns.Sim:Toggle() end
commands.status = function() ns.Comm:PrintStatus() end

commands.scale = function(arg)
  local s = tonumber(arg)
  if not s or s < 0.5 or s > 2 then return ns.Print("Usage: /gp scale 0.5-2") end
  ns.db.scale = s
  ns.Frames:ApplySettings()
end

-- Shared by the slash commands and the minimap button.
function ns.SetFramesShown(show)
  ns.db.showFrames = show
  ns.Frames:ApplySettings()
  ns.Print("Party frames", show and "shown." or "hidden.",
    InCombatLockdown() and "(Applies when combat ends.)" or "")
  if ns.Button then ns.Button:Update() end
end

-- Stop: tell friends you've left (their frame and pin for you disappear),
-- stop sending anything, and hide pins on your own maps. Saved across reloads.
function ns.SetSharing(on)
  if on == ns.db.sharing then
    return ns.Print(on and "Already sharing." or "Already stopped. /gp start to resume.")
  end
  if on then
    ns.db.sharing = true
    ns.State:SendHello(true)
    ns.Print("Sharing resumed: friends see you again, and map pins are back.")
  else
    ns.Comm:SendUrgent(ns.Protocol.EncodeBye())
    ns.Comm:ClearState()
    ns.db.sharing = false
    ns.Print("Sharing stopped: friends no longer see you, and map pins are hidden. /gp start to resume.")
  end
  if ns.Button then ns.Button:Update() end
end

commands.frames = function() ns.SetFramesShown(not ns.db.showFrames) end
commands.stop = function() ns.SetSharing(false) end
commands.start = function() ns.SetSharing(true) end
commands.button = function()
  ns.db.hideButton = not ns.db.hideButton
  if ns.Button then ns.Button:Update() end
  ns.Print("Minimap button", ns.db.hideButton and "hidden. /gp button brings it back." or "shown.")
end

commands.pins = function()
  ns.db.showPins = not ns.db.showPins
  ns.Print("Map pins", ns.db.showPins and "shown." or "hidden.")
end

commands.debug = function()
  ns.db.debug = not ns.db.debug
  ns.Print("Debug", ns.db.debug and "on." or "off.")
end

SLASH_GHOSTPARTY1 = "/gp"
SLASH_GHOSTPARTY2 = "/ghostparty"
SlashCmdList.GHOSTPARTY = function(input)
  local cmd, arg = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  local fn = commands[cmd] or commands.help
  fn(arg)
end
