local _, ns = ...

-- The friend roster: one row per friend, in WoW's tooltip style.
--   [class icon] Name                    [status icons]  [+ / -]
--                Zone, Subzone                   180 yd  [find]
--
-- Each slot is three layers:
--   visual  - plain frame, freely updated any time (also in combat)
--   click   - secure button over the row that /targets the friend; only
--             changed out of combat, and anchored to the anchor (never to the
--             visual, which must stay free to change)
--   buttons - insecure Invite / Uninvite / Find on top of the click layer
--             (C_PartyInfo and waypoints aren't protected, so they work in combat)
local F = {}
ns.Frames = F

local P = ns.Protocol
local Call = ns.Call

local H, GAP = 38, 2
local MIN_W, MAX_W, DEFAULT_W = 180, 420, 236

-- Row width: the player's choice (drag the grip on the handle while unlocked).
local function Width()
  local w = tonumber(ns.db and ns.db.width) or DEFAULT_W
  return math.max(MIN_W, math.min(MAX_W, w))
end
local ICON = 28
local STATUS_SIZE = 14

local anchor, handle
local slots = {}
local assigned = {}   -- slot index -> tag
local pendingSecure = false

local function AtlasExists(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

---------------------------------------------------------------------------
-- Status icons, in display order. test(r) says whether it shows.
---------------------------------------------------------------------------
local function St(r, bit) return P.HasFlag(r.status, bit) end
local function Fl(r, bit) return P.HasFlag(r.flags, bit) end
local ICON_CROP = { 0.08, 0.92, 0.08, 0.92 }

local STATUSES = {
  { key = "combat", label = "In combat", file = "Interface\\CharacterFrame\\UI-StateIcon", coords = { 0.5, 1, 0, 0.5 },
    test = function(r) return Fl(r, P.FLAG_COMBAT) end },
  { key = "ghost", label = "Ghost", atlas = "poi-graveyard-neutral", test = function(r) return Fl(r, P.FLAG_GHOST) end },
  { key = "dead", label = "Dead", file = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    test = function(r) return Fl(r, P.FLAG_DEAD) end },
  { key = "afk", label = "Away", file = "Interface\\FriendsFrame\\StatusIcon-Away", test = function(r) return Fl(r, P.FLAG_AFK) end },
  { key = "dnd", label = "Do not disturb", file = "Interface\\FriendsFrame\\StatusIcon-DnD",
    test = function(r) return St(r, P.ST_DND) end },
  { key = "raid", label = "In a raid", atlas = "Raid", test = function(r) return r.instType == "raid" end },
  { key = "dungeon", label = "In a dungeon", atlas = "Dungeon",
    test = function(r) return Fl(r, P.FLAG_INSTANCE) and (r.instType == "party" or r.instType == "scenario" or not r.instType) end },
  { key = "bg", label = "In a battleground", file = "Interface\\TargetingFrame\\UI-PVP-FFA", coords = { 0, 0.62, 0, 0.62 },
    test = function(r) return r.instType == "pvp" or r.instType == "arena" end },
  { key = "taxi", label = "On a flight", file = "Interface\\Icons\\Ability_Mount_Wyvern_01", coords = ICON_CROP,
    test = function(r) return St(r, P.ST_TAXI) or St(r, P.ST_FLYING) end },
  { key = "resting", label = "Resting", file = "Interface\\CharacterFrame\\UI-StateIcon", coords = { 0, 0.5, 0, 0.5 },
    test = function(r) return St(r, P.ST_RESTING) end },
  { key = "group", label = "In a group", atlas = "socialqueuing-icon-group",
    test = function(r) return (r.group or 0) > 1 end },
  { key = "pvp", label = "PvP flagged", file = "Interface\\TargetingFrame\\UI-PVP-FFA", coords = { 0, 0.62, 0, 0.62 },
    test = function(r) return St(r, P.ST_PVP) and not (r.instType == "pvp" or r.instType == "arena") end },
}

local function SetIcon(tex, spec)
  if spec.atlas and AtlasExists(spec.atlas) then
    tex:SetAtlas(spec.atlas)
    tex:SetTexCoord(0, 1, 0, 1)
  else
    tex:SetTexture(spec.file or "Interface\\Icons\\INV_Misc_QuestionMark")
    local c = spec.coords
    if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) else tex:SetTexCoord(0, 1, 0, 1) end
  end
end

---------------------------------------------------------------------------
-- Actions (insecure)
---------------------------------------------------------------------------
local function FullName(r)
  return ns.Roster:Chars(r.tag)[1] or r.name
end

-- Battle.net friends: Blizzard's own friends-list invite (player GUID + game
-- account), which works across realms. "Name-Realm" built from Battle.net's
-- realm field doesn't ("Cannot find player"). By name only as a last resort
-- (a friend reached by whisper while Appearing Offline).
local function Invite(r)
  local o = ns.Roster:Online(r.tag)
  local id = o and o.gameAccountID
  local U = FriendsListUtil
  if id and U and U.InviteOrRequestToJoin and C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
    local info = Call(C_BattleNet.GetGameAccountInfoByID, id)
    local guid = type(info) == "table" and ns.Plain(info.playerGuid)
    if guid and pcall(U.InviteOrRequestToJoin, guid, id) then return end
  end
  local f = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
  if f and r.name then pcall(f, FullName(r)) end
