--[[
    Chess Craft - UI/ProfileTab.lua
    The "Profile" tab: your card on the left, ways to customize it on the
    right (title, motto, emblem, frame, background), and how rating works.
]]

local _, ns = ...
local Theme, W, Names = ns.Theme, ns.Widgets, ns.Names
local C = Theme.COLORS

local ProfileTab = {}
ns.ProfileTab = ProfileTab

local RIGHT_X = 300
local RIGHT_W = 484

local function options(list, width)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = { value = e.id, label = e.label } end
    return out
end

function ProfileTab:Build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    self.frame = f
    local P = ns.Profile

    local header = W.Header(f, "Your card")
    header:SetPoint("TOPLEFT", 2, -2)
    self.card = ns.ProfileCard.Create(f)
    self.card:SetPoint("TOPLEFT", 6, -28)

    local h2 = W.Header(f, "Customize your card")
    h2:SetPoint("TOPLEFT", RIGHT_X, -2)
    local sub = W.Label(f, "Other Chess Craft players see this card when they look you up.", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", RIGHT_X, -24)
    sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    -- a short red note when typed text is refused
    self.warning = W.Label(f, "", "GameFontHighlightSmall")
    self.warning:SetPoint("TOPLEFT", RIGHT_X + 250, -50)
    self.warning:SetWidth(RIGHT_W - 254)
    self.warning:SetTextColor(C.bad[1], C.bad[2], C.bad[3])

    local function save(key, box)
        local ok, why = P:Customize(key, box:GetText())
        if ok then
            self.warning:SetText("")
        else
            if why then
                self.warning:SetText(why)
                ns.Print(why)
            end
            box:SetText(P:Data()[key] or "")
        end
    end
    local function textField(label, y, width, maxLetters, key)
        local l = W.Label(f, label, "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", RIGHT_X, y)
        local e
        e = W.EditBox(f, width, function() save(key, e) end)
        e:SetMaxLetters(maxLetters)
        e:SetPoint("TOPLEFT", RIGHT_X + 6, y - 14)
        e:SetScript("OnEditFocusLost", function(self) save(key, self) end)
        return e
    end
    self.titleBox = textField("Title (up to 24 letters)", -50, 230, 24, "title")
    self.mottoBox = textField("Motto (up to 60 letters)", -92, 420, 60, "motto")

    local emLabel = W.Label(f, "Emblem", "GameFontNormalSmall")
    emLabel:SetPoint("TOPLEFT", RIGHT_X, -136)
    -- current emblem, and a window with every choice (pieces, factions, classes, races)
    self.emblemIcon = W.Icon(f, 40)
    self.emblemIcon:SetPoint("TOPLEFT", RIGHT_X, -152)
    self.emblemName = W.Label(f, "", "GameFontHighlight")
    self.emblemName:SetPoint("LEFT", self.emblemIcon, "RIGHT", 10, 0)
    self.emblemName:SetWidth(150)
    self.chooseEmblem = W.Button(f, "Choose emblem...", 150, 24, function() ns.EmblemPicker:Show() end,
        "Choose emblem", "Chess pieces, faction crests, class icons and race portraits.")
    self.chooseEmblem:SetPoint("LEFT", self.emblemIcon, "RIGHT", 170, 0)

    local frLabel = W.Label(f, "Card frame", "GameFontNormalSmall")
    frLabel:SetPoint("TOPLEFT", RIGHT_X, -204)
    self.frameSeg = W.Segmented(f, options(P.FRAMES), function() return P:Data().frame end,
        function(v) P:Customize("frame", v) end, 86, 22)
    self.frameSeg:SetPoint("TOPLEFT", RIGHT_X, -220)

    local bgLabel = W.Label(f, "Card background", "GameFontNormalSmall")
    bgLabel:SetPoint("TOPLEFT", RIGHT_X, -252)
    self.bgSeg = W.Segmented(f, options(P.BACKDROPS), function() return P:Data().backdrop end,
        function(v) P:Customize("backdrop", v) end, 90, 22)
    self.bgSeg:SetPoint("TOPLEFT", RIGHT_X, -268)

    local info = W.Panel(f)
    info:SetPoint("TOPLEFT", RIGHT_X, -306)
    info:SetSize(RIGHT_W - 4, 150)
    local infoTitle = W.Label(info, "How rating works", "GameFontNormal")
    infoTitle:SetPoint("TOPLEFT", 12, -10)
    local infoText = W.Label(info,
        "Live games against other players are rated. Everyone starts at 1200. Beating a stronger player gains more "
        .. "than beating a weaker one, and your first games move your rating faster so you find your level quickly "
        .. "(it shows a ? until you have played 10).\n\nBot games never change your rating; your best bot win "
        .. "is shown on your card instead. Aborted games don't count.",
        "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", infoTitle, "BOTTOMLEFT", 0, -6)
    infoText:SetWidth(RIGHT_W - 30)
    infoText:SetJustifyV("TOP")

    f:SetScript("OnShow", function() ProfileTab:Refresh() end)
    ns:On("PROFILE_CHANGED", function(who)
        if who == nil or Names.IsMe(who) then ProfileTab:Refresh() end
    end)
    ns:On("GAME_ENDED", function() ProfileTab:Refresh() end)
    return f
end

function ProfileTab:Refresh()
    if not self.frame or not self.frame:IsVisible() then return end
    local P = ns.Profile
    local d = P:Data()
    self.card:SetCard(P:Mine())
    if not self.titleBox:HasFocus() then self.titleBox:SetText(d.title or "") end
    if not self.mottoBox:HasFocus() then self.mottoBox:SetText(d.motto or "") end
    local em = P.Emblem(d.emblem)
    ns.EmblemPicker.SetEmblemTexture(self.emblemIcon.tex, em)
    self.emblemName:SetText(em.label)
    self.frameSeg:Refresh()
    self.bgSeg:Refresh()
end

return ProfileTab
