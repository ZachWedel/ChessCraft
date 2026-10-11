--[[
    Chess Craft - UI/Lobby.lua
    The "Play" tab, laid out like Peggle's menu: the bot roster with saved
    games on the left, challenging other players on the right (name box,
    time control, color, incoming challenges and Chess Craft players seen
    in your guild, group and friends list).
]]

local _, ns = ...
local Theme, W, Compat, Names = ns.Theme, ns.Widgets, ns.Compat, ns.Names
local C = Theme.COLORS

local Lobby = {}
ns.Lobby = Lobby

local LEFT_W = 380
local RIGHT_X = 400
local RIGHT_W = 384
local CARD_W, CARD_H = 188, 48

local COLOR_OPTIONS = {
    { value = "white", label = "White" },
    { value = "random", label = "Random" },
    { value = "black", label = "Black" },
}

local function dim(text) return Theme.ColorText(text, C.dim) end

local function record(stats)
    if not stats then return "" end
    return string.format("%d-%d-%d", stats.w or 0, stats.l or 0, stats.d or 0)
end

-- construction ---------------------------------------------------------------------------
function Lobby:Build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    self.frame = f
    self.botColor = ns.db.char.lastColor or "random"
    if self.botColor ~= "white" and self.botColor ~= "black" then self.botColor = "random" end
    self.challengeColor = "random"
    self.selectedLevel = ns.db.char.lastBot or 3
    self.tcKey = ns.db.char.lastTimeControl or "5+3"

    self:BuildBots(f)
    self:BuildPlayers(f)

    f:SetScript("OnShow", function()
        ns.Presence:Announce(false)
        ns.Presence:PingFriends(false)
        Lobby:Refresh()
    end)
    return f
end

