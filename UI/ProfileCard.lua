--[[
    Chess Craft - UI/ProfileCard.lua
    The player card: a gold-framed dialog-style card with a strip of the
    player's chosen board, their emblem, name and title, rating (with peak),
    record, best bot beaten and motto. Used on the Profile tab and as a
    small pop-up window when you look at someone else's card.
]]

local _, ns = ...
local Theme, W, Compat, Names, Rating = ns.Theme, ns.Widgets, ns.Compat, ns.Names, ns.Rating
local C = Theme.COLORS

local ProfileCard = {}
ns.ProfileCard = ProfileCard

local CARD_W, CARD_H = 260, 372
local BAND_H = 64
ProfileCard.WIDTH, ProfileCard.HEIGHT = CARD_W, CARD_H

local function dim(text) return Theme.ColorText(text, C.dim) end

function ProfileCard.Create(parent, name)
    local card = CreateFrame("Frame", name, parent, "BackdropTemplate")
    card:SetSize(CARD_W, CARD_H)
    card:SetBackdrop(Theme.Backdrop())

    -- strip of the player's board style across the top
    local band = CreateFrame("Frame", nil, card)
    band:SetPoint("TOPLEFT", 12, -12)
    band:SetPoint("TOPRIGHT", -12, -12)
    band:SetHeight(BAND_H)
    band.squares = {}
    local cols, rows = 8, 2
    local sw = (CARD_W - 24) / cols
    local sh = BAND_H / rows
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local t = band:CreateTexture(nil, "BACKGROUND")
            t:SetPoint("TOPLEFT", c * sw, -r * sh)
            t:SetSize(sw, sh)
            t.light = (c + r) % 2 == 0
            t.col, t.row = c, r
            band.squares[#band.squares + 1] = t
        end
    end
    band.shade = band:CreateTexture(nil, "BORDER")
    band.shade:SetAllPoints()
    band.shade:SetColorTexture(0, 0, 0, 0.30)
    band.edge = band:CreateTexture(nil, "ARTWORK")
    band.edge:SetPoint("BOTTOMLEFT")
    band.edge:SetPoint("BOTTOMRIGHT")
    band.edge:SetHeight(2)
    card.band = band

    card.emblem = W.Icon(card, 60)
    card.emblem:SetPoint("CENTER", band, "BOTTOM", 0, 0)
    card.emblem:SetFrameLevel(band:GetFrameLevel() + 2)

    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    card.name:SetPoint("TOP", card.emblem, "BOTTOM", 0, -8)
    card.name:SetWidth(CARD_W - 30)
    card.name:SetWordWrap(false)
    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.title:SetPoint("TOP", card.name, "BOTTOM", 0, -3)
    card.title:SetWidth(CARD_W - 30)
    card.title:SetWordWrap(false)
    card.title:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    local line = card:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 26, -164)
    line:SetPoint("TOPRIGHT", -26, -164)
    line:SetHeight(1)
    line:SetColorTexture(C.panelBorder[1], C.panelBorder[2], C.panelBorder[3], 0.6)
    card.line = line

    card.ratingLabel = W.Label(card, "Rating", "GameFontNormalSmall", "CENTER")
    card.ratingLabel:SetPoint("TOP", line, "BOTTOM", 0, -8)
    card.rating = card:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    card.rating:SetPoint("TOP", card.ratingLabel, "BOTTOM", 0, -3)
    pcall(card.rating.SetFont, card.rating, "Fonts\\FRIZQT__.TTF", 30, "OUTLINE")
    card.peak = W.Label(card, "", "GameFontHighlightSmall", "CENTER")
    card.peak:SetPoint("TOP", card.rating, "BOTTOM", 0, -4)
    card.peak:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    card.record = W.Label(card, "", "GameFontHighlight", "CENTER")
    card.record:SetPoint("TOP", card.peak, "BOTTOM", 0, -10)
    card.record:SetWidth(CARD_W - 30)

    card.botIcon = card:CreateTexture(nil, "ARTWORK")
    card.botIcon:SetSize(18, 18)
    card.botIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    card.bot = W.Label(card, "", "GameFontHighlightSmall", "LEFT")
    card.bot:SetPoint("TOP", card.record, "BOTTOM", 10, -10)
    card.botIcon:SetPoint("RIGHT", card.bot, "LEFT", -5, 0)

    card.motto = W.Label(card, "", "GameFontHighlightSmall", "CENTER")
    card.motto:SetPoint("TOP", card.bot, "BOTTOM", -10, -12)
    card.motto:SetWidth(CARD_W - 44)
    card.motto:SetTextColor(0.95, 0.90, 0.76)

    card.footer = W.Label(card, ns.TITLE, "GameFontDisableSmall", "CENTER")
    card.footer:SetPoint("BOTTOM", 0, 16)

    card.SetCard = ProfileCard.SetCard
    card:SetCard(nil)
    return card
