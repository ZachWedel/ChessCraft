--[[
    Chess Craft - UI/BoardView.lua
    The chessboard widget. Renders a position with last-move, selection,
    check and legal-move markers; takes moves by click-click or drag and
    drop; asks which piece to promote to; slides pieces for the opponent's
    moves; and can show any earlier position of the game.

    The view never changes the game itself: a finished move is handed to
    view.onMove(uci, wasClick) and the game logic decides.
]]

local _, ns = ...
local Theme = ns.Theme
local Board = ns.Board
local T = ns.ChessTables
local C = Theme.COLORS

local BoardView = {}
BoardView.__index = BoardView
ns.BoardView = BoardView

local SQ = 56
local BORDER = 6
local DRAG_THRESHOLD = 5
local ANIM_TIME = 0.16
local WHITE, BLACK = 1, 2
local PROMO_ORDER = { 5, 2, 4, 3 } -- queen, knight, rook, bishop
local FILES = "abcdefgh"
local FLAG_EP = 2                   -- Board.MoveFlag() value of an en passant capture

BoardView.SQUARE = SQ
BoardView.BORDER = BORDER
BoardView.SIZE = SQ * 8 + BORDER * 2

local floor, abs = math.floor, math.abs

-- construction --------------------------------------------------------------------
function BoardView.Create(parent)
    local self = setmetatable({}, BoardView)
    self.flipped = false
    self.manualFlip = false

    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(BoardView.SIZE, BoardView.SIZE)
    frame:SetBackdrop({
        bgFile = Theme.WHITE8, edgeFile = Theme.WHITE8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropBorderColor(0, 0, 0, 0.9)
    self.frame = frame

    local board = CreateFrame("Frame", nil, frame)
    board:SetSize(SQ * 8, SQ * 8)
    board:SetPoint("BOTTOMLEFT", BORDER, BORDER)
    self.board = board

    -- one slot per visual square; which chess square it shows depends on flip
    self.slots = {}
    for row = 0, 7 do
        for col = 0, 7 do
            local slot = { col = col, row = row }
            local x, y = col * SQ, row * SQ
            local function place(tex, inset)
                inset = inset or 0
                tex:SetPoint("BOTTOMLEFT", board, "BOTTOMLEFT", x + inset, y + inset)
                tex:SetSize(SQ - 2 * inset, SQ - 2 * inset)
            end
            slot.bg = board:CreateTexture(nil, "BACKGROUND")
            place(slot.bg)
            slot.mark = board:CreateTexture(nil, "BORDER")
            place(slot.mark)
            slot.mark:SetColorTexture(C.lastMove[1], C.lastMove[2], C.lastMove[3], C.lastMove[4])
            slot.mark:Hide()
            slot.sel = board:CreateTexture(nil, "BORDER", nil, 1)
            place(slot.sel)
            slot.sel:SetColorTexture(C.selected[1], C.selected[2], C.selected[3], C.selected[4])
            slot.sel:Hide()
            slot.check = board:CreateTexture(nil, "ARTWORK", nil, -1)
            place(slot.check)
            slot.check:SetTexture(Theme.GLOW)
            slot.check:SetVertexColor(C.check[1], C.check[2], C.check[3], C.check[4])
            slot.check:Hide()
            slot.piece = board:CreateTexture(nil, "ARTWORK", nil, 1)
            place(slot.piece, 1)
            slot.piece:Hide()
            slot.hint = board:CreateTexture(nil, "OVERLAY")
            place(slot.hint)
            slot.hint:Hide()
            self.slots[row * 8 + col + 1] = slot
        end
    end

    -- coordinates live inside the edge squares, like most online boards
    self.fileLabels, self.rankLabels = {}, {}
    for i = 0, 7 do
        local f = board:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f:SetPoint("BOTTOMRIGHT", board, "BOTTOMLEFT", (i + 1) * SQ - 3, 2)
        self.fileLabels[i] = f
        local r = board:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        r:SetPoint("TOPLEFT", board, "BOTTOMLEFT", 3, (i + 1) * SQ - 2)
        self.rankLabels[i] = r
    end

    self.hover = board:CreateTexture(nil, "OVERLAY", nil, 1)
    self.hover:SetColorTexture(C.hover[1], C.hover[2], C.hover[3], C.hover[4])
    self.hover:SetSize(SQ, SQ)
    self.hover:Hide()

    -- mouse input for the whole board
    local input = CreateFrame("Frame", nil, board)
    input:SetAllPoints(board)
    input:EnableMouse(true)
    input:SetScript("OnMouseDown", function(_, button) self:OnMouseDown(button) end)
    input:SetScript("OnMouseUp", function(_, button) self:OnMouseUp(button) end)
    input:SetScript("OnEnter", function() self.mouseInside = true end)
    input:SetScript("OnLeave", function()
        self.mouseInside = false
        self:UpdateHover()
    end)
    input:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
    input:SetScript("OnHide", function()
        self:CancelDrag()
        self:CancelPromotion()
        self:StopAnimation()
    end)
    -- mouse wheel steps through the game's moves
    input:EnableMouseWheel(true)
    input:SetScript("OnMouseWheel", function(_, delta)
        if self.game and not self.dragging and not self.promo:IsShown() then self:Step(-delta) end
    end)
    self.input = input

    -- dragged / sliding pieces float above everything else on the board
    local top = CreateFrame("Frame", nil, board)
    top:SetAllPoints(board)
    top:SetFrameLevel(input:GetFrameLevel() + 5)
    self.top = top
    self.dragTex = top:CreateTexture(nil, "OVERLAY")
    self.dragTex:SetSize(SQ + 6, SQ + 6)
    self.dragTex:Hide()
    self.animTex = top:CreateTexture(nil, "ARTWORK")
    self.animTex:SetSize(SQ - 2, SQ - 2)
    self.animTex:Hide()

    -- result banner across the middle of the board (click to dismiss)
    local banner = CreateFrame("Frame", nil, board)
    banner:SetPoint("LEFT", board, "LEFT", 0, 0)
    banner:SetPoint("RIGHT", board, "RIGHT", 0, 0)
    banner:SetHeight(76)
    banner:SetFrameLevel(top:GetFrameLevel() + 2)
    banner:EnableMouse(true)
    banner.bg = banner:CreateTexture(nil, "BACKGROUND")
    banner.bg:SetAllPoints()
    banner.bg:SetColorTexture(0, 0, 0, 0.74)
    banner.line1 = banner:CreateTexture(nil, "BORDER")
    banner.line1:SetPoint("TOPLEFT"); banner.line1:SetPoint("TOPRIGHT"); banner.line1:SetHeight(2)
    banner.line2 = banner:CreateTexture(nil, "BORDER")
    banner.line2:SetPoint("BOTTOMLEFT"); banner.line2:SetPoint("BOTTOMRIGHT"); banner.line2:SetHeight(2)
    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    banner.title:SetPoint("TOP", 0, -14)
    banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -6)
    banner:SetScript("OnMouseDown", function(f) f:Hide() end)
    banner:Hide()
    self.banner = banner

    -- promotion picker
    local promo = CreateFrame("Frame", nil, board)
    promo:SetAllPoints(board)
    promo:SetFrameLevel(top:GetFrameLevel() + 6)
    promo:EnableMouse(true)
    promo.dim = promo:CreateTexture(nil, "BACKGROUND")
    promo.dim:SetAllPoints()
    promo.dim:SetColorTexture(0, 0, 0, 0.45)
    promo:SetScript("OnMouseDown", function() self:CancelPromotion() end)
    promo.buttons = {}
    for i = 1, 4 do
        local b = CreateFrame("Button", nil, promo)
        b:SetSize(SQ, SQ)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(0.93, 0.91, 0.86, 0.97)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 3, -3)
        b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 0.82, 0, 0.35)
        b:SetScript("OnClick", function() self:FinishPromotion(PROMO_ORDER[i]) end)
        promo.buttons[i] = b
    end
    promo:Hide()
    self.promo = promo

    return self
