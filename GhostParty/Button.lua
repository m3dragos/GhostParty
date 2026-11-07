local _, ns = ...

-- Minimap button: left-click shows/hides the roster, right-click
-- stops/starts sharing, drag to move it around the minimap's edge.
local B = {}
ns.Button = B

local ICON = "Interface\\Icons\\Ability_Vanish"
local button

local function Place()
  local angle = math.rad(ns.db.buttonAngle or 215)
  local radius = Minimap:GetWidth() / 2 + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursor()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  ns.db.buttonAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
  Place()
end

local function ShowTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText(ns.NAME, 0.62, 0.85, 1)
  if ns.db.sharing then
    GameTooltip:AddLine("Sharing your position", 0.3, 1, 0.3)
  else
    GameTooltip:AddLine("Sharing stopped", 1, 0.3, 0.3)
  end
  GameTooltip:AddLine(ns.db.showFrames and "Roster shown" or "Roster hidden", 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Left-click", ns.db.showFrames and "Hide roster" or "Show roster", 1, 1, 1, 1, 0.82, 0)
  GameTooltip:AddDoubleLine("Right-click", ns.db.sharing and "Stop sharing" or "Start sharing", 1, 1, 1, 1, 0.82, 0)
  GameTooltip:AddDoubleLine("Drag", "Move button", 1, 1, 1, 1, 0.82, 0)
  GameTooltip:Show()
end

local function Build()
  button = CreateFrame("Button", "GhostPartyMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)

  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetTexture(ICON)
  button.icon:SetSize(18, 18)
  button.icon:SetPoint("TOPLEFT", 7, -6)
  button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local mask = button:CreateMaskTexture()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  mask:SetAllPoints(button.icon)
  button.icon:AddMaskTexture(mask)

  local ring = button:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetSize(53, 53)
  ring:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(self, mouse)
    if mouse == "RightButton" then
      ns.SetSharing(not ns.db.sharing)
    else
      ns.SetFramesShown(not ns.db.showFrames)
    end
    if GameTooltip:IsOwned(self) then ShowTooltip(self) end
  end)
  button:SetScript("OnDragStart", function(self)
    GameTooltip_Hide()
    self:SetScript("OnUpdate", FollowCursor)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", ShowTooltip)
  button:SetScript("OnLeave", GameTooltip_Hide)

  Place()
end

function B:Update()
  if not button then return end
  button:SetShown(not ns.db.hideButton)
  -- Greyed out and tinted red while sharing is stopped.
  button.icon:SetDesaturated(not ns.db.sharing)
  if ns.db.sharing then
    button.icon:SetVertexColor(1, 1, 1)
  else
    button.icon:SetVertexColor(1, 0.45, 0.45)
  end
  button.icon:SetAlpha(ns.db.showFrames and 1 or 0.6)
end

ns:On("PLAYER_LOGIN", function()
  if not Minimap then return end
  Build()
  B:Update()
end)