function Lobby:BuildBots(f)
    local header = W.Header(f, "Play the bots")
    header:SetPoint("TOPLEFT", 2, -2)
    local sub = W.Label(f, "Pause or close any time: games save after every move.", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 2, -24)
    sub:SetWidth(LEFT_W)
    sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    self.botCards = {}
    for i, p in ipairs(ns.Bots.list) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local card = CreateFrame("Button", nil, f, "BackdropTemplate")
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", col * (CARD_W + 4), -44 - row * (CARD_H + 4))
        card:SetBackdrop(Theme.FlatBackdrop())
        card.icon = W.Icon(card, 38)
        card.icon:SetPoint("LEFT", 5, 0)
        Compat.SetTextureFromList(card.icon.tex, p.icon)
        card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 6, -2)
        card.name:SetWidth(CARD_W - 52)
        card.name:SetJustifyH("LEFT")
        card.name:SetWordWrap(false)
        card.name:SetText(p.name)
        card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.sub:SetPoint("BOTTOMLEFT", card.icon, "BOTTOMRIGHT", 6, 2)
        card.sub:SetJustifyH("LEFT")
        card.sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        card.rec = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.rec:SetPoint("BOTTOMRIGHT", -6, 6)
        card.hl = card:CreateTexture(nil, "HIGHLIGHT")
        card.hl:SetPoint("TOPLEFT", 2, -2)
        card.hl:SetPoint("BOTTOMRIGHT", -2, 2)
        card.hl:SetColorTexture(1, 1, 1, 0.07)
        card.level = p.level
        card:SetScript("OnClick", function()
            Compat.PlaySound("click")
            Lobby.selectedLevel = p.level
            Lobby:RefreshBots()
        end)
        card:SetScript("OnDoubleClick", function()
            Lobby.selectedLevel = p.level
            Lobby:StartBotGame()
        end)
        self.botCards[i] = card
    end

    -- details of the selected bot
    local detail = W.Panel(f)
    detail:SetPoint("TOPLEFT", 0, -254)
    detail:SetSize(LEFT_W, 86)
    detail.name = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detail.name:SetPoint("TOPLEFT", 10, -9)
    detail.blurb = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail.blurb:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -4)
    detail.blurb:SetWidth(LEFT_W - 20)
    detail.blurb:SetJustifyH("LEFT")
    local playAs = W.Label(detail, "Play as", "GameFontNormalSmall")
    playAs:SetPoint("BOTTOMLEFT", 10, 12)
    detail.color = W.Segmented(detail, COLOR_OPTIONS,
        function() return Lobby.botColor end,
        function(v) Lobby.botColor = v end, 60, 20)
    detail.color:SetPoint("BOTTOMLEFT", 58, 9)
    detail.play = W.Button(detail, "Play", 96, 24, function() Lobby:StartBotGame() end)
    detail.play:SetPoint("BOTTOMRIGHT", -8, 7)
    self.detail = detail

    -- saved games
    local savedHeader = W.Label(f, "Saved games", "GameFontNormal")
    savedHeader:SetPoint("TOPLEFT", 2, -348)
    self.savedHeader = savedHeader
    self.savedEmpty = W.Label(f, "", "GameFontDisableSmall")
    self.savedEmpty:SetPoint("TOPLEFT", 4, -372)

    self.savedList = W.ScrollList(f, LEFT_W - 26, 92, 30, function(content)
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(30)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetPoint("TOPLEFT", 0, -1)
        row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 3, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 7, -1)
        row.name:SetPoint("RIGHT", -104, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 7, 1)
        row.text:SetPoint("RIGHT", -104, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.text:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        row.delete = W.FlatButton(row, "X", 22, 20, function()
            local id = row.gameId
            ns.Dialogs:Confirm("delete-" .. tostring(id), "Delete saved game?",
                "Delete this saved game? This cannot be undone.", "Delete",
                function() ns.BotGame:Delete(id) end, ns.UI.frame)
        end)
        row.delete:SetPoint("RIGHT", -1, 0)
        W.Tooltip(row.delete, "Delete this saved game")
        row.resume = W.FlatButton(row, "Resume", 72, 20, function()
            Lobby:ResumeBotGame(row.gameId)
        end)
        row.resume:SetPoint("RIGHT", row.delete, "LEFT", -4, 0)
        return row
    end, function(row, t)
        row.gameId = t.id
        local botId = t.extra and t.extra.botId
        local p = ns.Bots.Get(botId or 1)
        if p then Compat.SetTextureFromList(row.icon, p.icon) end
        local plies = 0
        for _ in tostring(t.moves or ""):gmatch("%S+") do plies = plies + 1 end
        local open = ns.BotGame.game and ns.BotGame.game.id == t.id
        row.name:SetText(p and p.name or "Bot")
        local text = string.format("You play %s · move %d · %s", Theme.Side(t.localColor or 1).name,
            math.floor(plies / 2) + 1, W.TimeAgo(t.updatedAt))
        if t.extra and t.extra.paused then text = text .. " · " .. Theme.ColorText("paused", C.warn) end
        row.text:SetText(text)
        row.resume:SetLabel(open and "Open" or "Resume")
    end)
    self.savedList:SetPoint("TOPLEFT", 0, -368)
end