end

-- In your group they have a unit token: uninvite by the name the client
-- itself gives that unit.
local function Uninvite(r)
  local f = C_PartyInfo and C_PartyInfo.UninviteUnit or UninviteUnit
  if not f then return end
  local unit = ns.Geo and ns.Geo.InMyGroup(r)
  local name = unit and Call(GetUnitName, unit, true)
  if name or r.name then pcall(f, name or FullName(r)) end
end

-- Find: Blizzard's own map pin and on-screen arrow at the friend's position,
-- moved every few seconds while you're still tracking them.
local findTag
local FIND_REFRESH = 3

local function CanFind(r)
  return r.pos and not P.HasFlag(r.flags, P.FLAG_INSTANCE) and C_Map and C_Map.SetUserWaypoint
end

local function PlaceWaypoint(r)
  local map, x, y = ns.Members:Position(r, GetTime())
  if not map then return false end
  if C_Map.CanSetUserWaypointOnMap and not Call(C_Map.CanSetUserWaypointOnMap, map) then
    local mine = ns.Geo.Player()
    if not mine then return false end
    local mx, my = ns.Geo.ToMap(map, x, y, mine)
    if not (mx and my and mx >= 0 and mx <= 1 and my >= 0 and my <= 1) then return false end
    map, x, y = mine, mx, my
  end
  local point = UiMapPoint and UiMapPoint.CreateFromCoordinates and UiMapPoint.CreateFromCoordinates(map, x, y)
    or { uiMapID = map, position = CreateVector2D(x, y) }
  local ok = pcall(C_Map.SetUserWaypoint, point)
  if ok and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
  end
  return ok
end

local function StopFinding()
  findTag = nil
  if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

local function Find(r)
  if findTag == r.tag then
    StopFinding()
    return ns.Print("Stopped finding " .. (r.name or r.tag) .. ".")
  end
  if not CanFind(r) then return ns.Print((r.name or r.tag) .. " can't be found on the map right now.") end
  if PlaceWaypoint(r) then
    findTag = r.tag
    ns.Print("Finding " .. (r.name or r.tag) .. ": follow the arrow. Click the pin button again to stop.")
  else
    ns.Print("The map won't take a waypoint there.")
  end
end

