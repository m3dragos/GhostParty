local _, ns = ...

-- Party-style frames. Uses the game's own party frame art (the 12.x atlas
-- frame when the client has it, otherwise vanilla's UI-PartyFrame).
--
-- Each slot is two layers:
--   visual  - plain frame, freely updated any time (also in combat)
--   click   - secure button that /targets the friend; only changed out of combat
local F = {}
ns.Frames = F

local P = ns.Protocol
local SPACING = 12 -- room for the zone/distance line under each frame

-- Geometry from the stock frames, in frame units from the top-left (y down).
local KITS = {
  modern = {
    w = 120, h = 49,
    art = { atlas = "UI-HUD-UnitFrame-Party-PortraitOn", x = 0, y = 0, w = 120, h = 49 },
    combat = { atlas = "ui-hud-unitframe-party-portraiton-incombat", x = 0, y = 0, w = 114, h = 47 },
    portrait = { x = 6, y = 4, s = 37 },
    health = { x = 44, y = 17, w = 70, h = 10, mask = "UI-HUD-UnitFrame-Party-PortraitOn-Bar-Health-Mask", mx = -29, my = 3 },
    power = { x = 40, y = 28, w = 74, h = 7, mask = "UI-HUD-UnitFrame-Party-PortraitOn-Bar-Mana-Mask", mx = -27, my = 4 },
    name = { x = 45, y = 4, w = 57, h = 12 },
    artAbove = false,
    subY = 3,  -- location line offset from the frame's bottom (up = positive)
  },
  classic = {
    w = 128, h = 53,
    art = { file = "Interface\\TargetingFrame\\UI-PartyFrame", x = 0, y = -1, w = 128, h = 64 },
    combat = { file = "Interface\\TargetingFrame\\UI-PartyFrame-Flash", x = -3, y = -5, w = 128, h = 64 },
    portrait = { x = 7, y = 4, s = 37 },
    health = { x = 47, y = 10, w = 70, h = 8 },
    power = { x = 47, y = 19, w = 70, h = 8 },
    name = { x = 50, y = -9, w = 60, h = 12 },
    artAbove = true,
    subY = 5,
  },
}

local function AtlasExists(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local kit
local anchor, handle
local slots = {}
local assigned = {}   -- slot index -> tag
local pendingSecure = false

local function Place(region, parent, g)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", parent, "TOPLEFT", g.x, -g.y)
  if g.w then region:SetSize(g.w, g.h) end
end

local function SetArt(tex, g)
  if g.atlas then tex:SetAtlas(g.atlas) else tex:SetTexture(g.file) end
end

local function MakeBar(parent, g, color)
  local bar = CreateFrame("StatusBar", nil, parent)
  Place(bar, parent, g)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(unpack(color))
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(1)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.55)
  if g.mask and AtlasExists(g.mask) then
    local m = bar:CreateMaskTexture()
    m:SetAtlas(g.mask)
    m:SetSize(128, 16)
    m:SetPoint("TOPLEFT", bar, "TOPLEFT", g.mx, g.my)
    bar:GetStatusBarTexture():AddMaskTexture(m)
    bg:AddMaskTexture(m)
  end
  bar.text = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
  bar.text:SetPoint("CENTER", 0, 0)
  bar.text:SetScale(0.85)
  return bar
end

-- One column growing downward, however many friends there are.
local function PlaceSlot(frame, i)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -(i - 1) * (kit.h + SPACING))
end

