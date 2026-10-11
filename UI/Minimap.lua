--[[
    Chess Craft - UI/Minimap.lua
    Minimap button: left-click opens the board, right-click opens settings,
    drag it around the minimap edge. It glows when a live opponent is
    waiting for your move or a challenge is waiting for an answer.
    (The game's addon compartment entry is set up in the TOC.)
]]

local _, ns = ...
local Theme = ns.Theme

local MinimapButton = ns:NewModule("MinimapButton")

local function minimapRadius()
    local w = Minimap and Minimap:GetWidth() or 140
    return (w / 2) + 10
end

function MinimapButton:UpdatePosition()
    local b = self.button
    if not b then return end
    local angle = math.rad(ns.db.global.minimap.angle or 205)
    local r = minimapRadius()
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

function MinimapButton:Create()
    if self.button or not Minimap then return self.button end
    local b = CreateFrame("Button", "ChessCraftMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER", 0, 0)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(Theme.ICON)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- attention glow
    local glow = b:CreateTexture(nil, "OVERLAY", nil, 1)
    glow:SetSize(44, 44)
    glow:SetPoint("CENTER", 0, 0)
    glow:SetTexture(Theme.GLOW)
    glow:SetVertexColor(1, 0.82, 0.1, 1)
    glow:SetBlendMode("ADD")
    glow:Hide()
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local alpha = pulse:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.15)
    alpha:SetToAlpha(0.9)
    alpha:SetDuration(0.7)
    b.glow, b.pulse = glow, pulse

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ns.UI:Show("settings")
        else
            ns.UI:Toggle()
        end
    end)
    b:SetScript("OnEnter", function(self) ns.UI:ShowSummaryTooltip(self) end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            if not mx then return end
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            local angle = math.deg(math.atan2(py - my, px - mx)) % 360
            ns.db.global.minimap.angle = math.floor(angle * 10 + 0.5) / 10
            MinimapButton:UpdatePosition()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
    end)

    self.button = b
    self:UpdatePosition()
    return b
end

function MinimapButton:Refresh()
    if ns.db.global.minimap.hide then
        if self.button then self.button:Hide() end
        return
    end
    self:Create()
    if self.button then
        self.button:Show()
        self:UpdatePosition()
        self:UpdateAttention()
    end
end

-- glow while a live opponent waits for us or a challenge is waiting
function MinimapButton:UpdateAttention()
    local b = self.button
    if not b then return end
    local want = false
    local live = ns.Live and ns.Live.game
    if live and not live.result and live.board.side == live.localColor then want = true end
    if #ns.Challenge:ListIncoming() > 0 then want = true end
    if want then
        b.glow:Show()
        if not b.pulse:IsPlaying() then b.pulse:Play() end
    else
        b.pulse:Stop()
        b.glow:Hide()
    end
end

function MinimapButton:OnEnable()
    self:Refresh()
    ns:On("MINIMAP_SETTING_CHANGED", function() MinimapButton:Refresh() end)
end

return MinimapButton
