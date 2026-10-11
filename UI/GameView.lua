--[[
    Chess Craft - UI/GameView.lua
    The "Game" tab: the board, and beside it both players (name, clock,
    captured pieces), a message strip (bot chatter, draw offers, connection
    problems), the move list, navigation, the status line and the controls
    that fit the kind of game on screen:

      bot game     Pause/Resume, Take back, Resign, Close (stays saved)
      live game    Offer draw, Abort/Resign, Leave (untimed games)
      finished     Rematch, Copy PGN, Close
      review       a finished game from History, read only
]]

local _, ns = ...
local Theme, W, Compat, Names = ns.Theme, ns.Widgets, ns.Compat, ns.Names
local Board = ns.Board
local T = ns.ChessTables
local C = Theme.COLORS

local GameView = {}
ns.GameView = GameView

local CARD_H = 64
local BANNER_H = 44
local ROW_H = 18
local LOW_TIME_MS = 20000
local QUIP_SECONDS = 7
local WHITE, BLACK = 1, 2
local CAPTURE_ORDER = { 5, 4, 3, 2, 1 } -- queen, rook, bishop, knight, pawn

local function now() return ns.Clock.now() end

-- helpers ------------------------------------------------------------------------------
local function persona(g, side)
    local p = g and g.players[side]
    if p and p.kind == "bot" then return ns.Bots.Get(p.botId or (g.extra and g.extra.botId) or 1) end
    return nil
end

local function playerName(g, side)
    local bot = persona(g, side)
    if bot then return bot.name end
    local p = g.players[side]
    return Names.Display(p and p.name or "?")
end
GameView.PlayerName = playerName

local function colorize(text, c) return Theme.ColorText(text, c) end

-- construction -----------------------------------------------------------------------------
local function createCard(parent)
    local card = W.Panel(parent)
    card:SetHeight(CARD_H)

    card.turn = card:CreateTexture(nil, "ARTWORK")
    card.turn:SetPoint("TOPLEFT", 4, -4)
    card.turn:SetPoint("BOTTOMLEFT", 4, 4)
    card.turn:SetWidth(3)
    card.turn:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.9)

    card.icon = W.Icon(card, 40)
    card.icon:SetPoint("LEFT", 11, 0)

    card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 59, -8)
    card.name:SetWidth(150)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)

    card.sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.sub:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -2)
    card.sub:SetWidth(150)
    card.sub:SetJustifyH("LEFT")
    card.sub:SetWordWrap(false)
    card.sub:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    -- a light tray behind captured pieces keeps dark pieces readable
    card.capBg = card:CreateTexture(nil, "BORDER")
    card.capBg:SetColorTexture(0.85, 0.80, 0.70, 0.22)
    card.capBg:SetHeight(17)
    card.capBg:Hide()
    card.caps = {}
    for i = 1, 16 do
        local t = card:CreateTexture(nil, "ARTWORK")
        t:SetSize(15, 15)
        t:Hide()
        card.caps[i] = t
    end
    card.adv = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.adv:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    local clock = CreateFrame("Frame", nil, card, "BackdropTemplate")
    clock:SetSize(90, 34)
    clock:SetPoint("RIGHT", -10, 0)
    clock:SetBackdrop(Theme.FlatBackdrop())
    clock.text = clock:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
    clock.text:SetPoint("CENTER", 0, 0)
    pcall(clock.text.SetFont, clock.text, "Fonts\\ARIALN.TTF", 21, "")
    card.clock = clock

    card.badge = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.badge:SetPoint("RIGHT", -12, 0)
    return card
end

local function createSanButton(row, gv)
    local b = CreateFrame("Button", nil, row)
    b:SetSize(104, ROW_H)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.28)
    b.sel:Hide()
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.08)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetJustifyH("LEFT")
    b:SetScript("OnClick", function(self)
        if self.ply and gv.view then gv.view:SetViewPly(self.ply) end
    end)
    return b
end