function Lobby:BuildPlayers(f)
    local header = W.Header(f, "Challenge a player")
    header:SetPoint("TOPLEFT", RIGHT_X, -2)
    local sub = W.Label(f, "Your opponent needs Chess Craft too.", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", RIGHT_X, -24)
    sub:SetWidth(RIGHT_W)
    sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    local nameLabel = W.Label(f, "Player", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", RIGHT_X, -52)
    local edit = W.EditBox(f, 230, function() Lobby:SendChallenge() end)
    edit:SetPoint("TOPLEFT", RIGHT_X + 6, -66)
    self.nameBox = edit
    local useTarget = W.Button(f, "Use target", 104, 22, function()
        local name = Names.FromUnit("target")
        if name then
            edit:SetText(Names.Display(name))
        else
            ns.Print("Target a player first.")
        end
    end, "Use target", "Fill in the name of the player you have targeted.")
    useTarget:SetPoint("LEFT", edit, "RIGHT", 10, 0)

    local tcLabel = W.Label(f, "Time control (minutes + seconds added per move)", "GameFontNormalSmall")
    tcLabel:SetPoint("TOPLEFT", RIGHT_X, -98)
    self.tcButtons = {}
    for i, tc in ipairs(ns.Challenge.TIME_CONTROLS) do
        local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
        local label = (tc.key == "inf") and "Untimed" or tc.key
        local b = W.FlatButton(f, label, 74, 20, function()
            Lobby.tcKey = tc.key
            ns.db.char.lastTimeControl = tc.key
            Lobby:RefreshTimeControls()
        end)
        b:SetPoint("TOPLEFT", RIGHT_X + col * 77, -112 - row * 23)
        b.key = tc.key
        W.Tooltip(b, tc.label, (tc.key == "inf")
            and "No clock. The game is saved and continues whenever you are both online. Leaving early aborts it; leaving after both sides moved counts as a loss."
            or "If a player disconnects, the clock keeps running; after 60 seconds of silence the other player may claim the win or keep waiting.")
        self.tcButtons[i] = b
    end

    local playAs = W.Label(f, "Play as", "GameFontNormalSmall")
    playAs:SetPoint("TOPLEFT", RIGHT_X, -166)
    self.challengeColorSeg = W.Segmented(f, COLOR_OPTIONS,
        function() return Lobby.challengeColor end,
        function(v) Lobby.challengeColor = v end, 60, 20)
    self.challengeColorSeg:SetPoint("TOPLEFT", RIGHT_X + 48, -163)
    self.sendButton = W.Button(f, "Send challenge", 134, 24, function() Lobby:SendChallenge() end)
    self.sendButton:SetPoint("TOPRIGHT", f, "TOPLEFT", RIGHT_X + RIGHT_W, -161)

    -- outgoing challenge
    local out = W.Panel(f)
    out:SetPoint("TOPLEFT", RIGHT_X, -194)
    out:SetSize(RIGHT_W, 30)
    out.text = out:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    out.text:SetPoint("LEFT", 10, 0)
    out.text:SetPoint("RIGHT", -86, 0)
    out.text:SetJustifyH("LEFT")
    out.text:SetWordWrap(false)
    out.cancel = W.Button(out, "Cancel", 72, 20, function() ns.Challenge:Cancel() end)
    out.cancel:SetPoint("RIGHT", -6, 0)
    self.outgoing = out

    -- incoming challenges
    local inHeader = W.Label(f, "Challenges for you", "GameFontNormal")
    inHeader:SetPoint("TOPLEFT", RIGHT_X, -232)
    self.incomingEmpty = W.Label(f, "", "GameFontDisableSmall")
    self.incomingEmpty:SetPoint("TOPLEFT", RIGHT_X + 2, -252)
    self.incomingRows = {}
    for i = 1, 2 do
        local row = W.Panel(f)
        row:SetPoint("TOPLEFT", RIGHT_X, -250 - (i - 1) * 30)
        row:SetSize(RIGHT_W, 28)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 10, 0)
        row.text:SetPoint("RIGHT", -150, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.decline = W.Button(row, "Decline", 68, 20, function()
            if row.cid then ns.Challenge:Decline(row.cid, "declined") end
        end)
        row.decline:SetPoint("RIGHT", -5, 0)
        row.accept = W.Button(row, "Accept", 68, 20, function()
            if row.cid then ns.Challenge:Accept(row.cid) end
        end)
        row.accept:SetPoint("RIGHT", row.decline, "LEFT", -4, 0)
        row:Hide()
        self.incomingRows[i] = row
    end

    -- players seen with the addon
    local pHeader = W.Label(f, "Chess Craft players nearby", "GameFontNormal")
    pHeader:SetPoint("TOPLEFT", RIGHT_X, -316)
    local refresh = W.FlatButton(f, "Refresh", 64, 18, function()
        ns.Presence:Announce(true)
        ns.Presence:PingFriends(true)
    end)
    refresh:SetPoint("TOPRIGHT", f, "TOPLEFT", RIGHT_X + RIGHT_W, -314)
    W.Tooltip(refresh, "Refresh", "Ask your guild, group and online friends who has Chess Craft.")
    self.playersEmpty = W.Label(f, "", "GameFontDisableSmall")
    self.playersEmpty:SetPoint("TOPLEFT", RIGHT_X + 2, -340)
    self.playersEmpty:SetWidth(RIGHT_W - 4)
    self.playerList = W.ScrollList(f, RIGHT_W - 26, 104, 26, function(content)
        local row = CreateFrame("Button", nil, content)
        row:SetHeight(26)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.06)
        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(10, 10)
        row.dot:SetPoint("LEFT", 6, 0)
        row.dot:SetTexture(Theme.DOT)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.dot, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", -96, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.challenge = W.Button(row, "Challenge", 88, 20, function()
            if row.playerName then
                Lobby.nameBox:SetText(Names.Display(row.playerName))
                Lobby:SendChallenge(row.playerName)
            end
        end)
        row.challenge:SetPoint("RIGHT", -2, 0)
        row:SetScript("OnClick", function()
            if row.playerName then Lobby.nameBox:SetText(Names.Display(row.playerName)) end
        end)
        return row
    end, function(row, p)
        row.playerName = p.name
        local idle = p.status == "idle"
        if idle then row.dot:SetVertexColor(C.good[1], C.good[2], C.good[3], 1)
        else row.dot:SetVertexColor(C.warn[1], C.warn[2], C.warn[3], 1) end
        local where = ({ guild = "guild", group = "group", friend = "friend", reply = "guild", direct = "" })[p.source or ""] or ""
        local status = idle and "" or (" " .. Theme.ColorText("(in a game)", C.warn))
        local extra = (where ~= "") and dim(" · " .. where) or ""
        row.text:SetText(Names.Display(p.name) .. extra .. status)
        local ok = ns.Challenge:CanChallenge()
        row.challenge:SetEnabled(ok and idle and p.proto == ns.PROTOCOL)
    end)
    self.playerList:SetPoint("TOPLEFT", RIGHT_X, -336)

    self.notice = W.Label(f, "", "GameFontHighlightSmall")
    self.notice:SetPoint("BOTTOMLEFT", RIGHT_X, 2)
    self.notice:SetWidth(RIGHT_W)
