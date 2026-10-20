--[[
    Chess Craft - UI/EmblemPicker.lua
    "Choose an emblem" window for the player card: chess pieces, faction
    crests, class icons and race portraits, laid out in the same gold
    dialog frame as the rest of Chess Craft.
]]

local _, ns = ...
local Theme, W = ns.Theme, ns.Widgets
local C = Theme.COLORS

local EmblemPicker = {}
ns.EmblemPicker = EmblemPicker

local PER_ROW = 8
local CELL = 44
local GAP = 5
local WIDTH = PER_ROW * (CELL + GAP) - GAP + 40

EmblemPicker.SetEmblemTexture = Theme.SetEmblem

function EmblemPicker:Build()
    if self.frame then return self.frame end
    local P = ns.Profile
    local f = CreateFrame("Frame", "ChessCraftEmblemPicker", UIParent, "BackdropTemplate")
    f:SetBackdrop(Theme.Backdrop())
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        EmblemPicker.moved = true
    end)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    f:Hide()
    self.frame = f
    if UISpecialFrames then table.insert(UISpecialFrames, "ChessCraftEmblemPicker") end

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("TOPLEFT", 16, -14)
    icon:SetTexture(Theme.ICON)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 7, 0)
    title:SetText("Choose an emblem")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() f:Hide() end)

    self.buttons = {}
    local y = -46
    for _, group in ipairs(P.EMBLEM_GROUPS) do
        local list = {}
        for _, em in ipairs(P.EMBLEMS) do
            if em.group == group and Theme.EmblemAvailable(em) then list[#list + 1] = em end
        end
        if #list > 0 then
            local header = W.Label(f, group, "GameFontNormal")
            header:SetPoint("TOPLEFT", 20, y)
            y = y - 18
            for i, em in ipairs(list) do
                local col = (i - 1) % PER_ROW
                if i > 1 and col == 0 then y = y - (CELL + GAP) end
                local b = CreateFrame("Button", nil, f, "BackdropTemplate")
                b:SetSize(CELL, CELL)
                b:SetPoint("TOPLEFT", 20 + col * (CELL + GAP), y)
                b:SetBackdrop(Theme.FlatBackdrop())
                b.tex = b:CreateTexture(nil, "ARTWORK")
                b.tex:SetPoint("TOPLEFT", 3, -3)
                b.tex:SetPoint("BOTTOMRIGHT", -3, 3)
                EmblemPicker.SetEmblemTexture(b.tex, em)
                b.hl = b:CreateTexture(nil, "HIGHLIGHT")
                b.hl:SetAllPoints()
                b.hl:SetColorTexture(1, 1, 1, 0.10)
                b.id = em.id
                b:SetScript("OnClick", function()
                    ns.Compat.PlaySound("click")
                    P:Customize("emblem", em.id)
                    EmblemPicker:Refresh()
                end)
                W.Tooltip(b, em.label)
                self.buttons[#self.buttons + 1] = b
            end
            y = y - (CELL + GAP) - 6
        end
    end
    local done = W.Button(f, "Done", 110, 22, function() f:Hide() end)
    done:SetPoint("BOTTOM", 0, 18)
    f:SetSize(WIDTH, -y + 52)
    f:SetScript("OnShow", function() EmblemPicker:Refresh() end)
    return f
end

function EmblemPicker:Show()
    local f = self:Build()
    if not f:IsShown() and not self.moved then
        -- open beside your card on the Profile tab so you can see each pick on it
        local card = ns.ProfileTab and ns.ProfileTab.card
        f:ClearAllPoints()
        if card and card:IsVisible() then
            f:SetPoint("LEFT", card, "RIGHT", 16, 0)
        else
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
        end
    end
    f:Show()
    f:Raise()
end

function EmblemPicker:Refresh()
    if not self.frame then return end
    local current = ns.Profile:Data().emblem
    for _, b in ipairs(self.buttons) do
        if b.id == current then
            b:SetBackdropColor(0.42, 0.33, 0.12, 0.95)
            b:SetBackdropBorderColor(1, 0.82, 0, 1)
        else
            b:SetBackdropColor(0.10, 0.09, 0.08, 0.92)
            b:SetBackdropBorderColor(0.45, 0.38, 0.25, 0.9)
        end
    end
end

return EmblemPicker