function GameView:Build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    self.frame = f

    local view = ns.BoardView.Create(f)
    view.frame:SetPoint("TOPLEFT", 0, 0)
    view.canMove = function() return GameView:CanMove() end
    view.onMove = function(uci, wasClick) GameView:OnBoardMove(uci, wasClick) end
    view.onViewChanged = function() GameView:RefreshPanel() end
    self.view = view

    local panel = CreateFrame("Frame", nil, f)
    panel:SetPoint("TOPLEFT", view.frame, "TOPRIGHT", 12, 0)
    panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    self.panel = panel

    self.topCard = createCard(panel)
    self.topCard:SetPoint("TOPLEFT", 0, 0)
    self.topCard:SetPoint("TOPRIGHT", 0, 0)
    self.bottomCard = createCard(panel)
    self.bottomCard:SetPoint("BOTTOMLEFT", 0, 0)
    self.bottomCard:SetPoint("BOTTOMRIGHT", 0, 0)

    -- message strip
    local banner = W.Panel(panel)
    banner:SetPoint("TOPLEFT", self.topCard, "BOTTOMLEFT", 0, -6)
    banner:SetPoint("TOPRIGHT", self.topCard, "BOTTOMRIGHT", 0, -6)
    banner:SetHeight(BANNER_H)
    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetSize(26, 26)
    banner.icon:SetPoint("LEFT", 9, 0)
    banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    banner.text:SetJustifyH("LEFT")
    banner.text:SetJustifyV("MIDDLE")
    banner.text:SetPoint("LEFT", banner.icon, "RIGHT", 8, 0)
    banner.text:SetHeight(BANNER_H - 8)
    banner.btn2 = W.Button(banner, "", 62, 20)
    banner.btn2:SetPoint("RIGHT", -8, 0)
    banner.btn1 = W.Button(banner, "", 62, 20)
    banner.btn1:SetPoint("RIGHT", banner.btn2, "LEFT", -4, 0)
    self.banner = banner

    -- navigation row
    local nav = CreateFrame("Frame", nil, panel)
    nav:SetHeight(22)
    nav:SetPoint("BOTTOMLEFT", self.bottomCard, "TOPLEFT", 0, 58)
    nav:SetPoint("BOTTOMRIGHT", self.bottomCard, "TOPRIGHT", 0, 58)
    local function navButton(label, x, w, fn, tip)
        local b = W.FlatButton(nav, label, w, 22, fn)
        b:SetPoint("LEFT", x, 0)
        if tip then W.Tooltip(b, tip) end
        return b
    end
    self.navFirst = navButton("<<", 0, 40, function() self.view:ViewFirst() end, "First position")
    self.navPrev = navButton("<", 44, 40, function() self.view:Step(-1) end, "Previous move")
    self.navNext = navButton(">", 88, 40, function() self.view:Step(1) end, "Next move")
    self.navLast = navButton(">>", 132, 40, function() self.view:ViewLast() end, "Current position")
    self.flipButton = navButton("Flip", 180, 56, function() self.view:Flip(); self:RefreshPanel() end, "Flip the board")
    self.pgnButton = W.FlatButton(nav, "PGN", 56, 22, function() self:CopyPGN() end)
    self.pgnButton:SetPoint("RIGHT", 0, 0)
    W.Tooltip(self.pgnButton, "Copy PGN", "Show this game in PGN notation so you can copy it into any chess program or website.")

    -- move list between the message strip and the navigation row
    local listW = 312 - 28
    local list = W.ScrollList(panel, listW, 100, ROW_H, function(content)
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(ROW_H)
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
        row.stripe:SetColorTexture(1, 1, 1, 0.03)
        row.num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.num:SetPoint("LEFT", 0, 0)
        row.num:SetWidth(30)
        row.num:SetJustifyH("RIGHT")
        row.w = createSanButton(row, self)
        row.w:SetPoint("LEFT", 36, 0)
        row.b = createSanButton(row, self)
        row.b:SetPoint("LEFT", 36 + 112, 0)
        return row
    end, function(row, item, index)
        row.stripe:SetShown(index % 2 == 0)
        row.num:SetText(item.num .. ".")
        local viewed = self.view:ViewedPly()
        for _, key in ipairs({ "w", "b" }) do
            local btn, san, ply = row[key], item[key .. "San"], item[key .. "Ply"]
            if san then
                btn.text:SetText(san)
                btn.ply = ply
                btn.sel:SetShown(ply == viewed)
                btn:Show()
            else
                btn.ply = nil
                btn.sel:Hide()
                btn:SetShown(key == "w" and item.bSan ~= nil)
                btn.text:SetText(key == "w" and "..." or "")
            end
        end
    end)
    list:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 2, -6)
    list:SetPoint("BOTTOMLEFT", nav, "TOPLEFT", 2, 6)
    list:SetWidth(listW)
    list.content:SetWidth(listW)
    self.moveList = list
    self.emptyMoves = W.Label(list, "", "GameFontDisable", "CENTER")
    self.emptyMoves:SetPoint("CENTER", 0, 0)

    -- status line and controls
    self.status = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.status:SetPoint("BOTTOMLEFT", self.bottomCard, "TOPLEFT", 0, 38)
    self.status:SetPoint("BOTTOMRIGHT", self.bottomCard, "TOPRIGHT", 0, 38)
    self.status:SetHeight(16)
    self.status:SetJustifyH("CENTER")

    self.actions = {}
    for i = 1, 4 do
        local b = W.Button(panel, "", 74, 24, function() GameView:RunAction(i) end)
        b:Hide()
        self.actions[i] = b
    end

    -- placeholder when nothing is on the board
    local empty = CreateFrame("Frame", nil, f)
    empty:SetAllPoints(panel)
    empty.text = W.Label(empty, "No game in progress.\n\nPick a bot or challenge a player on the Play tab.", "GameFontHighlight", "CENTER")
    empty.text:SetPoint("CENTER", 0, 40)
    empty.text:SetWidth(290)
    empty.play = W.Button(empty, "Go to Play", 140, 24, function() ns.UI:ShowTab("play") end)
    empty.play:SetPoint("TOP", empty.text, "BOTTOM", 0, -16)
    self.empty = empty

    f:SetScript("OnUpdate", function(_, elapsed) GameView:OnUpdate(elapsed) end)
    f:SetScript("OnShow", function() GameView:Refresh() end)

    self:SetGame(ns.activeGame)
    return f
