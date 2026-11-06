local _, ns = ...

-- Minimap and world map pins, plus the map math shared with the frames.
local Call = ns.Call

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------
local Geo = {}
ns.Geo = Geo

local function WorldPos(map, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  local cont, pos = Call(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if not (cont and pos) then return nil end
  local wx, wy = pos:GetXY()
  return cont, wx, wy, pos
end

-- A position on one map, expressed on another (may fall outside 0..1).
function Geo.ToMap(srcMap, x, y, dstMap)
  if srcMap == dstMap then return x, y end
  local cont, _, _, pos = WorldPos(srcMap, x, y)
  if not cont then return nil end
  local _, out = Call(C_Map.GetMapPosFromWorldPos, cont, pos, dstMap)
  if not out then return nil end
  return out:GetXY()
end

function Geo.Player()
  local map = Call(C_Map.GetBestMapForUnit, "player")
  local pos = map and Call(C_Map.GetPlayerMapPosition, map, "player")
  if not pos then return nil end
  local x, y = pos:GetXY()
  x, y = ns.Plain(x), ns.Plain(y)
  if not (x and y) then return nil end
  return map, x, y
end

-- Yards from you to a friend, or nil (different continent, instance, unknown).
function Geo.DistanceTo(r)
  local p = r.pos
  if not p then return nil end
  local map, x, y = Geo.Player()
  if not map then return nil end
  local c1, x1, y1 = WorldPos(map, x, y)
  local c2, x2, y2 = WorldPos(p.map, p.x, p.y)
  if not (c1 and c2) or c1 ~= c2 then return nil end
  return math.floor(math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) + 0.5)
end

---------------------------------------------------------------------------
-- Pin widgets
---------------------------------------------------------------------------
local function MakePin(parent, size, withLabel)
  local pin = CreateFrame("Frame", nil, parent)
  pin:SetSize(size, size)
  pin.icon = pin:CreateTexture(nil, "OVERLAY")
  pin.icon:SetAllPoints()
  if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("PlayerPartyBlip") then
    pin.icon:SetAtlas("PlayerPartyBlip")
  else
    pin.icon:SetTexture("Interface\\Buttons\\WHITE8x8")
    local mask = pin:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(pin.icon)
    pin.icon:AddMaskTexture(mask)
  end
  if withLabel then
    pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pin.label:SetPoint("BOTTOM", pin, "TOP", 0, 1)
    pin.label:SetFont(pin.label:GetFont(), 11, "OUTLINE")
  end
  pin:EnableMouse(true)
  pin:SetScript("OnEnter", function(self)
    local r = self.rec
    if not r then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(r.name or r.tag, ns.ClassColor(r.class))
    if r.level then GameTooltip:AddLine("Level " .. r.level, 1, 1, 1) end
    local yards = Geo.DistanceTo(r)
    if yards then GameTooltip:AddLine(yards .. " yards away", 1, 1, 1) end
    GameTooltip:Show()
  end)
  pin:SetScript("OnLeave", GameTooltip_Hide)
  pin:Hide()
  return pin
end

local function Paint(pin, r, live)
  local cr, cg, cb = ns.ClassColor(r.class)
  pin.icon:SetVertexColor(cr, cg, cb)
  pin:SetAlpha(live and 1 or 0.5)
  if pin.label then
    pin.label:SetText(r.name or r.tag)
    pin.label:SetTextColor(cr, cg, cb)
  end
  pin.rec = r
end

---------------------------------------------------------------------------
-- Minimap
---------------------------------------------------------------------------
-- Minimap diameter in yards for each zoom level (0-5).
local MINIMAP_YARDS = {
  indoor = { 300, 240, 180, 120, 80, 50 },
  outdoor = { 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}

local miniPins = {}

local function MiniPin(tag)
  local pin = miniPins[tag]
  if not pin then
    pin = MakePin(Minimap, 14, false)
    pin:SetFrameStrata(Minimap:GetFrameStrata())
    pin:SetFrameLevel(Minimap:GetFrameLevel() + 6)
    miniPins[tag] = pin
  end
  return pin
end

local function UpdateMinimap(visible, now)
  local shown = {}
  local map, px, py = Geo.Player()
  local w, h
  if map then w, h = Call(C_Map.GetMapWorldSize, map) end

  if ns.db.showPins and ns.db.sharing and map and w and w > 0 and Minimap:IsVisible() then
    local zoom = (Minimap:GetZoom() or 0) + 1
    local diameter = (Call(IsIndoors) and MINIMAP_YARDS.indoor or MINIMAP_YARDS.outdoor)[zoom] or 466
    local radius = Minimap:GetWidth() / 2
    local pxPerYard = Minimap:GetWidth() / diameter
    local rotate = GetCVar("rotateMinimap") == "1"
    local facing = rotate and Call(GetPlayerFacing) or 0
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE"

    for _, r in ipairs(visible) do
      local fmap, fx, fy = ns.Members:Position(r, now)
      if fmap then fx, fy = Geo.ToMap(fmap, fx, fy, map) end
      if fx then
        -- Yards east / north of you, then pixels.
        local ox = (fx - px) * w * pxPerYard
        local oy = -(fy - py) * h * pxPerYard
        if rotate and facing ~= 0 then
          local c, s = math.cos(-facing), math.sin(-facing)
          ox, oy = ox * c - oy * s, ox * s + oy * c
        end
        -- Off the edge: clamp to the rim, smaller and faded.
        local edge = false
        local limit = radius - 6
        if square then
          if math.abs(ox) > limit or math.abs(oy) > limit then
            local k = limit / math.max(math.abs(ox), math.abs(oy))
            ox, oy, edge = ox * k, oy * k, true
          end
        else
          local d = math.sqrt(ox * ox + oy * oy)
          if d > limit then ox, oy, edge = ox * limit / d, oy * limit / d, true end
        end
        local pin = MiniPin(r.tag)
        Paint(pin, r, r.live)
        pin:SetSize(edge and 10 or 14, edge and 10 or 14)
        if edge then pin:SetAlpha(0.7) end
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
        pin:Show()
        shown[r.tag] = true
      end
    end
  end
  for tag, pin in pairs(miniPins) do
    if not shown[tag] then pin:Hide() end
  end
end

---------------------------------------------------------------------------
-- World map
---------------------------------------------------------------------------
local worldPins = {}

local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local function StrataAbove(s)
  for i, name in ipairs(STRATA) do
    if name == s then return STRATA[math.min(i + 1, #STRATA - 1)] end
  end
  return "DIALOG"
end

local function UpdateWorldMap(visible, now)
  local shown = {}
  local wm = WorldMapFrame
  if ns.db.showPins and ns.db.sharing and wm and wm:IsShown() and wm.GetMapID and wm.GetCanvas then
    local mapID = wm:GetMapID()
    local canvas = wm:GetCanvas()
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local ok, canvasScale = pcall(wm.GetCanvasScale, wm)
    local pinScale = (ok and canvasScale and canvasScale > 0) and (1 / canvasScale) or 1

    -- Pins sit above the map's strata, so the scroll frame no longer hides
    -- the ones panned out of view: skip those ourselves.
    local sc = wm.ScrollContainer
    local cs = canvas:GetEffectiveScale()
    local left, top = canvas:GetLeft(), canvas:GetTop()
    local function InView(fx, fy)
      if not (sc and left and top) then return true end
      local ss = sc:GetEffectiveScale()
      local sl, sr, st, sb = sc:GetLeft(), sc:GetRight(), sc:GetTop(), sc:GetBottom()
      if not (sl and sr and st and sb) then return true end
      local x, y = (left + fx * cw) * cs, (top - fy * ch) * cs
      return x >= sl * ss and x <= sr * ss and y <= st * ss and y >= sb * ss
    end

    for _, r in ipairs(visible) do
      local fmap, fx, fy = ns.Members:Position(r, now)
      if fmap and mapID then fx, fy = Geo.ToMap(fmap, fx, fy, mapID) else fx = nil end
      if fx and fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 and InView(fx, fy) then
        local pin = worldPins[r.tag]
        if not pin then
          pin = MakePin(canvas, 18, true)
          worldPins[r.tag] = pin
        end
        if pin:GetParent() ~= canvas then pin:SetParent(canvas) end
        -- On zone maps other map layers (quest areas, overlays) are drawn over
        -- the canvas's own children: put pins one strata above the map itself.
        local strata = StrataAbove(wm:GetFrameStrata())
        if pin:GetFrameStrata() ~= strata then pin:SetFrameStrata(strata) end
        pin:SetScale(pinScale)
        Paint(pin, r, r.live)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", canvas, "TOPLEFT", fx * cw / pinScale, -fy * ch / pinScale)
        pin:Show()
        shown[r.tag] = true
      end
    end
  end
  for tag, pin in pairs(worldPins) do
    if not shown[tag] then pin:Hide() end
  end
end

---------------------------------------------------------------------------
-- Friends who are also in your real party/raid already get Blizzard's own
-- map and minimap markers: don't draw a second one for them.
---------------------------------------------------------------------------
local grouped = {}   -- lowercased "Name" and "Name-Realm" of your group members

local function RefreshGroup()
  wipe(grouped)
  local n = Call(GetNumGroupMembers) or 0
  if n == 0 then return end
  local prefix = Call(IsInRaid) and "raid" or "party"
  for i = 1, n do
    local name, realm = Call(UnitName, prefix .. i)
    if name and name ~= "" then
      grouped[name:lower()] = true
      if realm and realm ~= "" then grouped[(name .. "-" .. realm):lower()] = true end
    end
  end
end

function Geo.InMyGroup(r)
  return r.name ~= nil and grouped[r.name:lower()] == true
end

ns:On("GROUP_ROSTER_UPDATE", RefreshGroup)
ns:On("PLAYER_ENTERING_WORLD", RefreshGroup)

---------------------------------------------------------------------------
local elapsed = 0
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed < 1 / 30 then return end
  elapsed = 0
  if not ns.db then return end
  local now = GetTime()
  local visible = {}
  for _, r in ipairs(ns.Members:Visible()) do
    if not Geo.InMyGroup(r) then visible[#visible + 1] = r end
  end
  local ok, err = pcall(UpdateMinimap, visible, now)
  if not ok then ns.Debug("minimap pins:", err) end
  ok, err = pcall(UpdateWorldMap, visible, now)
  if not ok then ns.Debug("world map pins:", err) end
end)
