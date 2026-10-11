--[[
    Chess Craft - UI/History.lua
    The "History" tab: your record, and the last 100 finished games with
    a move-by-move review on the board and PGN export.
]]

local _, ns = ...
local Theme, W, Compat, Names = ns.Theme, ns.Widgets, ns.Compat, ns.Names
local C = Theme.COLORS

local History = {}
ns.History = History

local WIDTH = 784
local ROW_H = 26

local OUTCOME = {
    win = { "Win", C.good },
    loss = { "Loss", C.bad },
    draw = { "Draw", C.gold },
    aborted = { "Aborted", C.dim },
}

local SHORT_TERMINATION = {
    checkmate = "checkmate", stalemate = "stalemate", repetition = "repetition", fifty = "50-move rule",
    material = "insufficient material", agreement = "agreement", resign = "resignation",
    timeout = "time", ["timeout-draw"] = "time (no mating material)", abandon = "left the game",
    disconnect = "disconnect", aborted = "aborted",
}

local function dim(text) return Theme.ColorText(text, C.dim) end

local function opponentName(e)
    if e.mode == "bot" then
        local p = ns.Bots.Get(e.botId or 1)
        return p and p.name or "Bot"
    end
    return Names.Display(e.opponent)
end

local function sum(group)
    local w, l, d = 0, 0, 0
    for _, s in pairs(group) do w, l, d = w + s.w, l + s.l, d + s.d end
    return w, l, d
end

function History:Build(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    self.frame = f

    local header = W.Header(f, "Game history")
    header:SetPoint("TOPLEFT", 2, -2)
    self.totals = W.Label(f, "", "GameFontHighlight", "RIGHT")
    self.totals:SetPoint("TOPRIGHT", -2, -4)
    self.breakdown = W.Label(f, "", "GameFontHighlightSmall", "RIGHT")
    self.breakdown:SetPoint("TOPRIGHT", -2, -22)
    self.breakdown:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    -- column headings
    local cols = {
        { "When", 8 }, { "Opponent", 104 }, { "Side", 330 }, { "Result", 404 }, { "How", 470 }, { "Moves", 610 },
    }
    for _, c in ipairs(cols) do
        local l = W.Label(f, c[1], "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", c[2], -46)
    end

    self.list = W.ScrollList(f, WIDTH - 26, 400, ROW_H, function(content)
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(ROW_H)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.035)
        local function cell(x, w, font)
            local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth(w)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            return fs
        end
        row.when = cell(6, 92)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 100, 0)
        row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.opp = cell(126, 196)
        row.side = cell(328, 70)
        row.result = cell(402, 64, "GameFontNormalSmall")
        row.how = cell(468, 138)
        row.moves = cell(608, 44)
        row.pgn = W.FlatButton(row, "PGN", 40, 20, function()
            local g = ns.GameView.GameFromHistory(row.entry)
            if g then
                ns.UI:ShowCopyText("Game PGN", "Press Ctrl+C to copy, then paste it into any chess site or program.",
                    ns.GameView.PGN(g))
            end
        end)
        row.pgn:SetPoint("RIGHT", -2, 0)
        row.review = W.FlatButton(row, "Review", 56, 20, function()
            ns.GameView:ShowReview(row.entry)
        end)
        row.review:SetPoint("RIGHT", row.pgn, "LEFT", -4, 0)
        return row
    end, function(row, e, index)
        row.entry = e
        row.bg:SetShown(index % 2 == 1)
        row.when:SetText(e.date and date("%b %d, %H:%M", e.date) or "")
        if e.mode == "bot" then
            local p = ns.Bots.Get(e.botId or 1)
            Compat.SetTextureFromList(row.icon, p and p.icon or Theme.ICON)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            row.icon:SetTexture(Theme.PieceTextureFor(3 - (e.myColor or 1), 6))
            row.icon:SetTexCoord(0, 1, 0, 1)
        end
        local tc = ""
        if e.mode == "live" then
            local t = e.timeControl and ns.Challenge.WireToTimeControl(e.timeControl)
            tc = dim(" · " .. (t and ns.Challenge.Describe(t) or "untimed"))
        end
        row.opp:SetText(opponentName(e) .. tc)
        row.side:SetText(Theme.Side(e.myColor or 1).name)
        local o = OUTCOME[e.outcome] or OUTCOME.aborted
        row.result:SetText(o[1])
        row.result:SetTextColor(o[2][1], o[2][2], o[2][3])
        row.how:SetText(SHORT_TERMINATION[e.termination] or tostring(e.termination or ""))
        row.moves:SetText(tostring(math.ceil((e.plies or 0) / 2)))
        local hasMoves = e.moves ~= nil
        row.review:SetEnabled(hasMoves)
        row.pgn:SetEnabled(hasMoves)
    end)
    self.list:SetPoint("TOPLEFT", 0, -62)

    self.empty = W.Label(f, "Finished games show up here. Review them move by move or copy them as PGN.",
        "GameFontDisable", "CENTER")
    self.empty:SetPoint("CENTER", 0, 0)

    f:SetScript("OnShow", function() History:Refresh() end)
    return f
end

function History:Refresh()
    if not self.frame or not self.frame:IsVisible() then return end
    local h = ns.db.char.history
    self.list:SetItems(h)
    self.empty:SetShown(#h == 0)
    local w, l, d = ns.Database.Totals()
    self.totals:SetText(string.format("%s  %s  %s",
        Theme.ColorText(w .. " won", C.good), Theme.ColorText(l .. " lost", C.bad), Theme.ColorText(d .. " drawn", C.gold)))
    local bw, bl, bd = sum(ns.db.char.stats.bots)
    local pw, pl, pd = sum(ns.db.char.stats.players)
    self.breakdown:SetText(string.format("vs bots %d-%d-%d · vs players %d-%d-%d", bw, bl, bd, pw, pl, pd))
end

return History