end

-- which game, and who controls it ------------------------------------------------------------
function GameView:Mode()
    local g = self.game
    if not g then return nil end
    if ns.Live and ns.Live.game == g then return "live" end
    if ns.BotGame and ns.BotGame.game == g then return "bot" end
    return "review"
end

function GameView:CanMove()
    local mode = self:Mode()
    if mode == "bot" then return ns.BotGame:CanHumanMove() end
    if mode == "live" then return ns.Live:CanMove() end
    return false
end

function GameView:OnBoardMove(uci)
    local mode = self:Mode()
    local ok, err
    if mode == "bot" then
        ok, err = ns.BotGame:HumanMove(uci)
    elseif mode == "live" then
        ok, err = ns.Live:HumanMove(uci)
    end
    if not ok then
        ns.Debug("move %s not played: %s", tostring(uci), tostring(err))
        self.view:Refresh()
    end
end

function GameView:SetGame(game)
    if game ~= self.game or (game and self.shownId ~= game.id) then
        self.quip = nil
        self.claimDismissedAt = nil
        self.lowTimeWarned = nil
        self.shownId = game and game.id
    end
    self.game = game
    if not self.frame then return end
    self.view:SetGame(game)
    if game and game.result then self:ShowResultBanner() end
    self:Refresh()
end

function GameView:Game() return self.game end

-- Rebuild a finished game from a history entry (for review and PGN export).
function GameView.GameFromHistory(entry)
    if not entry or not entry.moves then return nil end
    local me = { name = Names.Me(), kind = "human" }
    local them
    if entry.mode == "bot" then
        local p = ns.Bots.Get(entry.botId or 1)
        them = { name = p and p.name or "Bot", kind = "bot", botId = entry.botId }
    else
        them = { name = entry.opponent or "?", kind = "remote" }
    end
    local color = entry.myColor or WHITE
    local ok, g = pcall(ns.Game.new, {
        id = "review-" .. tostring(entry.id), mode = entry.mode,
        white = (color == WHITE) and me or them, black = (color == BLACK) and me or them,
        localColor = color, startFEN = entry.startFEN,
        tc = entry.timeControl and ns.Challenge.WireToTimeControl(entry.timeControl) or nil,
    })
    if not ok or not g then return nil end
    for uci in tostring(entry.moves):gmatch("%S+") do
        if not g:Replay(uci) then break end
    end
    local tc = g.tc
    g.clock, g.tc = nil, nil
    local loser
    if entry.outcome == "loss" then loser = color elseif entry.outcome == "win" then loser = 3 - color end
    g:Finish(entry.result or "*", entry.termination or "aborted", loser)
    g.reviewTC = tc -- for the PGN header only; a review has no running clocks
    if entry.date then g.createdAt = entry.date end
    g.reviewOf = entry
    return g