end

-- game & orientation ----------------------------------------------------------------
function BoardView:SetGame(game)
    if self.game ~= game then
        local sameGame = self.game and game and self.game.id == game.id
        self.game = game
        self.viewPly = nil
        if not sameGame then self.manualFlip = false end
        self:ClearSelection(true)
        self:CancelDrag()
        self:CancelPromotion()
        self:StopAnimation()
        self:HideBanner()
    end
    self:UpdateOrientation()
    self:Refresh()
end

function BoardView:BottomColor()
    local bottom = WHITE
    local g = self.game
    local mine = g and g.localColor or self.idleColor
    if mine and ns.db.settings.autoFlip and mine == BLACK then bottom = BLACK end
    if self.manualFlip then bottom = 3 - bottom end
    return bottom
end

function BoardView:UpdateOrientation()
    self.flipped = (self:BottomColor() == BLACK)
end

function BoardView:Flip()
    self.manualFlip = not self.manualFlip
    self:UpdateOrientation()
    self:CancelPromotion()
    self:Refresh()
end

-- chess square shown in a visual slot
function BoardView:SquareAt(col, row)
    if self.flipped then return 22 + (7 - col) + 10 * (7 - row) end
    return 22 + col + 10 * row
end

-- visual slot (and col,row) that shows a chess square
function BoardView:SlotOf(sq)
    local f, r = T.FILE[sq], T.RANK[sq]
    if self.flipped then f, r = 7 - f, 7 - r end
    return self.slots[r * 8 + f + 1], f, r
