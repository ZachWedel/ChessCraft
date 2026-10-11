--[[
    Chess Craft - UI/MainWindow.lua
    The Chess Craft window (Game / Play / History / Settings tabs), the
    PGN copy window, the summary tooltip, and the wiring that keeps every
    screen in step with the game logic's callbacks.
]]

local _, ns = ...
local Theme, W, Compat, Names = ns.Theme, ns.Widgets, ns.Compat, ns.Names
local C = Theme.COLORS

local UI = ns:NewModule("UI")

local WIDTH, HEIGHT = 812, 548
local CONTENT_W = WIDTH - 28
local TABS = {
    { key = "game", label = "Game" },
    { key = "play", label = "Play" },
    { key = "history", label = "History" },
    { key = "settings", label = "Settings" },
}

-- window ---------------------------------------------------------------------------------
function UI:Build()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "ChessCraftMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetBackdrop(Theme.Backdrop())
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI:SavePosition()
    end)
    f:SetScript("OnShow", function()
        Compat.PlaySound("finish")
        UI:RefreshTabs()
    end)
    f:SetScript("OnHide", function()
        if GameTooltip then GameTooltip:Hide() end
        Compat.PlaySound("IG_MAINMENU_CLOSE")
    end)
    f:Hide()
    self.frame = f
    if UISpecialFrames then table.insert(UISpecialFrames, "ChessCraftMainFrame") end

    -- title bar
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("TOPLEFT", 16, -13)
    icon:SetTexture(Theme.ICON)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(ns.TITLE)
    local version = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 6, 1)
    version:SetText("v" .. ns.version)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() UI:Hide() end)

    -- tabs
    self.tabButtons = {}
    for i, t in ipairs(TABS) do
        local b = W.FlatButton(f, t.label, 96, 24, function() UI:ShowTab(t.key) end)
        b:SetPoint("TOPLEFT", 16 + (i - 1) * 100, -42)
        b.key = t.key
        self.tabButtons[t.key] = b
    end
    self.headerStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.headerStatus:SetPoint("TOPRIGHT", -18, -48)
    self.headerStatus:SetJustifyH("RIGHT")

    -- pages
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", 14, -72)
    content:SetPoint("BOTTOMRIGHT", -14, 12)
    content:SetSize(CONTENT_W, HEIGHT - 84)
    self.content = content
    self.pages = {
        game = ns.GameView:Build(content),
        play = ns.Lobby:Build(content),
        history = ns.History:Build(content),
    }
    local settings = ns.SettingsUI.Build(content, CONTENT_W)
    settings.frame:SetPoint("TOPLEFT", 2, -4)
    self.pages.settings = settings.frame
    for _, page in pairs(self.pages) do page:Hide() end

    self:RestorePosition()
    f:SetScale(ns.db.settings.scale or 1)
    return f
end

function UI:SavePosition()
    local f = self.frame
    if not f then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    ns.db.global.window = { point = point, relPoint = relPoint, x = x, y = y }
end