end

function GameView.PGN(g)
    if not g then return "" end
    local saved = g.tc
    if g.reviewTC then g.tc = g.reviewTC end
    local ok, text = pcall(g.ToPGN, g)
    g.tc = saved
    return ok and text or ""
end

-- review a finished game from the history list
function GameView:ShowReview(entry)
    local g = GameView.GameFromHistory(entry)
    if not g then return end
    self:SetGame(g)
    ns.UI:ShowTab("game")
end

function GameView:CloseReview()
    if self:Mode() ~= "review" then return end
    self:SetGame(ns.activeGame)
    if not self.game then ns.UI:ShowTab("history") end
end

-- refresh --------------------------------------------------------------------------------------------
function GameView:Refresh()
    if not self.frame then return end
    local g = self.game
    self.empty:SetShown(g == nil)
    self.panel:SetShown(g ~= nil)
    self.view.frame:SetAlpha(g and 1 or 0.55)
    self.view:Refresh()
    if g then self:RefreshPanel() end
end

function GameView:RefreshPanel()
    local g = self.game
    if not g or not self.frame then return end
    local bottom = self.view:BottomColor()
    local shown = self.view:DisplayBoard() or g.board
    self:UpdateCard(self.bottomCard, g, bottom, shown)
    self:UpdateCard(self.topCard, g, 3 - bottom, shown)
    self:UpdateMoveList()
    self:UpdateNav()
    self:UpdateBanner()
    self:UpdateStatus()
    self:UpdateActions()
    self:UpdateClocks()
end