end

local function applyBand(band, backdropId, frameColor)
    local style = Theme.BOARDS[ns.Profile.Backdrop(backdropId).id] or Theme.BOARDS.wood
    for _, t in ipairs(band.squares) do
        local spec = t.light and style.light or style.dark
        if spec.tex then
            t:SetTexture(spec.tex)
            local u = ((t.col * 3 + t.row * 5) % 4) * 0.25
            t:SetTexCoord(u, u + 0.25, 0.25, 0.5)
        else
            t:SetColorTexture(spec.color[1], spec.color[2], spec.color[3], 1)
        end
    end
    band.edge:SetColorTexture(frameColor[1], frameColor[2], frameColor[3], 0.9)
end

-- c: card table from Profile:Mine() / Profile:Get(); nil shows a placeholder.
function ProfileCard.SetCard(card, c, nameIfUnknown)
    local P = ns.Profile
    local frame = P.Frame(c and c.frame)
    local fc = frame.color
    card:SetBackdropBorderColor(fc[1], fc[2], fc[3], 1)
    applyBand(card.band, c and c.backdrop or "wood", fc)
    card.emblem:SetBackdropBorderColor(fc[1], fc[2], fc[3], 1)

    local em = P.Emblem(c and c.emblem or "knight")
    Theme.SetEmblem(card.emblem.tex, em)

    if not c then
        card.name:SetText(nameIfUnknown and Names.Display(nameIfUnknown) or "")
        card.title:SetText("")
        card.rating:SetText("...")
        card.peak:SetText("Looking up this player's card...")
        card.record:SetText("")
        card.bot:SetText("")
        card.botIcon:Hide()
        card.motto:SetText("")
        return
    end

    card.name:SetText(Names.Display(c.name))
    card.title:SetText(c.title ~= "" and c.title or "")
    card.rating:SetText(Rating.Format(c.rating, c.games))
    if Rating.IsProvisional(c.games) then
        card.peak:SetText(string.format("Provisional: %d of %d games", c.games or 0, Rating.PROVISIONAL_GAMES))
    else
        card.peak:SetText("Peak " .. (c.peak or c.rating))
    end
    if (c.games or 0) == 0 then
        card.record:SetText(dim("No rated games yet"))
    else
        card.record:SetText(string.format("%s  %s  %s",
            Theme.ColorText(c.w .. " won", C.good), Theme.ColorText(c.l .. " lost", C.bad),
            Theme.ColorText(c.d .. " drawn", C.gold)))
    end
    local bot = (c.bestBot or 0) > 0 and ns.Bots.Get(c.bestBot) or nil
    if bot then
        Compat.SetTextureFromList(card.botIcon, bot.icon)
        card.botIcon:Show()
        card.bot:SetText("Has beaten the " .. bot.name)
    else
        card.botIcon:Hide()
        card.bot:SetText(dim("No bot victories yet"))
    end
    card.motto:SetText((c.motto and c.motto ~= "") and ("\"" .. c.motto .. "\"") or "")
end

-- Pop-up window showing another player's card -------------------------------------------------
function ProfileCard.ShowFor(name)
    if not name then return end
    local f = ProfileCard.popup
    if not f then
        f = ProfileCard.Create(UIParent, "ChessCraftProfileFrame")
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:SetMovable(true)
        f:SetDontSavePosition(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -5, -5)
        close:SetFrameLevel(f.band:GetFrameLevel() + 5)
        close:SetScript("OnClick", function() f:Hide() end)
        f:Hide()
        ProfileCard.popup = f
        if UISpecialFrames then table.insert(UISpecialFrames, "ChessCraftProfileFrame") end
        ns:On("PROFILE_CHANGED", function(who)
            if f:IsShown() and f.who and (who == nil or Names.Same(who, f.who)) then
                f:SetCard(ns.Profile:Get(f.who), f.who)
            end
        end)
    end
    f.who = name
    local c = ns.Profile:Get(name)
    f:SetCard(c, name)
    if not c or (c.at and ns.Clock.now() - c.at > 60) then ns.Profile:Request(name) end
    f:Show()
    f:Raise()
    Compat.PlaySound("click")
end

return ProfileCard