local function StillFinding()
  if not findTag then return false end
  local hasPoint = C_Map.HasUserWaypoint and Call(C_Map.HasUserWaypoint)
  local tracked = not C_SuperTrack or not C_SuperTrack.IsSuperTrackingUserWaypoint
    or Call(C_SuperTrack.IsSuperTrackingUserWaypoint)
  if not (hasPoint and tracked) then findTag = nil end
  return findTag ~= nil
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function ShowTooltip(owner, r)
  if not r then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.name or r.tag, ns.ClassColor(r.class))
  GameTooltip:AddLine(r.tag, 0.7, 0.7, 0.7)
  if r.guild then GameTooltip:AddLine("<" .. r.guild .. ">", 0.25, 1, 0.25) end
  if r.level then
    local className = r.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.class] or r.class or ""
    GameTooltip:AddLine(("Level %d %s%s"):format(r.level, r.race and (r.race .. " ") or "", className), 1, 1, 1)
  end
  local where = r.zone or ""
  if r.subzone and r.subzone ~= r.zone then where = (where ~= "" and (r.subzone .. ", " .. where)) or r.subzone end
  if where ~= "" then GameTooltip:AddLine(where, 1, 0.82, 0) end
  local yards = ns.Geo and ns.Geo.DistanceTo(r)
  if yards then GameTooltip:AddLine(("%d yards away"):format(yards), 1, 1, 1) end
  for _, s in ipairs(STATUSES) do
    if s.test(r) then
      local label = s.label
      if s.key == "group" then label = ("In a group of %d"):format(r.group) end
      GameTooltip:AddLine(label, 0.8, 0.8, 0.8)
    end
  end
  if r.home then GameTooltip:AddLine("Home: " .. r.home, 0.6, 0.6, 0.6) end
  local age = r.heardAt and GetTime() - r.heardAt
  if age and age > 3 then GameTooltip:AddLine(("Last update %ds ago"):format(age), 0.6, 0.6, 0.6) end
  if not r.sim then
    if r.hasInfo then
      GameTooltip:AddLine(ns.NAME .. " " .. (r.version or "?"), 0.5, 0.5, 0.5)
    else
      GameTooltip:AddLine("Older version (0.3.x): no statuses or news", 1, 0.5, 0.25)
    end
  end
  if not r.sim then GameTooltip:AddLine("Click: target (when nearby)", 0.4, 0.8, 1) end
  GameTooltip:Show()
end

local function ButtonTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self.tip, 1, 1, 1)
  GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
local function PlaceSlot(frame, i)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -(i - 1) * (H + GAP))
end

local function SmallButton(parent, tip, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(16, 16)
  b:SetFrameLevel(parent:GetFrameLevel() + 5) -- above the secure click layer
  b.tip = tip
  b:SetScript("OnEnter", ButtonTooltip)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self) if self.rec then onClick(self.rec) end end)
  return b
end

local function BuildVisual(i)
  local v = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
  v:SetSize(Width(), H)
  PlaceSlot(v, i)
  v:SetFrameLevel(anchor:GetFrameLevel() + 1)
  v:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  v:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
  v:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

  v.icon = v:CreateTexture(nil, "ARTWORK")
  v.icon:SetSize(ICON, ICON)
  v.icon:SetPoint("LEFT", v, "LEFT", 5, 0)

  v.level = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.level:SetPoint("BOTTOMLEFT", v.icon, "BOTTOMLEFT", -2, -2)
  v.level:SetFont(v.level:GetFont(), 9, "OUTLINE")

  -- Right column: Invite/Uninvite on top, Find below.
  v.invite = SmallButton(v, "Invite to your group", Invite)
  v.invite:SetPoint("TOPRIGHT", v, "TOPRIGHT", -4, -3)
  v.invite:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
  v.invite:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
  v.invite:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")

  v.uninvite = SmallButton(v, "Remove from your group", Uninvite)
  v.uninvite:SetPoint("TOPRIGHT", v, "TOPRIGHT", -4, -3)
  v.uninvite:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
  v.uninvite:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
  v.uninvite:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")

  v.find = SmallButton(v, "Find: map pin and arrow to them (click again to stop)", Find)
  v.find:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -4, 3)
  local pin = v.find:CreateTexture(nil, "ARTWORK")
  pin:SetAllPoints()
  SetIcon(pin, { atlas = "Waypoint-MapPin-Untracked", file = "Interface\\Minimap\\Tracking\\None" })
  v.find.pin = pin
  v.find:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

  local right = -24
  v.name = v:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  v.name:SetPoint("TOPLEFT", v, "TOPLEFT", 5 + ICON + 6, -4)
  v.name:SetPoint("TOPRIGHT", v, "TOPRIGHT", right, -4)
  v.name:SetJustifyH("LEFT")
  v.name:SetWordWrap(false)

  v.statuses = {}
  for k = 1, 6 do
    local t = v:CreateTexture(nil, "OVERLAY")
    t:SetSize(STATUS_SIZE, STATUS_SIZE)
    if k == 1 then t:SetPoint("TOPRIGHT", v, "TOPRIGHT", right, -5)
    else t:SetPoint("RIGHT", v.statuses[k - 1], "LEFT", -1, 0) end
    t:Hide()
    v.statuses[k] = t
  end
  v.groupCount = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.groupCount:SetFont(v.groupCount:GetFont(), 8, "OUTLINE")

  v.dist = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.dist:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", right, 5)
  v.dist:SetJustifyH("RIGHT")

  v.sub = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  v.sub:SetPoint("BOTTOMLEFT", v.icon, "BOTTOMRIGHT", 6, 0)
  v.sub:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", right - 46, 5) -- 46: room for "1234 yd"
  v.sub:SetJustifyH("LEFT")
  v.sub:SetWordWrap(false)

  v:Hide()
  return v