function UI:RestorePosition()
    local f = self.frame
    local w = ns.db.global.window
    f:ClearAllPoints()
    if w and w.point and w.x and w.y then
        f:SetPoint(w.point, UIParent, w.relPoint or w.point, w.x, w.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

function UI:IsShown() return self.frame ~= nil and self.frame:IsShown() end

function UI:Show(tab)
    self:Build()
    tab = tab or self.tab
    if not tab or (tab == "game" and not ns.GameView:Game()) then
        tab = ns.GameView:Game() and "game" or "play"
    end
    self.frame:Show()
    self:ShowTab(tab)
end

function UI:Hide()
    if self.frame then self.frame:Hide() end
end

function UI:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
end

function UI:ShowTab(key)
    self:Build()
    if not self.pages[key] then key = "play" end
    self.tab = key
    if not self.frame:IsShown() then self.frame:Show() end
    for k, page in pairs(self.pages) do
        if k ~= key then page:Hide() end
    end
    self.pages[key]:Show()
    self:RefreshTabs()
end

function UI:RefreshTabs()
    if not self.frame then return end
    local incoming = #ns.Challenge:ListIncoming()
    for key, b in pairs(self.tabButtons) do
        b:SetSelected(key == self.tab)
        if key == "play" then
            b:SetLabel(incoming > 0 and ("Play " .. Theme.ColorText("(" .. incoming .. ")", C.good)) or "Play")
        elseif key == "game" then
            local g = ns.GameView:Game()
            local mine = g and not g.result and g:IsLocalTurn() and ns.GameView:Mode() == "live"
            b:SetLabel(mine and ("Game " .. Theme.ColorText("*", C.good)) or "Game")
        end
    end
    local players = #ns.Presence:List()
    local status = players > 0 and string.format("%d Chess Craft player%s nearby", players, players == 1 and "" or "s") or ""
    if Compat.IsTrial() then status = Theme.ColorText("Trial account: bots only", C.warn) end
    self.headerStatus:SetText(status)
end

-- PGN / copy window -------------------------------------------------------------------------
function UI:ShowCopyText(title, hint, text)
    local cf = self.copyFrame
    if not cf then
        cf = CreateFrame("Frame", "ChessCraftCopyFrame", UIParent, "BackdropTemplate")
        cf:SetSize(540, 360)
        cf:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        cf:SetFrameStrata("DIALOG")
        cf:SetToplevel(true)
        cf:SetClampedToScreen(true)
        cf:SetBackdrop(Theme.Backdrop())
        cf:EnableMouse(true)
        cf:SetMovable(true)
        cf:SetDontSavePosition(true)
        cf:RegisterForDrag("LeftButton")
        cf:SetScript("OnDragStart", function(self) self:StartMoving() end)
        cf:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        cf.title = W.Header(cf, "")
        cf.title:SetPoint("TOPLEFT", 22, -18)
        cf.hint = W.Label(cf, "", "GameFontHighlightSmall")
        cf.hint:SetPoint("TOPLEFT", 22, -42)
        cf.hint:SetWidth(490)
        local bg = W.Panel(cf)
        bg:SetPoint("TOPLEFT", 18, -62)
        bg:SetSize(500, 246)
        cf.box = W.CopyBox(bg, 466, 232)
        cf.box:SetPoint("TOPLEFT", 8, -7)
        cf.close = W.Button(cf, CLOSE or "Close", 110, 22, function() cf:Hide() end)
        cf.close:SetPoint("BOTTOM", 0, 18)
        local x = CreateFrame("Button", nil, cf, "UIPanelCloseButton")
        x:SetPoint("TOPRIGHT", -6, -6)
        x:SetScript("OnClick", function() cf:Hide() end)
        if UISpecialFrames then table.insert(UISpecialFrames, "ChessCraftCopyFrame") end
        self.copyFrame = cf
    end
    cf.title:SetText(title or "")
    cf.hint:SetText(hint or "")
    cf.box:SetCopyText(text or "")
    cf:Show()
    cf.box:Focus()
end

-- summary tooltip (minimap button, addon compartment) --------------------------------------
function UI:ShowSummaryTooltip(owner)
    if not GameTooltip or not owner then return end
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(ns.TITLE, 1, 0.82, 0)
    local Live, BotGame = ns.Live, ns.BotGame
    if Live:IsActive() then
        local g = Live.game
        local line = "Live game vs " .. Names.Display(Live.opp) .. ": " ..
            (g.board.side == g.localColor and "|cff5ae65ayour move|r" or "their move")
        if g.tc then line = line .. " (" .. W.FormatClock(g:Remaining(g.localColor)) .. " left)" end
        GameTooltip:AddLine(line, 1, 1, 1)
    elseif BotGame:IsActive() and BotGame.persona then
        local g = BotGame.game
        GameTooltip:AddLine(string.format("Bot game vs %s, move %d%s", BotGame.persona.name,
            math.floor(g:Ply() / 2) + 1, BotGame.paused and " (paused)" or ""), 1, 1, 1)
    end
    local saved = #ns.Database.ListBotGames()
    if saved > 0 then
        GameTooltip:AddLine(string.format("%d saved bot game%s", saved, saved == 1 and "" or "s"), 0.85, 0.85, 0.85)
    end
    local incoming = #ns.Challenge:ListIncoming()
    if incoming > 0 then
        GameTooltip:AddLine(string.format("%d challenge%s waiting", incoming, incoming == 1 and "" or "s"), 0.35, 0.9, 0.35)
    end
    local w, l, d = ns.Database.Totals()
    if w + l + d > 0 then
        GameTooltip:AddLine(string.format("Record: %d won, %d lost, %d drawn", w, l, d), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100Left-click:|r open or close", 0.9, 0.9, 0.9)
    GameTooltip:AddLine("|cffffd100Right-click:|r settings", 0.9, 0.9, 0.9)
    GameTooltip:Show()
end

-- notifications when the window is closed ---------------------------------------------------------
local function toastOpen(key, title, text)
    ns.Dialogs:Toast(key, title, text, {
        icon = Theme.ICON, iconCoords = { 0, 1, 0, 1 }, timeout = 8,
        onClick = function() UI:Show("game") end,
    })
end

function UI:OnChallengeReceived(c)
    local text = string.format("%s challenges you to a game of chess.\n%s · you play %s.",
        Names.Display(c.from), ns.Challenge.Describe(c.tc), Theme.Side(c.myColor).name)
    ns.Dialogs:Show("challenge-" .. c.id, {
        title = "Chess challenge!",
        text = text,
        icon = Theme.ICON, iconCoords = { 0, 1, 0, 1 },
        timeout = 58,
        buttons = {
            { label = "Accept", onClick = function()
                if ns.Challenge:Accept(c.id) then ns.Print("Accepted. Starting the game with %s...", Names.Display(c.from)) end
            end },
            { label = "Decline", onClick = function() ns.Challenge:Decline(c.id, "declined") end },
            { label = "Later", onClick = function() end },
        },
        -- Escape / close / timeout leave the challenge pending in the Play tab until it expires
    })
end

function UI:OnInitialize()
    ns:On("GAME_STARTED", function(g)
        ns.GameView:SetGame(g)
        ns.Dialogs:Hide("draw")
        UI:Show("game")
        if ns.MinimapButton then ns.MinimapButton:UpdateAttention() end
    end)
    ns:On("GAME_UPDATED", function(g, info)
        ns.GameView:OnGameUpdated(g, info)
        if ns.MinimapButton then ns.MinimapButton:UpdateAttention() end
        UI:RefreshTabs()
        -- a live opponent moved while the window is closed
        if info and not UI:IsShown() and ns.Live.game == g and not g.result and info.side ~= g.localColor then
            toastOpen("your-move", "Your move!", string.format("%s played %s. Click to open the board.",
                Names.Display(ns.Live.opp), info.san or info.uci))
        end
    end)
    ns:On("GAME_ENDED", function(g)
        if ns.GameView:Game() == g then ns.GameView:ShowResultBanner() end
        ns.Dialogs:Hide("draw")
        ns.Dialogs:Hide("your-move")
        ns.Lobby:Refresh()
        ns.History:Refresh()
        if ns.MinimapButton then ns.MinimapButton:UpdateAttention() end
        if not UI:IsShown() and g.mode == "live" then
            local outcome = g:Outcome(g.localColor)
            local title = (outcome == "win" and "You won!") or (outcome == "loss" and "You lost") or
                (outcome == "draw" and "Draw") or "Game over"
            toastOpen("game-over", title, (g:ResultText() or "") .. ".")
        end
    end)
    ns:On("GAME_CLOSED", function()
        ns.GameView:SetGame(ns.activeGame)
        if UI.tab == "game" and not ns.GameView:Game() then UI:ShowTab("play") end
        ns.Lobby:Refresh()
        if ns.MinimapButton then ns.MinimapButton:UpdateAttention() end
    end)
    ns:On("BOT_THINKING", function()
        if ns.GameView.frame and ns.GameView.game then ns.GameView:UpdateStatus() end
    end)
    ns:On("BOT_QUIP", function(p, line) ns.GameView:OnQuip(p, line) end)
    ns:On("DRAW_OFFERED", function(g)
        if UI:IsShown() and UI.tab == "game" then return end -- the game panel shows the offer
        ns.Dialogs:Show("draw", {
            title = "Draw offer",
            text = string.format("%s offers a draw.", Names.Display(ns.Live.opp)),
            icon = Theme.ICON, iconCoords = { 0, 1, 0, 1 },
            buttons = {
                { label = "Accept", onClick = function() ns.Live:AcceptDraw() end },
                { label = "Decline", onClick = function() ns.Live:DeclineDraw() end },
            },
        })
    end)
    ns:On("CHALLENGE_RECEIVED", function(c) UI:OnChallengeReceived(c) end)
    ns:On("CHALLENGE_EXPIRED", function(c)
        ns.Dialogs:Hide("challenge-" .. c.id)
        ns.Print("The challenge from %s expired.", Names.Display(c.from))
    end)
    ns:On("CHALLENGE_CANCELLED", function(c)
        ns.Dialogs:Hide("challenge-" .. c.id)
        ns.Print("%s withdrew the challenge.", Names.Display(c.from))
    end)
    ns:On("CHALLENGES_CHANGED", function()
        -- hide pop-ups for challenges that are gone or already answered
        for _, c in ipairs(ns.Challenge:ListIncoming()) do
            if c.state ~= "pending" then ns.Dialogs:Hide("challenge-" .. c.id) end
        end
        ns.Lobby:RefreshChallenges()
        UI:RefreshTabs()
        if ns.MinimapButton then ns.MinimapButton:UpdateAttention() end
    end)
    local presencePending = false
    ns:On("PRESENCE_CHANGED", function()
        if presencePending then return end
        presencePending = true
        C_Timer.After(0.5, function()
            presencePending = false
            ns.Lobby:RefreshPlayers()
            UI:RefreshTabs()
        end)
    end)
    ns:On("LIVE_CONNECTION", function()
        if ns.GameView.game and ns.GameView:Mode() == "live" then ns.GameView:RefreshPanel() end
    end)
    ns:On("COMM_LOCKDOWN", function()
        if ns.GameView.game and ns.GameView:Mode() == "live" then ns.GameView:RefreshPanel() end
    end)
    ns:On("LIVE_STATE_CHANGED", function()
        ns.Lobby:Refresh()
        UI:RefreshTabs()
    end)
    ns:On("SAVED_GAMES_CHANGED", function() ns.Lobby:RefreshSaved() end)
    ns:On("NEWER_VERSION", function() ns.Lobby:RefreshChallenges() end)
    ns:On("SETTINGS_CHANGED", function(key)
        if not UI.frame then return end
        if key == nil or key == "scale" then UI.frame:SetScale(ns.db.settings.scale or 1) end
        local view = ns.GameView.view
        if view then
            view.skinKey = nil
            view:UpdateOrientation()
        end
        ns.GameView:Refresh()
        ns.Lobby:Refresh()
    end)
end

function UI:OnEnable()
    ns.SettingsUI.RegisterBlizzardPanel()
    -- a game restored at login (live game after /reload) is already on the board
    if ns.activeGame and not ns.GameView:Game() then ns.GameView:SetGame(ns.activeGame) end
end

return UI
