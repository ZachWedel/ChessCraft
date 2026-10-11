--[[
    Chess Craft - Chess/Board.lua
    The complete rules of chess: position setup (FEN), pseudo-legal and legal
    move generation (castling, en passant, promotion), make/unmake with an
    undo stack, check detection, draw rules, SAN/UCI notation and perft.

    Written for plain Lua 5.1 (WoW's dialect) with no bit library and no
    per-move allocations, because the bot search runs on the same code.

    Move encoding (an integer):
        from + to * 128 + promoType * 16384 + flag * 131072
        promoType: 0 none, 2 knight, 3 bishop, 4 rook, 5 queen
        flag:      0 normal, 1 double pawn push, 2 en passant, 3 castling
]]

local _, ns = ...
local T = ns.ChessTables

local floor = math.floor
local format = string.format
local tconcat = table.concat

local WHITE, BLACK = T.WHITE, T.BLACK
local OFF = T.OFF
local WP, WN, WB, WR, WQ, WK = 1, 2, 3, 4, 5, 6
local BP, BN, BB, BR, BQ, BK = 7, 8, 9, 10, 11, 12
local COLOR, TYPE = T.COLOR, T.TYPE
local NAME, SQ, RANK, FILE, SQ64 = T.NAME, T.SQ, T.RANK, T.FILE, T.SQ64
local PMG, PEG = T.PMG, T.PEG
local PHASE_WEIGHT = T.PHASE_WEIGHT
local Z1, Z2, ZC1, ZC2, ZEP1, ZEP2 = T.Z1, T.Z2, T.ZC1, T.ZC2, T.ZEP1, T.ZEP2
local ZSIDE1, ZSIDE2 = T.ZSIDE1, T.ZSIDE2
local BAND4, CKEEP = T.BAND4, T.CKEEP

local PROMO_MUL = 16384
local FLAG_MUL = 131072
local F_DOUBLE = 1 * FLAG_MUL
local F_EP = 2 * FLAG_MUL
local F_CASTLE = 3 * FLAG_MUL

local A1, B1, C1, D1, E1, F1, G1, H1 = 22, 23, 24, 25, 26, 27, 28, 29
local A8, B8, C8, D8, E8, F8, G8, H8 = 92, 93, 94, 95, 96, 97, 98, 99

-- phase weight by piece code (array part)
local PHASE = {}
for p = 1, 12 do PHASE[p] = PHASE_WEIGHT[TYPE[p]] end

local UNDO_STRIDE = 13

local Board = {}
Board.__index = Board
ns.Board = Board

Board.START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
Board.F_DOUBLE, Board.F_EP, Board.F_CASTLE = F_DOUBLE, F_EP, F_CASTLE

-- move helpers ----------------------------------------------------------------
local function moveFrom(m) return m % 128 end
local function moveTo(m) return floor(m / 128) % 128 end
local function movePromo(m) return floor(m / PROMO_MUL) % 8 end
local function moveFlag(m) return floor(m / FLAG_MUL) end
Board.MoveFrom, Board.MoveTo, Board.MovePromo, Board.MoveFlag = moveFrom, moveTo, movePromo, moveFlag

function Board.EncodeMove(from, to, promo, flag)
    return from + to * 128 + (promo or 0) * PROMO_MUL + (flag or 0) * FLAG_MUL
end

-- construction ------------------------------------------------------------------
function Board.new(fen)
    local self = setmetatable({}, Board)
    local sq = {}
    for i = 1, 120 do sq[i] = OFF end
    self.sq = sq
    self.count = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    self.ksq = { E1, E8 }
    self.u = {}
    self.hist1, self.hist2 = {}, {}
    self.moveBuf = {}
    self:setFEN(fen or Board.START_FEN)
    return self
end

local function clearBoard(self)
    local sq = self.sq
    for i = 1, 120 do sq[i] = OFF end
    for i = 1, 64 do sq[SQ64[i]] = 0 end
    local count = self.count
    for p = 1, 12 do count[p] = 0 end
    self.side, self.castle, self.ep = WHITE, 0, 0
    self.halfmove, self.fullmove = 0, 1
    self.ply = 0
    self.histLen = 0
end

-- recompute hash and incremental evaluation from scratch
function Board:recompute()
    local sq, count = self.sq, self.count
    local h1, h2, ph, mg, eg, phase = 0, 0, 0, 0, 0, 0
    for p = 1, 12 do count[p] = 0 end
    for i = 1, 64 do
        local s = SQ64[i]
        local p = sq[s]
        if p ~= 0 then
            h1 = h1 + Z1[p][s]; h2 = h2 + Z2[p][s]
            mg = mg + PMG[p][s]; eg = eg + PEG[p][s]
            phase = phase + PHASE[p]
            count[p] = count[p] + 1
            if p == WP or p == BP then ph = ph + Z1[p][s] end
            if p == WK then self.ksq[WHITE] = s elseif p == BK then self.ksq[BLACK] = s end
        end
    end
    h1 = h1 + ZC1[self.castle + 1]; h2 = h2 + ZC2[self.castle + 1]
    if self.ep ~= 0 then h1 = h1 + ZEP1[self.ep]; h2 = h2 + ZEP2[self.ep] end
    if self.side == BLACK then h1 = h1 + ZSIDE1; h2 = h2 + ZSIDE2 end
    self.h1, self.h2, self.ph, self.mg, self.eg, self.phase = h1, h2, ph, mg, eg, phase
end

-- FEN ---------------------------------------------------------------------------
function Board:setFEN(fen)
    if type(fen) ~= "string" then return false, "FEN must be a string" end
    local placement, side, castling, ep, half, full =
        fen:match("^%s*(%S+)%s+([wb])%s+(%S+)%s+(%S+)%s*(%d*)%s*(%d*)%s*$")
    if not placement then return false, "malformed FEN" end
    clearBoard(self)
    local sq = self.sq
    local rank, file = 7, 0
    for i = 1, #placement do
        local c = placement:sub(i, i)
        if c == "/" then
            if file ~= 8 then return false, "bad rank length" end
            rank, file = rank - 1, 0
            if rank < 0 then return false, "too many ranks" end
        elseif c:match("%d") then
            file = file + tonumber(c)
            if file > 8 then return false, "rank overflow" end
        else
            local p = T.CHAR_PIECE[c]
            if not p or file > 7 then return false, "bad piece '" .. c .. "'" end
            sq[22 + file + 10 * rank] = p
            file = file + 1
        end
    end
    if rank ~= 0 or file ~= 8 then return false, "incomplete placement" end

    -- exactly one king each
    local wk, bk = 0, 0
    for i = 1, 64 do
        local p = sq[SQ64[i]]
        if p == WK then wk = wk + 1 elseif p == BK then bk = bk + 1 end
        if (p == WP or p == BP) and (RANK[SQ64[i]] == 0 or RANK[SQ64[i]] == 7) then
            return false, "pawn on back rank"
        end
    end
    if wk ~= 1 or bk ~= 1 then return false, "each side needs exactly one king" end

    self.side = (side == "w") and WHITE or BLACK
    local c = 0
    if castling ~= "-" then
        if castling:find("K") and sq[E1] == WK and sq[H1] == WR then c = c + 1 end
        if castling:find("Q") and sq[E1] == WK and sq[A1] == WR then c = c + 2 end
        if castling:find("k") and sq[E8] == BK and sq[H8] == BR then c = c + 4 end
        if castling:find("q") and sq[E8] == BK and sq[A8] == BR then c = c + 8 end
    end
    self.castle = c
    self.ep = 0
    if ep ~= "-" and SQ[ep] then
        -- keep only if an en passant capture is pseudo-possible (matches makeMove)
        local e = SQ[ep]
        if self.side == WHITE and RANK[e] == 5 and sq[e - 10] == BP and (sq[e - 11] == WP or sq[e - 9] == WP) then
            self.ep = e
        elseif self.side == BLACK and RANK[e] == 2 and sq[e + 10] == WP and (sq[e + 11] == BP or sq[e + 9] == BP) then
            self.ep = e
        end
    end
    self.halfmove = tonumber(half) or 0
    self.fullmove = math.max(1, tonumber(full) or 1)
    self:recompute()
    self.histLen = 1
    self.hist1[1], self.hist2[1] = self.h1, self.h2
    -- the side not to move must not be in check
    if self:isAttacked(self.ksq[3 - self.side], self.side) then
        return false, "side not to move is in check"
    end
    return true
end

function Board:getFEN()
    local sq = self.sq
    local rows = {}
    for rank = 7, 0, -1 do
        local row, empty = {}, 0
        for file = 0, 7 do
            local p = sq[22 + file + 10 * rank]
            if p == 0 then
                empty = empty + 1
            else
                if empty > 0 then row[#row + 1] = tostring(empty); empty = 0 end
                row[#row + 1] = T.PIECE_CHAR[p]
            end
        end
        if empty > 0 then row[#row + 1] = tostring(empty) end
        rows[#rows + 1] = tconcat(row)
    end
    local c = self.castle
    local cs = ""
    if c % 2 == 1 then cs = cs .. "K" end
    if floor(c / 2) % 2 == 1 then cs = cs .. "Q" end
    if floor(c / 4) % 2 == 1 then cs = cs .. "k" end
    if c >= 8 then cs = cs .. "q" end
    if cs == "" then cs = "-" end
    local ep = self.ep ~= 0 and NAME[self.ep] or "-"
    return format("%s %s %s %s %d %d", tconcat(rows, "/"), self.side == WHITE and "w" or "b",
        cs, ep, self.halfmove, self.fullmove)
end

function Board:copyFrom(o)
    local sq, osq = self.sq, o.sq
    for i = 1, 120 do sq[i] = osq[i] end
    local count, ocount = self.count, o.count
    for p = 1, 12 do count[p] = ocount[p] end
    self.ksq[1], self.ksq[2] = o.ksq[1], o.ksq[2]
    self.side, self.castle, self.ep = o.side, o.castle, o.ep
    self.halfmove, self.fullmove = o.halfmove, o.fullmove
    self.h1, self.h2, self.ph = o.h1, o.h2, o.ph
    self.mg, self.eg, self.phase = o.mg, o.eg, o.phase
    self.ply = 0
    -- only positions since the last irreversible move matter for repetition
    local keep = math.min(o.histLen, o.halfmove + 1)
    local first = o.histLen - keep
    local h1, h2, oh1, oh2 = self.hist1, self.hist2, o.hist1, o.hist2
    for i = 1, keep do h1[i] = oh1[first + i]; h2[i] = oh2[first + i] end
    self.histLen = keep
end

function Board:clone()
    local b = Board.new()
    b:copyFrom(self)
    return b
end

-- attacks -------------------------------------------------------------------------
-- Is square s attacked by any piece of color `by`?
function Board:isAttacked(s, by)
    local b = self.sq
    local t, p
    if by == WHITE then
        if b[s - 9] == WP or b[s - 11] == WP then return true end
        if b[s - 21] == WN or b[s - 19] == WN or b[s - 12] == WN or b[s - 8] == WN
            or b[s + 8] == WN or b[s + 12] == WN or b[s + 19] == WN or b[s + 21] == WN then return true end
        if b[s - 11] == WK or b[s - 10] == WK or b[s - 9] == WK or b[s - 1] == WK
            or b[s + 1] == WK or b[s + 9] == WK or b[s + 10] == WK or b[s + 11] == WK then return true end
        t = s - 11; p = b[t]; while p == 0 do t = t - 11; p = b[t] end
        if p == WB or p == WQ then return true end
        t = s - 9; p = b[t]; while p == 0 do t = t - 9; p = b[t] end
        if p == WB or p == WQ then return true end
        t = s + 9; p = b[t]; while p == 0 do t = t + 9; p = b[t] end
        if p == WB or p == WQ then return true end
        t = s + 11; p = b[t]; while p == 0 do t = t + 11; p = b[t] end
        if p == WB or p == WQ then return true end
        t = s - 10; p = b[t]; while p == 0 do t = t - 10; p = b[t] end
        if p == WR or p == WQ then return true end
        t = s - 1; p = b[t]; while p == 0 do t = t - 1; p = b[t] end
        if p == WR or p == WQ then return true end
        t = s + 1; p = b[t]; while p == 0 do t = t + 1; p = b[t] end
        if p == WR or p == WQ then return true end
        t = s + 10; p = b[t]; while p == 0 do t = t + 10; p = b[t] end
        if p == WR or p == WQ then return true end
    else
        if b[s + 9] == BP or b[s + 11] == BP then return true end
        if b[s - 21] == BN or b[s - 19] == BN or b[s - 12] == BN or b[s - 8] == BN
            or b[s + 8] == BN or b[s + 12] == BN or b[s + 19] == BN or b[s + 21] == BN then return true end
        if b[s - 11] == BK or b[s - 10] == BK or b[s - 9] == BK or b[s - 1] == BK
            or b[s + 1] == BK or b[s + 9] == BK or b[s + 10] == BK or b[s + 11] == BK then return true end
        t = s - 11; p = b[t]; while p == 0 do t = t - 11; p = b[t] end
        if p == BB or p == BQ then return true end
        t = s - 9; p = b[t]; while p == 0 do t = t - 9; p = b[t] end
        if p == BB or p == BQ then return true end
        t = s + 9; p = b[t]; while p == 0 do t = t + 9; p = b[t] end
        if p == BB or p == BQ then return true end
        t = s + 11; p = b[t]; while p == 0 do t = t + 11; p = b[t] end
        if p == BB or p == BQ then return true end
        t = s - 10; p = b[t]; while p == 0 do t = t - 10; p = b[t] end
        if p == BR or p == BQ then return true end
        t = s - 1; p = b[t]; while p == 0 do t = t - 1; p = b[t] end
        if p == BR or p == BQ then return true end
        t = s + 1; p = b[t]; while p == 0 do t = t + 1; p = b[t] end
        if p == BR or p == BQ then return true end
        t = s + 10; p = b[t]; while p == 0 do t = t + 10; p = b[t] end
        if p == BR or p == BQ then return true end
    end
    return false
end

function Board:inCheck(side)
    side = side or self.side
    return self:isAttacked(self.ksq[side], 3 - side)
end

-- move generation -------------------------------------------------------------------
local KNIGHT_OFF = { -21, -19, -12, -8, 8, 12, 19, 21 }
local KING_OFF = { -11, -10, -9, -1, 1, 9, 10, 11 }
local SLIDE_DIRS = {
    [3] = { -11, -9, 9, 11 },
    [4] = { -10, -1, 1, 10 },
    [5] = { -11, -10, -9, -1, 1, 9, 10, 11 },
}

local function addPromos(list, n, from, to, flag)
    local base = from + to * 128 + (flag or 0)
    list[n + 1] = base + 5 * PROMO_MUL
    list[n + 2] = base + 4 * PROMO_MUL
    list[n + 3] = base + 3 * PROMO_MUL
    list[n + 4] = base + 2 * PROMO_MUL
    return n + 4
end

-- Fill `list` with pseudo-legal moves for the side to move; returns count.
-- capturesOnly: captures and promotions only (quiescence search).
function Board:generate(list, capturesOnly)
    local b = self.sq
    local side = self.side
    local enemy = 3 - side
    local ep = self.ep
    local n = 0
    for i = 1, 64 do
        local s = SQ64[i]
        local p = b[s]
        if p ~= 0 and COLOR[p] == side then
            local t = TYPE[p]
            if t == 1 then
                local fwd, lastRank, startRank
                if side == WHITE then fwd, lastRank, startRank = 10, 7, 1 else fwd, lastRank, startRank = -10, 0, 6 end
                -- captures (diagonals)
                local c = s + fwd - 1
                local q = b[c]
                if q ~= 0 and COLOR[q] == enemy then
                    if RANK[c] == lastRank then n = addPromos(list, n, s, c)
                    else n = n + 1; list[n] = s + c * 128 end
                elseif c == ep and ep ~= 0 then
                    n = n + 1; list[n] = s + c * 128 + F_EP
                end
                c = s + fwd + 1
                q = b[c]
                if q ~= 0 and COLOR[q] == enemy then
                    if RANK[c] == lastRank then n = addPromos(list, n, s, c)
                    else n = n + 1; list[n] = s + c * 128 end
                elseif c == ep and ep ~= 0 then
                    n = n + 1; list[n] = s + c * 128 + F_EP
                end
                -- pushes
                local one = s + fwd
                if b[one] == 0 then
                    if RANK[one] == lastRank then
                        if capturesOnly then
                            n = n + 1; list[n] = s + one * 128 + 5 * PROMO_MUL
                        else
                            n = addPromos(list, n, s, one)
                        end
                    elseif not capturesOnly then
                        n = n + 1; list[n] = s + one * 128
                        if RANK[s] == startRank and b[one + fwd] == 0 then
                            n = n + 1; list[n] = s + (one + fwd) * 128 + F_DOUBLE
                        end
                    end
                end
            elseif t == 2 or t == 6 then
                local offs = (t == 2) and KNIGHT_OFF or KING_OFF
                for k = 1, 8 do
                    local d = s + offs[k]
                    local q = b[d]
                    if q == 0 then
                        if not capturesOnly then n = n + 1; list[n] = s + d * 128 end
                    elseif COLOR[q] == enemy then
                        n = n + 1; list[n] = s + d * 128
                    end
                end
                if t == 6 and not capturesOnly and self.castle ~= 0 then
                    local c = self.castle
                    if side == WHITE and s == E1 then
                        if c % 2 == 1 and b[F1] == 0 and b[G1] == 0 and b[H1] == WR
                            and not self:isAttacked(E1, BLACK) and not self:isAttacked(F1, BLACK) then
                            n = n + 1; list[n] = E1 + G1 * 128 + F_CASTLE
                        end
                        if floor(c / 2) % 2 == 1 and b[D1] == 0 and b[C1] == 0 and b[B1] == 0 and b[A1] == WR
                            and not self:isAttacked(E1, BLACK) and not self:isAttacked(D1, BLACK) then
                            n = n + 1; list[n] = E1 + C1 * 128 + F_CASTLE
                        end
                    elseif side == BLACK and s == E8 then
                        if floor(c / 4) % 2 == 1 and b[F8] == 0 and b[G8] == 0 and b[H8] == BR
                            and not self:isAttacked(E8, WHITE) and not self:isAttacked(F8, WHITE) then
                            n = n + 1; list[n] = E8 + G8 * 128 + F_CASTLE
                        end
                        if c >= 8 and b[D8] == 0 and b[C8] == 0 and b[B8] == 0 and b[A8] == BR
                            and not self:isAttacked(E8, WHITE) and not self:isAttacked(D8, WHITE) then
                            n = n + 1; list[n] = E8 + C8 * 128 + F_CASTLE
                        end
                    end
                end
            else
                local dirs = SLIDE_DIRS[t]
                for k = 1, #dirs do
                    local d = dirs[k]
                    local to = s + d
                    local q = b[to]
                    while q == 0 do
                        if not capturesOnly then n = n + 1; list[n] = s + to * 128 end
                        to = to + d
                        q = b[to]
                    end
                    if COLOR[q] == enemy then n = n + 1; list[n] = s + to * 128 end
                end
            end
        end
    end
    return n
end

-- make / unmake -------------------------------------------------------------------
-- Plays move m. Returns true if legal; if the move would leave the mover's
-- king in check it is taken back and false is returned.
function Board:makeMove(m)
    local sq = self.sq
    local from = m % 128
    local to = floor(m / 128) % 128
    local hi = floor(m / PROMO_MUL)
    local promo = hi % 8
    local flag = floor(hi / 8)
    local side = self.side
    local p = sq[from]
    local cap, capSq = sq[to], to
    if flag == 2 then
        capSq = (side == WHITE) and (to - 10) or (to + 10)
        cap = sq[capSq]
    end

    local ply = self.ply + 1
    self.ply = ply
    local u = self.u
    local base = ply * UNDO_STRIDE
    u[base + 1] = m; u[base + 2] = cap; u[base + 3] = self.castle; u[base + 4] = self.ep
    u[base + 5] = self.halfmove; u[base + 6] = self.h1; u[base + 7] = self.h2
    u[base + 8] = self.mg; u[base + 9] = self.eg; u[base + 10] = self.phase
    u[base + 11] = self.ph; u[base + 12] = capSq; u[base + 13] = p

    local h1, h2, mg, eg, ph = self.h1, self.h2, self.mg, self.eg, self.ph
    local count = self.count

    -- lift the moving piece
    h1 = h1 - Z1[p][from]; h2 = h2 - Z2[p][from]
    mg = mg - PMG[p][from]; eg = eg - PEG[p][from]
    sq[from] = 0
    local isPawn = (p == WP or p == BP)
    if isPawn then ph = ph - Z1[p][from] end

    -- remove a captured piece
    if cap ~= 0 then
        h1 = h1 - Z1[cap][capSq]; h2 = h2 - Z2[cap][capSq]
        mg = mg - PMG[cap][capSq]; eg = eg - PEG[cap][capSq]
        self.phase = self.phase - PHASE[cap]
        count[cap] = count[cap] - 1
        if cap == WP or cap == BP then ph = ph - Z1[cap][capSq] end
        sq[capSq] = 0
    end

    -- drop the piece (promoting if needed)
    local placed = p
    if promo ~= 0 then
        placed = (side == WHITE) and promo or (promo + 6)
        count[p] = count[p] - 1
        count[placed] = count[placed] + 1
        self.phase = self.phase + PHASE[placed]
    elseif isPawn then
        ph = ph + Z1[p][to]
    end
    sq[to] = placed
    h1 = h1 + Z1[placed][to]; h2 = h2 + Z2[placed][to]
    mg = mg + PMG[placed][to]; eg = eg + PEG[placed][to]

    -- castling moves the rook too
    if flag == 3 then
        local rook, rf, rt
        if to == G1 then rook, rf, rt = WR, H1, F1
        elseif to == C1 then rook, rf, rt = WR, A1, D1
        elseif to == G8 then rook, rf, rt = BR, H8, F8
        else rook, rf, rt = BR, A8, D8 end
        sq[rf] = 0; sq[rt] = rook
        h1 = h1 - Z1[rook][rf] + Z1[rook][rt]; h2 = h2 - Z2[rook][rf] + Z2[rook][rt]
        mg = mg - PMG[rook][rf] + PMG[rook][rt]; eg = eg - PEG[rook][rf] + PEG[rook][rt]
    end

    if p == WK then self.ksq[WHITE] = to elseif p == BK then self.ksq[BLACK] = to end

    -- castling rights
    local c = self.castle
    if c ~= 0 then
        local nc = c
        local keep = CKEEP[from]
        if keep then nc = BAND4[nc * 16 + keep + 1] end
        keep = CKEEP[to]
        if keep then nc = BAND4[nc * 16 + keep + 1] end
        if nc ~= c then
            h1 = h1 - ZC1[c + 1] + ZC1[nc + 1]; h2 = h2 - ZC2[c + 1] + ZC2[nc + 1]
            self.castle = nc
        end
    end

    -- en passant target (only recorded when a capture is pseudo-possible)
    local oldEp = self.ep
    if oldEp ~= 0 then h1 = h1 - ZEP1[oldEp]; h2 = h2 - ZEP2[oldEp] end
    local newEp = 0
    if flag == 1 then
        local enemyPawn = (side == WHITE) and BP or WP
        if sq[to - 1] == enemyPawn or sq[to + 1] == enemyPawn then
            newEp = (from + to) / 2
            h1 = h1 + ZEP1[newEp]; h2 = h2 + ZEP2[newEp]
        end
    end
    self.ep = newEp

    if cap ~= 0 or isPawn then self.halfmove = 0 else self.halfmove = self.halfmove + 1 end
    if side == WHITE then
        h1 = h1 + ZSIDE1; h2 = h2 + ZSIDE2
    else
        h1 = h1 - ZSIDE1; h2 = h2 - ZSIDE2
        self.fullmove = self.fullmove + 1
    end
    self.side = 3 - side
    self.h1, self.h2, self.mg, self.eg, self.ph = h1, h2, mg, eg, ph

    local hl = self.histLen + 1
    self.histLen = hl
    self.hist1[hl], self.hist2[hl] = h1, h2

    if self:isAttacked(self.ksq[side], 3 - side) then
        self:unmakeMove()
        return false
    end
    return true
end

function Board:unmakeMove()
    local ply = self.ply
    if ply <= 0 then return false end
    local u = self.u
    local base = ply * UNDO_STRIDE
    local m = u[base + 1]
    local sq = self.sq
    self.side = 3 - self.side
    local side = self.side
    if side == BLACK then self.fullmove = self.fullmove - 1 end
    self.histLen = self.histLen - 1
    self.ply = ply - 1
    self.castle, self.ep, self.halfmove = u[base + 3], u[base + 4], u[base + 5]
    self.h1, self.h2, self.mg, self.eg = u[base + 6], u[base + 7], u[base + 8], u[base + 9]
    self.phase, self.ph = u[base + 10], u[base + 11]
    if m == 0 then return true end -- null move

    local from = m % 128
    local to = floor(m / 128) % 128
    local hi = floor(m / PROMO_MUL)
    local promo = hi % 8
    local flag = floor(hi / 8)
    local cap, capSq, p = u[base + 2], u[base + 12], u[base + 13]
    local count = self.count

    if promo ~= 0 then
        local placed = sq[to]
        count[placed] = count[placed] - 1
        count[p] = count[p] + 1
    end
    sq[from] = p
    sq[to] = 0
    if cap ~= 0 then
        sq[capSq] = cap
        count[cap] = count[cap] + 1
    end
    if flag == 3 then
        if to == G1 then sq[H1] = WR; sq[F1] = 0
        elseif to == C1 then sq[A1] = WR; sq[D1] = 0
        elseif to == G8 then sq[H8] = BR; sq[F8] = 0
        else sq[A8] = BR; sq[D8] = 0 end
    end
    if p == WK then self.ksq[WHITE] = from elseif p == BK then self.ksq[BLACK] = from end
    return true
end

-- Null move (pass) for null-move pruning in search. Not legal in chess!
function Board:makeNullMove()
    local ply = self.ply + 1
    self.ply = ply
    local u = self.u
    local base = ply * UNDO_STRIDE
    u[base + 1] = 0; u[base + 2] = 0; u[base + 3] = self.castle; u[base + 4] = self.ep
    u[base + 5] = self.halfmove; u[base + 6] = self.h1; u[base + 7] = self.h2
    u[base + 8] = self.mg; u[base + 9] = self.eg; u[base + 10] = self.phase
    u[base + 11] = self.ph; u[base + 12] = 0; u[base + 13] = 0
    local h1, h2 = self.h1, self.h2
    if self.ep ~= 0 then h1 = h1 - ZEP1[self.ep]; h2 = h2 - ZEP2[self.ep]; self.ep = 0 end
    if self.side == WHITE then h1 = h1 + ZSIDE1; h2 = h2 + ZSIDE2
    else h1 = h1 - ZSIDE1; h2 = h2 - ZSIDE2; self.fullmove = self.fullmove + 1 end
    self.halfmove = self.halfmove + 1
    self.side = 3 - self.side
    self.h1, self.h2 = h1, h2
    local hl = self.histLen + 1
    self.histLen = hl
    self.hist1[hl], self.hist2[hl] = h1, h2
end
Board.unmakeNullMove = Board.unmakeMove

-- legal move helpers ----------------------------------------------------------------
-- Returns a new array of legal moves.
function Board:legalMoves()
    local buf = {}
    local n = self:generate(buf, false)
    local out = {}
    for i = 1, n do
        local m = buf[i]
        if self:makeMove(m) then
            self:unmakeMove()
            out[#out + 1] = m
        end
    end
    return out
end

function Board:hasLegalMove()
    local buf = self.moveBuf
    local n = self:generate(buf, false)
    for i = 1, n do
        if self:makeMove(buf[i]) then
            self:unmakeMove()
            return true
        end
    end
    return false
end

function Board:isLegal(m)
    local moves = self:legalMoves()
    for i = 1, #moves do if moves[i] == m then return true end end
    return false
end

-- draw rules ------------------------------------------------------------------------
-- Number of times the current position has occurred (same side to move,
-- castling rights and en passant), counting the current occurrence.
function Board:repetitionCount()
    local hl = self.histLen
    local h1, h2 = self.h1, self.h2
    local hist1, hist2 = self.hist1, self.hist2
    local n = 1
    local stop = math.max(1, hl - self.halfmove)
    local i = hl - 2
    while i >= stop do
        if hist1[i] == h1 and hist2[i] == h2 then n = n + 1 end
        i = i - 2
    end
    return n
end

-- Fast 2-fold check used inside the search.
function Board:isRepeated()
    local hl = self.histLen
    local h1, h2 = self.h1, self.h2
    local hist1, hist2 = self.hist1, self.hist2
    local stop = hl - self.halfmove
    if stop < 1 then stop = 1 end
    local i = hl - 4
    while i >= stop do
        if hist1[i] == h1 and hist2[i] == h2 then return true end
        i = i - 2
    end
    return false
end

local function bishopSquareColor(s) return (FILE[s] + RANK[s]) % 2 end

-- FIDE dead position (approximation used by most servers):
-- K v K, K+minor v K, and bishops-only positions where all bishops share a color.
function Board:isInsufficientMaterial()
    local c = self.count
    if c[WP] + c[BP] + c[WR] + c[BR] + c[WQ] + c[BQ] > 0 then return false end
    local knights = c[WN] + c[BN]
    local bishops = c[WB] + c[BB]
    if knights + bishops <= 1 then return true end
    if knights == 0 then
        local color
        local sq = self.sq
        for i = 1, 64 do
            local s = SQ64[i]
            local p = sq[s]
            if p == WB or p == BB then
                local bc = bishopSquareColor(s)
                if color == nil then color = bc elseif color ~= bc then return false end
            end
        end
        return true
    end
    return false
end

-- Could `side` deliver mate by some sequence of legal moves? Used when a flag
-- falls: if the opponent cannot possibly mate, the game is drawn.
function Board:hasMatingMaterial(side)
    local c = self.count
    local P, N, B, R, Q
    if side == WHITE then P, N, B, R, Q = c[WP], c[WN], c[WB], c[WR], c[WQ]
    else P, N, B, R, Q = c[BP], c[BN], c[BB], c[BR], c[BQ] end
    if P + R + Q > 0 then return true end
    local minors = N + B
    if minors == 0 then return false end
    local o = 3 - side
    local oppMaterial
    if o == WHITE then oppMaterial = c[WP] + c[WN] + c[WB] + c[WR] + c[WQ]
    else oppMaterial = c[BP] + c[BN] + c[BB] + c[BR] + c[BQ] end
    if minors == 1 then return oppMaterial > 0 end -- helpmate needs an enemy blocker
    if N == 0 then
        -- bishops only: need both square colors unless the opponent can block
        if oppMaterial > 0 then return true end
        local sq, seen0, seen1 = self.sq, false, false
        local mine = (side == WHITE) and WB or BB
        for i = 1, 64 do
            local s = SQ64[i]
            if sq[s] == mine then
                if bishopSquareColor(s) == 0 then seen0 = true else seen1 = true end
            end
        end
        return seen0 and seen1
    end
    return true
end

-- Game status for the side to move:
-- "ongoing", "checkmate", "stalemate", "fifty", "repetition", "material"
function Board:status()
    if not self:hasLegalMove() then
        return self:inCheck() and "checkmate" or "stalemate"
    end
    if self:isInsufficientMaterial() then return "material" end
    if self.halfmove >= 100 then return "fifty" end
    if self:repetitionCount() >= 3 then return "repetition" end
    return "ongoing"
end

-- notation ----------------------------------------------------------------------------
local PROMO_CHAR = { [2] = "n", [3] = "b", [4] = "r", [5] = "q" }
local PROMO_FROM_CHAR = { n = 2, b = 3, r = 4, q = 5 }
local SAN_LETTER = { [2] = "N", [3] = "B", [4] = "R", [5] = "Q", [6] = "K" }

function Board.MoveToUCI(m)
    local promo = movePromo(m)
    return NAME[moveFrom(m)] .. NAME[moveTo(m)] .. (PROMO_CHAR[promo] or "")
end

-- Find the legal move matching a UCI string ("e2e4", "e7e8q"); nil if illegal.
function Board:uciToMove(uci)
    if type(uci) ~= "string" then return nil end
    local f, t, pr = uci:lower():match("^([a-h][1-8])([a-h][1-8])([nbrq]?)$")
    if not f then return nil end
    local from, to = SQ[f], SQ[t]
    local promo = PROMO_FROM_CHAR[pr] or 0
    local moves = self:legalMoves()
    for i = 1, #moves do
        local m = moves[i]
        if moveFrom(m) == from and moveTo(m) == to and movePromo(m) == promo then return m end
    end
    return nil
end

-- Standard algebraic notation for a legal move in the current position.
function Board:moveToSAN(m, legal)
    legal = legal or self:legalMoves()
    local from, to = moveFrom(m), moveTo(m)
    local flag, promo = moveFlag(m), movePromo(m)
    local p = self.sq[from]
    local t = TYPE[p]
    local san
    if flag == 3 then
        san = (FILE[to] == 6) and "O-O" or "O-O-O"
    else
        local capture = self.sq[to] ~= 0 or flag == 2
        if t == 1 then
            san = capture and (string.char(97 + FILE[from]) .. "x" .. NAME[to]) or NAME[to]
            if promo ~= 0 then san = san .. "=" .. SAN_LETTER[promo] end
        else
            local needFile, needRank, ambiguous = false, false, false
            for i = 1, #legal do
                local o = legal[i]
                local of = moveFrom(o)
                if o ~= m and moveTo(o) == to and of ~= from and self.sq[of] == p then
                    ambiguous = true
                    if FILE[of] == FILE[from] then needRank = true else needFile = true end
                end
            end
            if ambiguous and not needFile and not needRank then needFile = true end
            local dis = ""
            if needFile then dis = string.char(97 + FILE[from]) end
            if needRank then dis = dis .. tostring(RANK[from] + 1) end
            san = SAN_LETTER[t] .. dis .. (capture and "x" or "") .. NAME[to]
        end
    end
    if self:makeMove(m) then
        if self:inCheck() then
            san = san .. (self:hasLegalMove() and "+" or "#")
        end
        self:unmakeMove()
    end
    return san
end

-- Parse SAN ("Nf3", "exd5", "O-O", "e8=Q+") into a legal move; nil if invalid.
function Board:sanToMove(san)
    if type(san) ~= "string" then return nil end
    local s = san:gsub("[+#!?]", ""):gsub("0", "O")
    local legal = self:legalMoves()
    for i = 1, #legal do
        local m = legal[i]
        local mine = self:moveToSAN(m, legal):gsub("[+#]", "")
        if mine == s then return m end
    end
    return nil
end

-- misc helpers --------------------------------------------------------------------------
function Board:pieceAt(s) return self.sq[s] end

-- Short, deterministic text fingerprint of the position (desync detection).
function Board:hashString()
    local v = self.h1 % 2176782336 -- 36^6
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = {}
    for i = 6, 1, -1 do
        local d = v % 36
        out[i] = digits:sub(d + 1, d + 1)
        v = floor(v / 36)
    end
    return tconcat(out)
end

-- Count leaf nodes to a given depth (move generator correctness test).
function Board:perft(depth, lists)
    if depth == 0 then return 1 end
    lists = lists or {}
    local list = lists[depth]
    if not list then list = {}; lists[depth] = list end
    local n = self:generate(list, false)
    local nodes = 0
    for i = 1, n do
        if self:makeMove(list[i]) then
            if depth == 1 then nodes = nodes + 1
            else nodes = nodes + self:perft(depth - 1, lists) end
            self:unmakeMove()
        end
    end
    return nodes
end

function Board:toString()
    local lines = {}
    for rank = 7, 0, -1 do
        local row = {}
        for file = 0, 7 do row[#row + 1] = T.PIECE_CHAR[self.sq[22 + file + 10 * rank]] end
        lines[#lines + 1] = (rank + 1) .. " " .. tconcat(row, " ")
    end
    lines[#lines + 1] = "  a b c d e f g h"
    return tconcat(lines, "\n")
end

return Board