end

local function BuildClick(i)
  local b = CreateFrame("Button", "GhostPartySlot" .. i, anchor, "SecureActionButtonTemplate")
  b:SetSize(Width(), H)
  PlaceSlot(b, i)
  b:SetFrameLevel(anchor:GetFrameLevel() + 2)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type1", "macro")
  b:SetAttribute("macrotext1", "")
  b:SetScript("OnEnter", function(self) ShowTooltip(self, ns.Members:Get(assigned[i] or "", true)) end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:Hide()
  return b
end

local function ApplyAnchor()
  anchor:SetScale(ns.db.scale or 1)
  anchor:ClearAllPoints()
  local p = ns.db.point
  if p then
    anchor:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 30, -220)
  end
end

local function Build()
  anchor = CreateFrame("Frame", "GhostPartyAnchor", UIParent)
  anchor:SetSize(Width(), H)
  anchor:SetMovable(true)
  anchor:SetClampedToScreen(true)

  handle = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
  handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
  handle:SetSize(Width(), 18)
  handle:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  handle:SetBackdropColor(0.15, 0.1, 0.02, 0.9)
  handle:SetBackdropBorderColor(1, 0.82, 0, 1)
  local label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", handle, "LEFT", 6, 0)
  label:SetPoint("RIGHT", handle, "RIGHT", -20, 0)
  label:SetJustifyH("LEFT")
  label:SetWordWrap(false)
  label:SetText(ns.NAME .. " - drag to move, grip to resize")
  handle:EnableMouse(true)
  handle:RegisterForDrag("LeftButton")
  handle:SetScript("OnDragStart", function()
    if not InCombatLockdown() then anchor:StartMoving() end
  end)
  handle:SetScript("OnDragStop", function()
    anchor:StopMovingOrSizing()
    local p, _, rp, x, y = anchor:GetPoint()
    ns.db.point = { p, rp, x, y }
  end)

  -- Resize grip (width only; height follows the number of friends).
  local grip = CreateFrame("Button", nil, handle)
  grip:SetSize(16, 16)
  grip:SetPoint("RIGHT", handle, "RIGHT", -2, 0)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Drag to resize", 1, 1, 1)
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", GameTooltip_Hide)
  local startX, startW, liveW
  local function CursorX() return GetCursorPosition() / anchor:GetEffectiveScale() end
  grip:SetScript("OnMouseDown", function(self)
    if InCombatLockdown() then return end
    startX, startW, liveW = CursorX(), Width(), Width()
    self:SetScript("OnUpdate", function()
      if InCombatLockdown() then return end
      liveW = math.max(MIN_W, math.min(MAX_W, math.floor(startW + CursorX() - startX + 0.5)))
      F:SetWidths(liveW)
    end)
  end)
  grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    if liveW then ns.db.width = liveW end
    startX, liveW = nil, nil
    F:ApplySettings()
  end)

  ApplyAnchor()