end

-- actions ----------------------------------------------------------------------------------------
function Lobby:StartBotGame()
    local g = ns.BotGame:StartNew(self.selectedLevel, self.botColor)
    if g then ns.UI:ShowTab("game") end
end

function Lobby:ResumeBotGame(id)
    local g = ns.BotGame:Resume(id)
    if g then ns.UI:ShowTab("game") end
end

function Lobby:SendChallenge(name)
    name = name or self.nameBox:GetText()
    if not name or name:match("^%s*$") then
        ns.Print("Enter the name of the player you want to challenge.")
        return
    end
    local tc = ns.Challenge.ParseTimeControl(self.tcKey)
    if tc == nil then tc = false end
    if ns.Challenge:SendTo(name, tc, self.challengeColor) then
        self.nameBox:ClearFocus()
    end
end

-- refresh ------------------------------------------------------------------------------------------
function Lobby:Refresh()
    if not self.frame or not self.frame:IsVisible() then return end
    self:RefreshBots()
    self:RefreshSaved()
    self:RefreshTimeControls()
    self:RefreshChallenges()
    self:RefreshPlayers()
end

function Lobby:RefreshBots()
    if not self.frame then return end
    local stats = ns.db.char.stats.bots
    for _, card in ipairs(self.botCards) do
        local p = ns.Bots.Get(card.level)
        local sel = card.level == self.selectedLevel
        if sel then
            card:SetBackdropColor(0.30, 0.24, 0.10, 0.95)
            card:SetBackdropBorderColor(1, 0.82, 0, 1)
        else
            card:SetBackdropColor(0.10, 0.09, 0.08, 0.92)
            card:SetBackdropBorderColor(0.45, 0.38, 0.25, 0.9)
        end
        card.sub:SetText(string.format("Level %d · ~%d", p.level, p.rating))
        local s = stats[p.id]
        card.rec:SetText((s and (s.w + s.l + s.d) > 0) and record(s) or "")
        if s and s.w > 0 then card.rec:SetTextColor(C.good[1], C.good[2], C.good[3]) else card.rec:SetTextColor(C.dim[1], C.dim[2], C.dim[3]) end
    end
    local p = ns.Bots.Get(self.selectedLevel)
    local d = self.detail
    d.name:SetText(string.format("%s  %s", p.name, dim(string.format("level %d, plays like ~%d", p.level, p.rating))))
    d.blurb:SetText(p.blurb)
    d.color:Refresh()
    local liveBusy = ns.Live:IsActive()
    d.play:SetEnabled(not liveBusy)
    if liveBusy then
        W.Tooltip(d.play, "Live game in progress", "Finish or leave your live game first.")
    else
        W.Tooltip(d.play, "Play", "Start a new game against " .. p.name .. ". Any game in progress stays saved.")
    end