-- material captured by `side` on the board on screen
local function capturedBy(b, side)
    local count = b.count
    local victim = 3 - side
    local off = (victim == WHITE) and 0 or 6
    local START = { 8, 2, 2, 2, 1 }
    local out = {}
    for _, t in ipairs(CAPTURE_ORDER) do
        local missing = START[t] - count[off + t]
        for _ = 1, math.max(0, missing) do out[#out + 1] = T.PIECE[victim][t] end
    end
    return out
end

local function materialBalance(b)
    local count, bal = b.count, 0
    for t = 1, 5 do bal = bal + (count[t] - count[6 + t]) * T.VALUE[t] end
    return math.floor(bal / 100 + 0.5)
end

function GameView:UpdateCard(card, g, side, b)
    local bot = persona(g, side)
    card.name:SetText(playerName(g, side))
    local s = Theme.Side(side)
    local subParts = {}
    if bot then
        subParts[#subParts + 1] = string.format("Level %d bot, ~%d", bot.level, bot.rating)
    elseif side == g.localColor and self:Mode() ~= "review" then
        subParts[#subParts + 1] = "You"
    end
    subParts[#subParts + 1] = s.name
    card.sub:SetText(table.concat(subParts, " · "))

    -- portrait: bot persona icon, otherwise the side's king or faction emblem
    local tex = card.icon.tex
    if bot then
        Compat.SetTextureFromList(tex, bot.icon)
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    elseif s.emblem then
        tex:SetAtlas(s.emblem)
        tex:SetTexCoord(0, 1, 0, 1)
    else
        tex:SetTexture(Theme.PieceTextureFor(side, 6))
        tex:SetTexCoord(0, 1, 0, 1)
    end
    card.icon:SetBackdropBorderColor(s.color[1], s.color[2], s.color[3], 1)

    -- whose turn
    card.turn:SetShown(not g.result and g.board.side == side)

    -- captured pieces + material lead
    local caps = capturedBy(b, side)
    local x = 0
    local prevType
    local shown = 0
    for i, piece in ipairs(caps) do
        local t = card.caps[i]
        if not t then break end
        local pt = T.TYPE[piece]
        if prevType and pt ~= prevType then x = x + 5 end
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 58 + x, 7)
        t:SetTexture(Theme.PieceTexture(piece))
        t:Show()
        x = x + 9
        prevType = pt
        shown = i
    end
    for i = shown + 1, #card.caps do card.caps[i]:Hide() end
    if shown > 0 then
        card.capBg:ClearAllPoints()
        card.capBg:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 55, 6)
        card.capBg:SetWidth(x + 10)
        card.capBg:Show()
    else
        card.capBg:Hide()
    end
    local bal = materialBalance(b)
    if side == BLACK then bal = -bal end
    card.adv:ClearAllPoints()
    card.adv:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 58 + x + ((shown > 0) and 8 or 0), 9)
    card.adv:SetText(bal > 0 and ("+" .. bal) or "")

    -- clock or a badge
    card.side = side
    if g.tc then
        card.clock:Show()
        card.badge:SetText("")
    else
        card.clock:Hide()
        local mode = self:Mode()
        card.badge:SetText((mode == "live") and "Untimed" or "")
    end
end

function GameView:UpdateClocks()
    local g = self.game
    if not g or not g.tc or not self.frame then return end
    local t = now()
    for _, card in ipairs({ self.topCard, self.bottomCard }) do
        local side = card.side
        if side then
            local ms = g:Remaining(side, t)
            card.clock.text:SetText(W.FormatClock(ms))
            local active = not g.result and g.board.side == side and g:ClockRunning()
            local low = ms and ms < LOW_TIME_MS
            local bg = (low and active) and C.clockLow or (active and C.clockActive or C.clockBg)
            card.clock:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
            if active and not low then
                card.clock.text:SetTextColor(0.08, 0.08, 0.08)
            elseif low then
                card.clock.text:SetTextColor(1, 0.92, 0.9)
            else
                card.clock.text:SetTextColor(0.85, 0.85, 0.85)
            end
            card.clock:SetBackdropBorderColor(active and 1 or 0.4, active and 0.82 or 0.35, active and 0 or 0.3, 1)
            -- one warning beep when our own time gets short
            if active and side == g.localColor and self:Mode() == "live" and ms and ms < 10000 and not self.lowTimeWarned then
                self.lowTimeWarned = true
                Compat.PlaySound("lowtime")
            end
        end
    end
end

function GameView:UpdateMoveList()
    local g = self.game
    local items = {}
    local start = self.startInfo
    if not start or start.fen ~= g.startFEN then
        local b = Board.new(g.startFEN)
        start = { fen = g.startFEN, side = b.side, fullmove = b.fullmove }
        self.startInfo = start
    end
    local num, side = start.fullmove, start.side
    local row
    for i, san in ipairs(g.sans) do
        if side == WHITE or not row then
            row = { num = num }
            items[#items + 1] = row
        end
        if side == WHITE then
            row.wSan, row.wPly = san, i
        else
            row.bSan, row.bPly = san, i
            num = num + 1
        end
        side = 3 - side
    end
    self.moveList:SetItems(items)
    self.emptyMoves:SetText(#items == 0 and "No moves yet" or "")
    -- keep the latest move visible
    if not self.view:IsViewingHistory() then
        local list = self.moveList
        if list.UpdateScrollChildRect then list:UpdateScrollChildRect() end
        list:ScrollToBottom()
        C_Timer.After(0, function() list:ScrollToBottom() end)
    end
end

function GameView:UpdateNav()
    local g = self.game
    local n = g:Ply()
    local viewed = self.view:ViewedPly()
    self.navFirst:SetEnabled(viewed > 0)
    self.navPrev:SetEnabled(viewed > 0)
    self.navNext:SetEnabled(viewed < n)
    self.navLast:SetEnabled(viewed < n)
    for _, b in ipairs({ self.navFirst, self.navPrev, self.navNext, self.navLast }) do
        b:SetAlpha(b:IsEnabled() and 1 or 0.45)
    end
    self.flipButton:SetSelected(self.view.manualFlip)
end

-- message strip --------------------------------------------------------------------------------------
function GameView:SetBanner(icon, text, b1, b2, atlas)
    local banner = self.banner
    if atlas then
        banner.icon:SetAtlas(atlas)
        banner.icon:SetTexCoord(0, 1, 0, 1)
    elseif icon then
        Compat.SetTextureFromList(banner.icon, icon)
        banner.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    banner.icon:SetShown(icon ~= nil or atlas ~= nil)
    banner.text:SetText(text or "")
    local right = -8
    for i, spec in ipairs({ b1 or false, b2 or false }) do
        local btn = (i == 1) and banner.btn1 or banner.btn2
        if spec then
            btn:SetText(spec.label)
            btn:SetScript("OnClick", function() spec.onClick() end)
            btn:Show()
        else
            btn:Hide()
        end
    end
    if b2 then right = right - 132 elseif b1 then right = right - 66 end
    if b1 and not b2 then
        banner.btn1:ClearAllPoints()
        banner.btn1:SetPoint("RIGHT", -8, 0)
    else
        banner.btn1:ClearAllPoints()
        banner.btn1:SetPoint("RIGHT", banner.btn2, "LEFT", -4, 0)
    end
    banner.text:ClearAllPoints()
    if icon or atlas then
        banner.text:SetPoint("LEFT", banner.icon, "RIGHT", 8, 0)
    else
        banner.text:SetPoint("LEFT", banner, "LEFT", 10, 0)
    end
    banner.text:SetPoint("RIGHT", banner, "RIGHT", right, 0)
end

function GameView:UpdateBanner()
    local g = self.game
    local mode = self:Mode()
    local opp = 3 - g.localColor
    local oppName = playerName(g, opp)

    if mode == "live" and not g.result then
        local Live = ns.Live
        if g.drawOfferFrom == opp then
            self:SetBanner(nil, colorize(oppName, C.gold) .. " offers a draw.",
                { label = "Accept", onClick = function() Live:AcceptDraw() end },
                { label = "Decline", onClick = function() Live:DeclineDraw() end },
                "communities-icon-chat")
            return
        end
        if Live:CanClaim() and (not self.claimDismissedAt or now() - self.claimDismissedAt > 60) then
            local silent = math.floor(Live:SilentFor())
            self:SetBanner(nil, string.format("No word from %s for %d:%02d. Claim the win, or keep waiting?",
                    oppName, math.floor(silent / 60), silent % 60),
                { label = "Claim", onClick = function() Live:ClaimDisconnectWin() end },
                { label = "Wait", onClick = function()
                    self.claimDismissedAt = now()
                    self:RefreshPanel()
                end }, "services-icon-warning")
            return
        end
        local state = Live:ConnectionState()
        local text
        if state == "locked" then
            text = "Chat is restricted here (instance or encounter). Your moves are queued and sent as soon as it lifts."
        elseif state == "syncing" then
            text = "Reconnecting to " .. oppName .. "..."
        elseif state == "offline" then
            text = oppName .. " appears to be offline." .. (g.tc and " Their clock keeps running." or " The game is saved until you both return.")
        elseif state == "unstable" then
            text = "Waiting for " .. oppName .. "'s connection..."
        end
        if text then
            self:SetBanner(nil, text, nil, nil, "services-icon-warning")
            return
        end
        if g.drawOfferFrom == g.localColor then
            self:SetBanner(nil, "You offered a draw. Waiting for an answer...", nil, nil, "communities-icon-chat")
            return
        end
    end

    if mode == "bot" and self.quip and now() - self.quip.at < QUIP_SECONDS then
        local q = self.quip
        self:SetBanner(q.persona.icon, colorize(q.persona.name .. ":", C.gold) .. " \"" .. q.line .. "\"")
        return
    end

    -- plain information
    local info
    if mode == "review" then
        local e = g.reviewOf
        info = string.format("Review: %s game, %s", e and e.mode == "bot" and "bot" or "live",
            e and e.date and date("%b %d %Y, %H:%M", e.date) or "")
    elseif mode == "bot" then
        local bot = persona(g, opp)
        info = bot and bot.blurb or ""
    else
        info = (g.tc and ns.Challenge.Describe(g.tc) or "Untimed game") ..
            (g.tc and "" or " · progress is saved; finish it any time you are both online")
    end
    self:SetBanner(nil, colorize(info, C.dim))
end

-- status line --------------------------------------------------------------------------------------
function GameView:StatusText()
    local g = self.game
    local mode = self:Mode()
    local opp = 3 - g.localColor
    local oppName = playerName(g, opp)
    if g.result then
        local outcome = (mode == "review" and g.reviewOf) and g.reviewOf.outcome or g:Outcome(g.localColor)
        local text = g:ResultText() or ""
        if outcome == "win" then return colorize("You won. ", C.good) .. text end
        if outcome == "loss" then return colorize("You lost. ", C.bad) .. text end
        if outcome == "draw" then return colorize("Draw. ", C.gold) .. text end
        return text
    end
    local viewing = self.view:IsViewingHistory() and
        string.format(" (viewing move %d of %d)", self.view:ViewedPly(), g:Ply()) or ""
    if mode == "bot" then
        local BG = ns.BotGame
        if BG.paused then return colorize("Paused.", C.warn) .. " Resume whenever you like." end
        if BG.combatPaused then return colorize("Paused while you are in combat.", C.warn) end
        if g.board.side ~= g.localColor then
            local dots = string.rep(".", 1 + math.floor(now() * 2.5) % 3)
            return oppName .. " is thinking" .. dots .. viewing
        end
        return colorize("Your move.", C.good) .. viewing
    elseif mode == "live" then
        if ns.Live.syncing then return "Reconnecting..." end
        if g.board.side == g.localColor then
            local extra = (g.tc and g:Ply() < 2) and " The clock starts after both first moves." or ""
            return colorize("Your move.", C.good) .. viewing .. extra
        end
        return "Waiting for " .. oppName .. "..." .. viewing
    end
    return ""
end

function GameView:UpdateStatus()
    self.status:SetText(self:StatusText())
end

-- actions ------------------------------------------------------------------------------------------------
local function confirmThen(key, title, text, label, fn)
    if ns.db.settings.confirmResign then
        ns.Dialogs:Confirm(key, title, text, label, fn, ns.UI.frame)
    else
        fn()
    end
end

function GameView:ActionList()
    local g = self.game
    local mode = self:Mode()
    local list = {}
    local function add(label, fn, enabled, tip)
        list[#list + 1] = { label = label, fn = fn, enabled = enabled ~= false, tip = tip }
    end
    if mode == "bot" then
        local BG = ns.BotGame
        local bot = persona(g, 3 - g.localColor)
        if g.result then
            add("Rematch", function()
                BG:StartNew(bot and bot.id or 3, 3 - g.localColor)
            end, true, "Play again with colors switched.")
            add("Take back", function() BG:Undo() end, g:Ply() > 0, "Undo your last move and play on.")
            add("Close", function() BG:SaveAndClose() end, true, "Back to the Play tab.")
        else
            add(BG.paused and "Resume" or "Pause", function() BG:TogglePause() end, true,
                "Pause the game; nothing happens until you resume it.")
            add("Take back", function() BG:Undo() end, g:Ply() > 0, "Undo your last move (and the bot's reply).")
            add("Resign", function()
                confirmThen("resign", "Resign?", "Resign this game against " .. playerName(g, 3 - g.localColor) .. "?",
                    "Resign", function() BG:Resign() end)
            end, g:Ply() > 0)
            add("Close", function() BG:SaveAndClose() end, true,
                "Close the board. The game is saved; resume it from the Play tab any time.")
        end
    elseif mode == "live" then
        local Live = ns.Live
        local opp = 3 - g.localColor
        if g.result then
            add("Rematch", function()
                ns.Challenge:SendTo(Live.opp, g.tc or false, (g.localColor == WHITE) and "black" or "white")
            end, ns.Challenge:CanChallenge(), "Challenge the same player again with colors switched.")
            add("Close", function() Live:Close() end)
        else
            if g.drawOfferFrom == opp then
                add("Accept draw", function() Live:AcceptDraw() end)
            else
                add("Offer draw", function() Live:OfferDraw() end, g.drawOfferFrom ~= g.localColor and g:Ply() >= 2,
                    "Offer your opponent a draw.")
            end
            if Live:CanAbort() then
                add("Abort", function() Live:Abort() end, true, "Cancel the game before it really starts. No result is recorded.")
            else
                add("Resign", function()
                    confirmThen("resign", "Resign?", "Resign this game against " .. playerName(g, opp) .. "?", "Resign",
                        function() Live:Resign() end)
                end)
            end
            if not g.tc then
                add("Leave", function()
                    local text = Live:CanAbort()
                        and "Leave this game? Neither side has moved yet, so it is simply cancelled."
                        or "Leave this game? It will count as a loss."
                    ns.Dialogs:Confirm("leave", "Leave the game?", text, "Leave", function() Live:Leave() end, ns.UI.frame)
                end, true, "An untimed game stays open until you finish it or leave it.")
            end
        end
    else
        add("Close", function() self:CloseReview() end)
    end
    return list
end

function GameView:UpdateActions()
    local list = self:ActionList()
    self.actionList = list
    local n = #list
    local panelW = 312
    local gap = 6
    local bw = math.floor((panelW - gap * (n - 1)) / math.max(n, 1))
    for i, b in ipairs(self.actions) do
        local spec = list[i]
        if spec then
            b:SetText(spec.label)
            b:SetWidth(bw)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", self.bottomCard, "TOPLEFT", (i - 1) * (bw + gap), 8)
            b:SetEnabled(spec.enabled)
            if spec.tip then W.Tooltip(b, spec.label, spec.tip) else
                b:SetScript("OnEnter", nil)
                b:SetScript("OnLeave", nil)
            end
            b:Show()
        else
            b:Hide()
        end
    end
end

function GameView:RunAction(i)
    local spec = self.actionList and self.actionList[i]
    if spec and spec.enabled then spec.fn() end
end

function GameView:CopyPGN()
    local g = self.game
    if not g then return end
    ns.UI:ShowCopyText("Game PGN", "Press Ctrl+C to copy, then paste it into any chess site or program.", GameView.PGN(g))
end

-- events --------------------------------------------------------------------------------------------
function GameView:ShowResultBanner()
    local g = self.game
    if not g or not g.result or not self.frame then return end
    local outcome = (self:Mode() == "review" and g.reviewOf) and g.reviewOf.outcome or g:Outcome(g.localColor)
    local title, color
    if outcome == "win" then title, color = "Victory!", C.good
    elseif outcome == "loss" then title, color = "Defeat", C.bad
    elseif outcome == "draw" then title, color = "Draw", C.gold
    else title, color = "Game aborted", C.dim end
    self.view:ShowBanner(title, g:ResultText(), color)
end

function GameView:OnGameUpdated(g, info)
    if not self.frame then
        self.game = g
        return
    end
    if g ~= self.game then
        -- the live game object can be rebuilt during a resync
        if self:Mode() == "review" and g ~= ns.activeGame then return end
        self:SetGame(g)
        return
    end
    -- a new move: jump back to the live position
    if info and self.view:IsViewingHistory() then self.view.viewPly = nil end
    if g.result then
        self.view:CancelPromotion()
        self.view:ClearSelection(true)
    end
    self.view:Refresh()
    if info and info.move then
        local mine = info.side == g.localColor
        if not mine or self.view.lastSubmitWasClick then self.view:AnimateMove(info.move) end
        self.view.lastSubmitWasClick = nil
    end
    if not g.result then self.view:HideBanner() end
    self:RefreshPanel()
end

function GameView:OnUpdate(elapsed)
    self.tick = (self.tick or 0) + elapsed
    if self.tick < 0.1 then return end
    self.tick = 0
    local g = self.game
    if not g then return end
    if g.tc then self:UpdateClocks() end
    local mode = self:Mode()
    -- refresh the status line (thinking dots) and time-based messages twice a second
    self.slow = (self.slow or 0) + 1
    if self.slow >= 5 then
        self.slow = 0
        self:UpdateStatus()
        if mode == "live" or (self.quip and now() - self.quip.at >= QUIP_SECONDS) then
            if self.quip and now() - self.quip.at >= QUIP_SECONDS then self.quip = nil end
            self:UpdateBanner()
            self:UpdateActions()
        end
    end
end

function GameView:OnQuip(p, line)
    if not self.game or self:Mode() ~= "bot" then return end
    self.quip = { persona = p, line = line, at = now() }
    if self.frame then self:UpdateBanner() end
end

return GameView