end

-- Every row's width (secure click buttons too, so out of combat only).
function F:SetWidths(w)
  if not anchor or InCombatLockdown() then return end
  w = w or Width()
  anchor:SetWidth(w)
  handle:SetWidth(w)
  for _, s in pairs(slots) do
    s.visual:SetWidth(w)
    if s.click then s.click:SetWidth(w) end
  end
end

-- Slots are made on demand, so there's no limit on friends. The visual part
-- can be made any time; the secure click part only out of combat.
local function EnsureSlot(i)
  local s = slots[i]
  if not s then
    s = { visual = BuildVisual(i) }
    slots[i] = s
  end
  if not s.click then
    if InCombatLockdown() then pendingSecure = true else s.click = BuildClick(i) end
  end
end

function F:ApplySettings()
  if not anchor then return end
  if InCombatLockdown() then
    pendingSecure = true
    return
  end
  ApplyAnchor()
  for i, s in pairs(slots) do
    PlaceSlot(s.visual, i)
    if s.click then PlaceSlot(s.click, i) end
  end
  self:SetWidths()
  handle:SetShown(not ns.db.locked)
  anchor:SetShown(ns.db.showFrames)
  self:Refresh()
end

-- Secure attributes and click-button visibility (out of combat only).
local function UpdateSecure()
  if InCombatLockdown() then
    pendingSecure = true
    return
  end
  pendingSecure = false
  for i, s in pairs(slots) do
    if not s.click then s.click = BuildClick(i) end
    local r = assigned[i] and ns.Members:Get(assigned[i], true)
    local real = r and not r.sim and r.name
    local target = real and ("/target " .. r.name) or ""
    if s.click:GetAttribute("macrotext1") ~= target then s.click:SetAttribute("macrotext1", target) end
    s.click:SetShown(r ~= nil)
  end
end

---------------------------------------------------------------------------
-- Updating
---------------------------------------------------------------------------
local function UpdateButtons(v, r)
  local real = not r.sim
  local grouped = ns.Geo and ns.Geo.InMyGroup(r)
  local leader = Call(UnitIsGroupLeader, "player")
  v.invite.rec, v.uninvite.rec, v.find.rec = r, r, r
  v.invite:SetShown(real and not grouped)
  v.uninvite:SetShown(real and grouped and leader and true or false)
  local findable = CanFind(r) and true or false
  v.find:SetShown(findable)
  v.find.pin:SetDesaturated(findTag ~= r.tag)
  v.find.pin:SetAlpha(findTag == r.tag and 1 or 0.8)
end