local function BuildVisual(i)
  local v = CreateFrame("Frame", nil, anchor)
  v:SetSize(kit.w, kit.h)
  PlaceSlot(v, i)

  v.portrait = v:CreateTexture(nil, "BACKGROUND", nil, 1)
  Place(v.portrait, v, { x = kit.portrait.x, y = kit.portrait.y, w = kit.portrait.s, h = kit.portrait.s })

  v.health = MakeBar(v, kit.health, { 0, 0.8, 0 })
  v.power = MakeBar(v, kit.power, { 0, 0, 1 })

  -- Modern art sits under the bars; vanilla art is drawn over them.
  local artHost = v
  if kit.artAbove then
    artHost = CreateFrame("Frame", nil, v)
    artHost:SetAllPoints()
    artHost:SetFrameLevel(v.health:GetFrameLevel() + 2)
  end
  v.art = artHost:CreateTexture(nil, kit.artAbove and "ARTWORK" or "BORDER")
  SetArt(v.art, kit.art)
  Place(v.art, v, kit.art)

  v.combat = artHost:CreateTexture(nil, "OVERLAY")
  SetArt(v.combat, kit.combat)
  Place(v.combat, v, kit.combat)
  v.combat:SetVertexColor(1, 0.1, 0.1)
  v.combat:SetBlendMode("ADD")
  v.combat:Hide()

  local textHost = CreateFrame("Frame", nil, v)
  textHost:SetAllPoints()
  textHost:SetFrameLevel(v.health:GetFrameLevel() + 3)

  v.name = textHost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  Place(v.name, v, kit.name)
  v.name:SetJustifyH("LEFT")

  v.level = textHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.level:SetPoint("BOTTOMLEFT", v.portrait, "BOTTOMLEFT", -2, -2)
  v.level:SetFont(v.level:GetFont(), 9, "OUTLINE")

  v.status = textHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.status:SetPoint("CENTER", v.health, "CENTER")

  v.sub = textHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  -- Full width of the frame, tucked right under the art.
  v.sub:SetPoint("TOPLEFT", v, "BOTTOMLEFT", kit.portrait.x, kit.subY)
  v.sub:SetPoint("TOPRIGHT", v, "BOTTOMRIGHT", -4, kit.subY)
  v.sub:SetJustifyH("LEFT")
  v.sub:SetWordWrap(false)

  v:Hide()
  return v
end

local function ShowTooltip(owner, r)
  if not r then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.name or r.tag, ns.ClassColor(r.class))
  GameTooltip:AddLine(r.tag, 0.7, 0.7, 0.7)
  if r.level then
    local className = r.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.class] or r.class or ""
    GameTooltip:AddLine(("Level %d %s"):format(r.level, className), 1, 1, 1)
  end
  if r.zone and r.zone ~= "" then GameTooltip:AddLine(r.zone, 1, 0.82, 0) end
  local yards = ns.Geo and ns.Geo.DistanceTo(r)
  if yards then GameTooltip:AddLine(("%d yards away"):format(yards), 1, 1, 1) end
  local age = r.heardAt and GetTime() - r.heardAt
  if age and age > 3 then GameTooltip:AddLine(("Last update %ds ago"):format(age), 0.6, 0.6, 0.6) end
  if not r.sim then
    GameTooltip:AddLine("Left-click: target (when nearby)", 0.4, 0.8, 1)
    if ns.Geo and ns.Geo.InMyGroup(r) then
      GameTooltip:AddLine("In your group", 0.6, 0.6, 0.6)
    else
      GameTooltip:AddLine("Right-click: invite to group", 0.4, 0.8, 1)
    end
  end
  GameTooltip:Show()
end

local function BuildClick(i)
  local b = CreateFrame("Button", "GhostPartySlot" .. i, anchor, "SecureActionButtonTemplate")
  -- Anchored to the anchor, not the visual: a frame a secure button is anchored
  -- to gets restricted in combat, and the visual must stay free to change.
  b:SetSize(kit.w, kit.h)
  PlaceSlot(b, i)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type1", "macro")
  b:SetAttribute("macrotext1", "")
  b:SetAttribute("type2", "macro")
  b:SetAttribute("macrotext2", "")
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
  kit = AtlasExists(KITS.modern.art.atlas) and KITS.modern or KITS.classic
  anchor = CreateFrame("Frame", "GhostPartyAnchor", UIParent)
  anchor:SetSize(kit.w, kit.h)
  anchor:SetMovable(true)
  anchor:SetClampedToScreen(true)

  handle = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
  handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
  handle:SetSize(kit.w, 16)
  handle:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  handle:SetBackdropColor(0.1, 0.4, 0.7, 0.8)
  handle:SetBackdropBorderColor(0, 0, 0, 1)
  local label = handle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("CENTER")
  label:SetText("GhostParty - drag, /gp lock")
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

  ApplyAnchor()
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
  -- Re-place every slot (also covers slots made while in combat).
  for i, s in pairs(slots) do
    PlaceSlot(s.visual, i)
    if s.click then PlaceSlot(s.click, i) end
  end
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
    -- Right-click invites, unless they're already in your group.
    local invite = (real and not (ns.Geo and ns.Geo.InMyGroup(r))) and ("/invite " .. r.name) or ""
    if s.click:GetAttribute("macrotext1") ~= target then s.click:SetAttribute("macrotext1", target) end
    if s.click:GetAttribute("macrotext2") ~= invite then s.click:SetAttribute("macrotext2", invite) end
    s.click:SetShown(r ~= nil)
  end