end

function BoardView:SquareUnderCursor()
    local left, bottom = self.board:GetLeft(), self.board:GetBottom()
    if not left or not bottom then return nil end
    local x, y = GetCursorPosition()
    local scale = self.board:GetEffectiveScale()
    x, y = x / scale - left, y / scale - bottom
    local col, row = floor(x / SQ), floor(y / SQ)
    if col < 0 or col > 7 or row < 0 or row > 7 then return nil end
    return self:SquareAt(col, row), col, row
end

-- which position is on screen ----------------------------------------------------------
function BoardView:DisplayBoard()
    local g = self.game
    if not g then
        -- no game: show the starting position as decoration
        if not self.idleBoard then self.idleBoard = Board.new() end
        return self.idleBoard, 0
    end
    local n = g:Ply()
    if not self.viewPly or self.viewPly >= n then return g.board, n end
    local b = self.viewBoard
    if not b then
        b = Board.new()
        self.viewBoard = b
    end
    b:setFEN(g.startFEN)
    for i = 1, self.viewPly do
        if not b:makeMove(g.moveInts[i]) then break end
    end
    return b, self.viewPly
end

function BoardView:IsViewingHistory()
    return self.viewPly ~= nil and self.game ~= nil and self.viewPly < self.game:Ply()
end

function BoardView:ViewedPly()
    if self:IsViewingHistory() then return self.viewPly end
    return self.game and self.game:Ply() or 0
end

function BoardView:SetViewPly(ply)
    local g = self.game
    if not g then return end
    local n = g:Ply()
    if ply and ply < 0 then ply = 0 end
    if ply and ply >= n then ply = nil end
    if ply == self.viewPly then return end
    self.viewPly = ply
    self:ClearSelection(true)
    self:CancelDrag()
    self:CancelPromotion()
    self:StopAnimation()
    self:Refresh()
    if self.onViewChanged then self.onViewChanged(ply) end
end

function BoardView:Step(delta) self:SetViewPly(self:ViewedPly() + delta) end
function BoardView:ViewFirst() self:SetViewPly(0) end
function BoardView:ViewLast() self:SetViewPly(nil) end

-- may the local player act on the board right now?
function BoardView:Interactive()
    local g = self.game
    if not g or g.result or self:IsViewingHistory() then return false end
    return self.canMove ~= nil and self.canMove() == true
end