local function UpdateVisual(v, r, now)
  local dead = P.HasFlag(r.flags, P.FLAG_DEAD)
  local ghost = P.HasFlag(r.flags, P.FLAG_GHOST)
  local live = r.heardAt and now - r.heardAt < ns.Members.STALE_AFTER

  local coords = r.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[r.class]
  if coords then
    v.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    v.icon:SetTexCoord(unpack(coords))
  else
    v.icon:SetTexture("Interface\\CharacterFrame\\TempPortrait")
    v.icon:SetTexCoord(0, 1, 0, 1)
  end
  v.icon:SetDesaturated(dead or ghost or not live)
  v.level:SetText(r.level and tostring(r.level) or "")

  v.name:SetText(r.name or r.tag)
  v.name:SetTextColor(ns.ClassColor(r.class))

  -- Status icons (as many as fit), right to left.
  local n = 0
  v.groupCount:Hide()
  if live then
    for _, s in ipairs(STATUSES) do
      if n < #v.statuses and s.test(r) then
        n = n + 1
        local t = v.statuses[n]
        SetIcon(t, s)
        t:Show()
        if s.key == "group" then
          v.groupCount:ClearAllPoints()
          v.groupCount:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 1, -1)
          v.groupCount:SetText(r.group)
          v.groupCount:Show()
        end
      end
    end
  end
  for k = n + 1, #v.statuses do v.statuses[k]:Hide() end
  -- The name stops where the icons start.
  v.name:SetPoint("TOPRIGHT", v, "TOPRIGHT", -26 - n * (STATUS_SIZE + 1), -4)

  -- Bottom line: where they are, distance and direction.
  local where
  if not live then
    where = "No signal"
  elseif P.HasFlag(r.flags, P.FLAG_INSTANCE) then
    where = (r.zone and r.zone ~= "" and r.zone or "Instance") .. " (inside)"
  else
    where = r.zone or ""
    if r.subzone and r.subzone ~= "" and r.subzone ~= r.zone then
      where = where ~= "" and (where .. ", " .. r.subzone) or r.subzone
    end
  end
  v.sub:SetText(where)

  local yards = live and ns.Geo and ns.Geo.DistanceTo(r)
  if yards then
    v.dist:SetText(yards >= 1000 and ("%.1f km"):format(yards / 1093.6) or (yards .. " yd"))
  else
    v.dist:SetText("")
  end

  UpdateButtons(v, r)
  v:SetAlpha(live and 1 or 0.55)
  v:SetBackdropBorderColor(live and P.HasFlag(r.flags, P.FLAG_COMBAT) and 1 or 0.6, live and P.HasFlag(r.flags, P.FLAG_COMBAT) and 0.2 or 0.6,
    live and P.HasFlag(r.flags, P.FLAG_COMBAT) and 0.2 or 0.6, 1)
end

function F:Refresh()
  if not anchor then return end
  local now = GetTime()
  local visible = ns.Members:Visible()

  local want = {}
  for _, r in ipairs(visible) do want[r.tag] = r end
  local changed = false

  if not InCombatLockdown() then
    -- Out of combat: pack rows in list order, no gaps.
    local highest = 0
    for i in pairs(assigned) do highest = math.max(highest, i) end
    for i = 1, math.max(#visible, highest) do
      local tag = visible[i] and visible[i].tag
      if assigned[i] ~= tag then assigned[i] = tag; changed = true end
    end
  end

  -- In combat click targets can't change: existing members keep their slot,
  -- leavers leave a gap and newcomers take the first free one until combat ends.
  for i, tag in pairs(assigned) do
    if not want[tag] then assigned[i] = nil; changed = true end
  end
  local placed = {}
  for _, tag in pairs(assigned) do placed[tag] = true end
  for _, r in ipairs(visible) do
    if not placed[r.tag] then
      local i = 1
      while assigned[i] do i = i + 1 end
      assigned[i], placed[r.tag], changed = r.tag, true, true
    end
  end
  for i in pairs(assigned) do EnsureSlot(i) end

  for i, s in pairs(slots) do
    local r = assigned[i] and want[assigned[i]]
    if r then
      UpdateVisual(s.visual, r, now)
      s.visual:Show()
    else
      s.visual:Hide()
    end
  end
  if changed or pendingSecure then UpdateSecure() end
end

ns:On("PLAYER_LOGIN", function()
  Build()
  F:ApplySettings()
  -- Distance and "No signal" change without messages arriving.
  C_Timer.NewTicker(0.2, function() F:Refresh() end)
  C_Timer.NewTicker(FIND_REFRESH, function()
    if not StillFinding() then return end
    local r = ns.Members:Get(findTag, true)
    if r and CanFind(r) then PlaceWaypoint(r) end
  end)
end)

ns:On("GROUP_ROSTER_UPDATE", function()
  C_Timer.After(0, function() F:Refresh() end)
end)

ns:On("PLAYER_REGEN_ENABLED", function()
  if pendingSecure then F:ApplySettings() end
  F:Refresh() -- closes any gaps left during combat
end)