end

function Lobby:RefreshSaved()
    if not self.frame then return end
    local list = ns.Database.ListBotGames()
    self.savedList:SetItems(list)
    self.savedHeader:SetText("Saved games" .. ((#list > 0) and dim(" (" .. #list .. ")") or ""))
    self.savedEmpty:SetText(#list == 0 and "No saved games. Start one above; it is saved after every move." or "")
end

function Lobby:RefreshTimeControls()
    if not self.frame then return end
    for _, b in ipairs(self.tcButtons) do b:SetSelected(b.key == self.tcKey) end
end

function Lobby:RefreshChallenges()
    if not self.frame then return end
    local canChallenge, why = ns.Challenge:CanChallenge()
    self.sendButton:SetEnabled(canChallenge)
    self.challengeColorSeg:Refresh()

    local o = ns.Challenge.outgoing
    if o then
        self.outgoing:Show()
        self.outgoing.text:SetText(string.format("Waiting for %s to answer (%s)...",
            Names.Display(o.target), ns.Challenge.Describe(o.tc)))
    else
        self.outgoing:Hide()
    end

    local incoming = ns.Challenge:ListIncoming()
    for i, row in ipairs(self.incomingRows) do
        local c = incoming[i]
        if c then
            row.cid = c.id
            local accepted = c.state == "accepted"
            row.text:SetText(string.format("%s · %s · you play %s", Names.Display(c.from), ns.Challenge.Describe(c.tc),
                Theme.Side(c.myColor).name) .. (accepted and dim(" (starting...)") or ""))
            row.accept:SetEnabled(not accepted and not ns.Live:IsActive())
            row.decline:SetEnabled(not accepted)
            row:Show()
        else
            row.cid = nil
            row:Hide()
        end
    end
    local extra = #incoming - #self.incomingRows
    if #incoming == 0 then
        self.incomingEmpty:SetText("No challenges right now.")
    elseif extra > 0 then
        self.incomingEmpty:SetText("")
    else
        self.incomingEmpty:SetText("")
    end

    -- notices at the bottom of the column
    local notice
    if not canChallenge and why then
        notice = Theme.ColorText(why, C.warn)
    end
    local newest = ns.db.global.newestVersionSeen
    if newest and Compat.CompareVersions(newest, ns.version) > 0 then
        local v = string.format("Chess Craft %s is available (you have %s).", newest, ns.version)
        notice = notice and (notice .. "\n" .. v) or Theme.ColorText(v, C.gold)
    end
    self.notice:SetText(notice or "")
end

function Lobby:RefreshPlayers()
    if not self.frame then return end
    local list = ns.Presence:List()
    self.playerList:SetItems(list)
    if #list == 0 then
        self.playersEmpty:SetText("Nobody found yet. Guildmates, group members and online friends with Chess Craft show up here. You can always type a name above.")
    else
        self.playersEmpty:SetText("")
    end
end

return Lobby