-- drawing ---------------------------------------------------------------------------------
function BoardView:ApplySkin()
    local style = Theme.BoardStyle()
    local key = tostring(style.name) .. (self.flipped and ":f" or ":w")
    if self.skinKey == key then return end
    self.skinKey = key
    self.frame:SetBackdropColor(style.frame[1], style.frame[2], style.frame[3], 1)
    for i = 1, 64 do
        local slot = self.slots[i]
        local sq = self:SquareAt(slot.col, slot.row)
        local f, r = T.FILE[sq], T.RANK[sq]
        local light = (f + r) % 2 == 1
        local spec = light and style.light or style.dark
        if spec.tex then
            slot.bg:SetTexture(spec.tex)
            -- each square shows a different patch of the grain texture
            local u = ((f * 3 + r * 5) % 4) * 0.25
            local v = ((f * 5 + r * 7) % 4) * 0.25
            slot.bg:SetTexCoord(u, u + 0.25, v, v + 0.25)
            slot.bg:SetVertexColor(1, 1, 1, 1)
        else
            slot.bg:SetTexCoord(0, 1, 0, 1)
            slot.bg:SetColorTexture(spec.color[1], spec.color[2], spec.color[3], 1)
        end
        slot.light = light
    end
    -- coordinate text takes the color of the opposite square shade
    local lightColor = style.light.color or { 0.93, 0.86, 0.72 }
    local darkColor = style.dark.color or { 0.45, 0.32, 0.22 }
    if style.light.tex then lightColor = (style == Theme.BOARDS.stone) and { 0.80, 0.79, 0.74 } or { 0.93, 0.83, 0.66 } end
    if style.dark.tex then darkColor = (style == Theme.BOARDS.stone) and { 0.30, 0.30, 0.33 } or { 0.55, 0.37, 0.23 } end
    for i = 0, 7 do
        local fileIdx = self.flipped and (7 - i) or i
        local rankIdx = self.flipped and (7 - i) or i
        local fl, rl = self.fileLabels[i], self.rankLabels[i]
        fl:SetText(FILES:sub(fileIdx + 1, fileIdx + 1))
        rl:SetText(tostring(rankIdx + 1))
        -- the bottom row slot i and the left column slot i
        local fileSlotLight = self.slots[i + 1].light
        local rankSlotLight = self.slots[i * 8 + 1].light
        local fc = fileSlotLight and darkColor or lightColor
        local rc = rankSlotLight and darkColor or lightColor
        fl:SetTextColor(fc[1], fc[2], fc[3], 0.95)
        rl:SetTextColor(rc[1], rc[2], rc[3], 0.95)
    end
end

function BoardView:Refresh()
    self:StopAnimation(true)
    self:ApplySkin()
    local settings = ns.db.settings
    local showCoords = settings.showCoordinates
    for i = 0, 7 do
        self.fileLabels[i]:SetShown(showCoords)
        self.rankLabels[i]:SetShown(showCoords)
    end

    local b, ply = self:DisplayBoard()
    local g = self.game
    local lastFrom, lastTo
    if b and settings.highlightLastMove and ply > 0 then
        local m = g.moveInts[ply]
        if m then lastFrom, lastTo = Board.MoveFrom(m), Board.MoveTo(m) end
    end
    local checkSq = (b and b:inCheck()) and b.ksq[b.side] or nil
    local interactive = self:Interactive()
    local selected = interactive and self.selected or nil
    local targets = interactive and self.targets or nil
    local showHints = settings.showLegalMoves
    local dragFrom = self.dragging and self.dragFrom or nil

    for i = 1, 64 do
        local slot = self.slots[i]
        local sq = self:SquareAt(slot.col, slot.row)
        local p = b and b.sq[sq] or 0
        if p ~= 0 and p ~= T.OFF and sq ~= dragFrom then
            local tex = Theme.PieceTextureInGame(g, p)
            if slot.pieceTex ~= tex then
                slot.piece:SetTexture(tex)
                slot.pieceTex = tex
            end
            slot.piece:Show()
        else
            slot.piece:Hide()
        end
        slot.mark:SetShown(sq == lastFrom or sq == lastTo)
        slot.sel:SetShown(sq == selected)
        slot.check:SetShown(sq == checkSq)
        local t = targets and targets[sq]
        if t and showHints then
            if t.capture then
                slot.hint:SetTexture(Theme.RING)
                slot.hint:SetVertexColor(C.capture[1], C.capture[2], C.capture[3], C.capture[4])
            else
                slot.hint:SetTexture(Theme.DOT)
                slot.hint:SetVertexColor(C.legal[1], C.legal[2], C.legal[3], C.legal[4])
            end
            slot.hint:Show()
        else
            slot.hint:Hide()
        end
    end
    self.hoverSlot = nil
    self:UpdateHover()
end

-- selection ---------------------------------------------------------------------------------
function BoardView:ClearSelection(noRefresh)
    if not self.selected and not self.targets then return end
    self.selected, self.targets = nil, nil
    if not noRefresh then self:Refresh() end
end