end

local function Fmt(v)
  if v >= 10000 then return ("%.1fk"):format(v / 1000) end
  return tostring(v)
end

local function UpdateVisual(v, r, now)
  local dead = P.HasFlag(r.flags, P.FLAG_DEAD)
  local ghost = P.HasFlag(r.flags, P.FLAG_GHOST)
  local live = r.heardAt and now - r.heardAt < ns.Members.STALE_AFTER

  -- Portrait: class icon in the round portrait slot.
  local coords = r.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[r.class]
  if coords then
    v.portrait:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    v.portrait:SetTexCoord(unpack(coords))
  else
    v.portrait:SetTexture("Interface\\CharacterFrame\\TempPortrait")
    v.portrait:SetTexCoord(0, 1, 0, 1)
  end
  v.portrait:SetDesaturated(dead or ghost or not live)

  v.name:SetText(r.name or r.tag)
  v.level:SetText(r.level and tostring(r.level) or "")

  -- Health
  local hp, hpMax = r.hp, r.hpMax
  if hpMax and hpMax > 0 and hp then
    v.health:SetMinMaxValues(0, hpMax)
    v.health:SetValue((dead or ghost) and 0 or hp)
    v.health.text:SetText((dead or ghost) and "" or (Fmt(hp) .. " / " .. Fmt(hpMax)))
  else
    v.health:SetMinMaxValues(0, 1)
    v.health:SetValue(1)
    v.health.text:SetText("")
  end

  -- Power, coloured by type.
  local pc = r.pwType and PowerBarColor and PowerBarColor[r.pwType]
  if pc then v.power:SetStatusBarColor(pc.r, pc.g, pc.b) end
  if r.pwMax and r.pwMax > 0 and r.pw then
    v.power:SetMinMaxValues(0, r.pwMax)
    v.power:SetValue(r.pw)
  else
    v.power:SetMinMaxValues(0, 1)
    v.power:SetValue(0)
  end
  v.power.text:SetText("")

  if ghost then v.status:SetText("Ghost")
  elseif dead then v.status:SetText("Dead")
  elseif not live then v.status:SetText("No signal")
  else v.status:SetText("") end
  if v.status:GetText() ~= "" then v.health.text:SetText("") end

  v.combat:SetShown(live and P.HasFlag(r.flags, P.FLAG_COMBAT))
  v:SetAlpha(live and 1 or 0.55)

  -- Zone / distance line.
  local sub
  if P.HasFlag(r.flags, P.FLAG_INSTANCE) then
    sub = (r.zone and r.zone ~= "" and r.zone or "Instance") .. " (inside)"
  else
    local yards = ns.Geo and ns.Geo.DistanceTo(r)
    if yards then
      sub = ("%s%d yd"):format((r.zone and r.zone ~= "" and (r.zone .. " - ") or ""), yards)
    else
      sub = r.zone or ""
    end
  end
  if P.HasFlag(r.flags, P.FLAG_AFK) then sub = "<AFK> " .. sub end
  v.sub:SetText(sub)
end

function F:Refresh()
  if not anchor then return end
  local now = GetTime()
  local visible = ns.Members:Visible()

  local want = {}
  for _, r in ipairs(visible) do want[r.tag] = r end
  local changed = false

  if not InCombatLockdown() then
    -- Out of combat: pack frames in list order, no gaps.
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
  C_Timer.NewTicker(0.5, function() F:Refresh() end)
end)

-- Joining/leaving a group changes who right-click can invite. Wait a frame so
-- the group list in Pins.lua has refreshed first.
ns:On("GROUP_ROSTER_UPDATE", function()
  C_Timer.After(0, function()
    pendingSecure = true
    F:Refresh()
  end)
end)

ns:On("PLAYER_REGEN_ENABLED", function()
  if pendingSecure then F:ApplySettings() end
  F:Refresh() -- closes any gaps left during combat
end)