function BoardView:Select(sq)
    local g = self.game
    local moves = g:MovesFrom(sq)
    local targets = {}
    for _, m in ipairs(moves) do
        local to = Board.MoveTo(m)
        local t = targets[to]
        if not t then
            t = { moves = {} }
            targets[to] = t
        end
        t.moves[#t.moves + 1] = m
        if g.board.sq[to] ~= 0 or Board.MoveFlag(m) == FLAG_EP then t.capture = true end
    end
    self.selected, self.targets = sq, targets
    self:Refresh()
end

function BoardView:IsOwnPiece(sq)
    local g = self.game
    local p = g and g.board.sq[sq]
    return p ~= nil and p ~= 0 and T.COLOR[p] == g.localColor
end

-- mouse ----------------------------------------------------------------------------------------
function BoardView:OnMouseDown(button)
    if self.promo:IsShown() then return end
    if button == "RightButton" then
        self:CancelDrag()
        self:ClearSelection()
        return
    end
    if button ~= "LeftButton" then return end
    local sq = self:SquareUnderCursor()
    if not sq or not self:Interactive() then return end

    if self.selected and self.targets and self.targets[sq] then
        self:TryMove(self.selected, sq, true)
        return
    end
    if self:IsOwnPiece(sq) then
        self.toggleOff = (self.selected == sq)
        if not self.toggleOff then self:Select(sq) end
        self.pressSq = sq
        self.pressX, self.pressY = GetCursorPosition()
        return
    end
    self:ClearSelection()
end

function BoardView:OnMouseUp(button)
    if button ~= "LeftButton" or not self.pressSq then return end
    local from = self.pressSq
    self.pressSq = nil
    if self.dragging then
        local to = self:SquareUnderCursor()
        self:EndDrag()
        if to and to ~= from and self.selected == from and self.targets and self.targets[to] and self:Interactive() then
            self:TryMove(from, to, false)
        else
            self:Refresh()
        end
        return
    end
    if self.toggleOff then
        self.toggleOff = nil
        self:ClearSelection()
    end
end

function BoardView:OnUpdate(elapsed)
    if self.anim then self:StepAnimation(elapsed) end
    if self.pressSq then
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
            -- the button was released somewhere we did not hear about
            self:OnMouseUp("LeftButton")
        else
            local x, y = GetCursorPosition()
            if not self.dragging then
                local threshold = DRAG_THRESHOLD * self.board:GetEffectiveScale()
                if abs(x - (self.pressX or x)) + abs(y - (self.pressY or y)) > threshold then
                    self:StartDrag()
                end
            end
            if self.dragging then self:PlaceDragTexture(x, y) end
        end
    end
    if self.mouseInside or self.dragging then self:UpdateHover() end
end

function BoardView:UpdateHover()
    local slotIndex
    if (self.mouseInside or self.dragging) and self:Interactive() then
        local sq, col, row = self:SquareUnderCursor()
        if sq and (self:IsOwnPiece(sq) or (self.targets and self.targets[sq])) then
            slotIndex = row * 8 + col + 1
        end
    end
    if slotIndex == self.hoverSlot then return end
    self.hoverSlot = slotIndex
    if slotIndex then
        local slot = self.slots[slotIndex]
        self.hover:ClearAllPoints()
        self.hover:SetPoint("BOTTOMLEFT", self.board, "BOTTOMLEFT", slot.col * SQ, slot.row * SQ)
        self.hover:Show()
    else
        self.hover:Hide()
    end
end

-- drag and drop ------------------------------------------------------------------------------------
function BoardView:StartDrag()
    local from = self.pressSq
    local g = self.game
    local p = g and g.board.sq[from]
    if not p or p == 0 then return end
    self.dragging = true
    self.dragFrom = from
    self.dragTex:SetTexture(Theme.PieceTextureInGame(g, p))
    self.dragTex:Show()
    local slot = self:SlotOf(from)
    slot.piece:Hide()
end

function BoardView:PlaceDragTexture(x, y)
    local left, bottom = self.board:GetLeft(), self.board:GetBottom()
    if not left or not bottom then return end
    local scale = self.board:GetEffectiveScale()
    self.dragTex:ClearAllPoints()
    self.dragTex:SetPoint("CENTER", self.board, "BOTTOMLEFT", x / scale - left, y / scale - bottom)
end

function BoardView:EndDrag()
    self.dragging = false
    self.dragFrom = nil
    self.dragTex:Hide()
end

function BoardView:CancelDrag()
    local was = self.dragging
    self.pressSq = nil
    self.toggleOff = nil
    if was then
        self:EndDrag()
        self:Refresh()
    end
end

-- making moves ----------------------------------------------------------------------------------------
function BoardView:TryMove(from, to, wasClick)
    local t = self.targets and self.targets[to]
    if not t then return end
    local m = t.moves[1]
    if #t.moves > 1 then
        -- several moves to one square = promotion choices
        if ns.db.settings.autoQueen then
            for _, mv in ipairs(t.moves) do
                if Board.MovePromo(mv) == 5 then m = mv end
            end
        else
            self:ShowPromotion(from, to, t.moves, wasClick)
            return
        end
    end
    self:Submit(m, wasClick)
end

-- The game logic answers an accepted move with GAME_UPDATED, which redraws
-- (and animates) the board, so nothing is drawn after onMove here.
function BoardView:Submit(m, wasClick)
    self:ClearSelection()
    self.lastSubmitWasClick = wasClick and true or false
    if self.onMove then
        self.onMove(Board.MoveToUCI(m), wasClick)
    end
end

function BoardView:ShowPromotion(from, to, moves, wasClick)
    local slot = self:SlotOf(to)
    local col, row = slot.col, slot.row
    local dir = (row >= 4) and -1 or 1
    local color = self.game.localColor
    self.promoChoice = { from = from, to = to, moves = moves, wasClick = wasClick }
    for i, ptype in ipairs(PROMO_ORDER) do
        local b = self.promo.buttons[i]
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", self.board, "BOTTOMLEFT", col * SQ, (row + dir * (i - 1)) * SQ)
        b.icon:SetTexture(Theme.PieceTextureFor(color, ptype))
        b.pieceType = ptype
    end
    self.promo:Show()
end

function BoardView:FinishPromotion(pieceType)
    local c = self.promoChoice
    self.promoChoice = nil
    self.promo:Hide()
    if not c or not self:Interactive() then
        self:ClearSelection()
        return
    end
    for _, m in ipairs(c.moves) do
        if Board.MovePromo(m) == pieceType then
            self:Submit(m, c.wasClick)
            return
        end
    end
end

function BoardView:CancelPromotion()
    if not self.promoChoice and not self.promo:IsShown() then return end
    self.promoChoice = nil
    self.promo:Hide()
end

function BoardView:IsPromoting() return self.promo:IsShown() end

-- animation ---------------------------------------------------------------------------------------------
-- Slide the piece that just arrived on move m's target square.
function BoardView:AnimateMove(m)
    if not m or not ns.db.settings.animateMoves or self:IsViewingHistory() then return end
    if not self.frame:IsVisible() then return end
    local from, to = Board.MoveFrom(m), Board.MoveTo(m)
    local slotTo = self:SlotOf(to)
    local slotFrom = self:SlotOf(from)
    if not slotTo.piece:IsShown() or not slotTo.pieceTex then return end
    self:StopAnimation()
    self.anim = {
        t = 0, slot = slotTo,
        fromX = slotFrom.col * SQ, fromY = slotFrom.row * SQ,
        toX = slotTo.col * SQ, toY = slotTo.row * SQ,
    }
    self.animTex:SetTexture(slotTo.pieceTex)
    slotTo.piece:Hide()
    self.animTex:Show()
    self:PlaceAnimation(0)
end

function BoardView:PlaceAnimation(k)
    local a = self.anim
    self.animTex:ClearAllPoints()
    self.animTex:SetPoint("BOTTOMLEFT", self.board, "BOTTOMLEFT",
        a.fromX + (a.toX - a.fromX) * k + 1, a.fromY + (a.toY - a.fromY) * k + 1)
end

function BoardView:StepAnimation(elapsed)
    local a = self.anim
    a.t = a.t + elapsed
    local k = a.t / ANIM_TIME
    if k >= 1 then
        self:StopAnimation()
        return
    end
    k = 1 - (1 - k) * (1 - k) -- ease out
    self:PlaceAnimation(k)
end

-- skipRestore: the caller redraws everything anyway
function BoardView:StopAnimation(skipRestore)
    local a = self.anim
    if not a then return end
    self.anim = nil
    self.animTex:Hide()
    if not skipRestore then a.slot.piece:Show() end
end

function BoardView:IsAnimating() return self.anim ~= nil end

-- banner --------------------------------------------------------------------------------------------------
function BoardView:ShowBanner(title, sub, color)
    local b = self.banner
    color = color or C.gold
    b.title:SetText(title or "")
    b.title:SetTextColor(color[1], color[2], color[3])
    b.sub:SetText(sub or "")
    b.line1:SetColorTexture(color[1], color[2], color[3], 0.8)
    b.line2:SetColorTexture(color[1], color[2], color[3], 0.8)
    b:Show()
end

function BoardView:HideBanner() self.banner:Hide() end

return BoardView
