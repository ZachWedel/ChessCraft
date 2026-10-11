--[[
    Chess Craft - AI/Search.lua
    Alpha-beta (PVS) search with iterative deepening, quiescence search,
    transposition table, null-move pruning, late move reductions, killer and
    history move ordering.

    The search runs inside a coroutine and yields whenever its per-frame time
    slice is used up, so the game client keeps rendering smoothly and WoW's
    "script ran too long" watchdog is never triggered. Strength is governed by
    a CPU-time budget (not wall time), so bots play the same on fast and slow
    machines; only how long the wait feels changes.
]]

local _, ns = ...
local T = ns.ChessTables
local Board = ns.Board
local evaluate = ns.Eval.evaluate

local floor = math.floor
local TYPE = T.TYPE
local VAL = T.VALUE

local INF = 1000000
local MATE = 100000
local MATE_IN_MAX = MATE - 1000
local MAXPLY = 64
local TT_SIZE = 32768
local EXACT, LOWER, UPPER = 1, 2, 3
local HIST_SIZE = 13 * 128

local function defaultClock() return os.clock() * 1000 end

local Search = {}
Search.__index = Search
ns.Search = Search
Search.MATE, Search.MATE_IN_MAX, Search.INF = MATE, MATE_IN_MAX, INF

function Search.new()
    local self = setmetatable({}, Search)
    self.board = Board.new()
    self.moves, self.scores = {}, {}
    self.killer1, self.killer2 = {}, {}
    for i = 0, MAXPLY + 2 do
        self.moves[i], self.scores[i] = {}, {}
        self.killer1[i], self.killer2[i] = 0, 0
    end
    local hist = {}
    for i = 1, HIST_SIZE do hist[i] = 0 end
    self.history = hist
    self.nodes = 0
    return self
end

-- Transposition table: five parallel arrays, allocated on first use and
-- released with freeMemory() when no bot game is running (~2.5 MB).
function Search:allocTT()
    if self.ttKey then return end
    local k, m, s, d, f = {}, {}, {}, {}, {}
    for i = 1, TT_SIZE do k[i] = -1; m[i] = 0; s[i] = 0; d[i] = -1; f[i] = 0 end
    self.ttKey, self.ttMove, self.ttScore, self.ttDepth, self.ttFlag = k, m, s, d, f
end

function Search:clearTT()
    if not self.ttKey then return end
    local k, d = self.ttKey, self.ttDepth
    for i = 1, TT_SIZE do k[i] = -1; d[i] = -1 end
end

function Search:freeMemory()
    self.ttKey, self.ttMove, self.ttScore, self.ttDepth, self.ttFlag = nil, nil, nil, nil, nil
    self.co = nil
    ns.Eval.clearCache()
end

-- time management -----------------------------------------------------------------
function Search:checkTime()
    local clock = self.clock
    local now = clock()
    local spent = now - self.sliceStart
    if self.cpuUsed + spent >= self.cpuBudget and self.canStop then
        self.stop = true
        return
    end
    if self.yieldable and spent >= self.sliceBudget then
        self.cpuUsed = self.cpuUsed + spent
        coroutine.yield()
        -- step() has reset sliceStart/sliceBudget before resuming us
        if self.abortFlag then self.stop = true end
    end
end

-- quiescence -----------------------------------------------------------------------
function Search:quiesce(alpha, beta, ply)
    local nodes = self.nodes + 1
    self.nodes = nodes
    if nodes % 256 == 0 then self:checkTime() end
    if self.stop then return 0 end

    local b = self.board
    local side = b.side
    local inCheck = b:isAttacked(b.ksq[side], 3 - side)
    if ply >= MAXPLY then return evaluate(b) end

    local moves, scores = self.moves[ply], self.scores[ply]
    local sq = b.sq
    local n, stand

    if inCheck then
        -- no standing pat while in check: look at every evasion
        n = b:generate(moves, false)
        stand = -INF
        for i = 1, n do
            local m = moves[i]
            local victim = sq[floor(m / 128) % 128]
            scores[i] = (victim ~= 0) and (VAL[TYPE[victim]] * 16 - TYPE[sq[m % 128]]) or 0
        end
    else
        stand = evaluate(b)
        if stand >= beta then return stand end
        if stand > alpha then alpha = stand end
        n = b:generate(moves, true)
        for i = 1, n do
            local m = moves[i]
            local victim = sq[floor(m / 128) % 128]
            local s = ((victim ~= 0) and VAL[TYPE[victim]] or 100) * 16 - TYPE[sq[m % 128]]
            if floor(m / 16384) % 8 ~= 0 then s = s + 12800 end
            scores[i] = s
        end
    end

    local legal = 0
    for i = 1, n do
        local bi, bs = i, scores[i]
        for j = i + 1, n do
            if scores[j] > bs then bi, bs = j, scores[j] end
        end
        local m = moves[bi]
        if bi ~= i then
            moves[bi] = moves[i]; moves[i] = m
            scores[bi] = scores[i]; scores[i] = bs
        end

        local skip = false
        if not inCheck then
            -- delta pruning: even winning this piece cannot lift us above alpha
            local victim = sq[floor(m / 128) % 128]
            local gain = (victim ~= 0) and VAL[TYPE[victim]] or 100
            if floor(m / 16384) % 8 ~= 0 then gain = gain + 800 end
            if stand + gain + 200 <= alpha then skip = true end
        end

        if not skip and b:makeMove(m) then
            legal = legal + 1
            local score = -self:quiesce(-beta, -alpha, ply + 1)
            b:unmakeMove()
            if self.stop then return 0 end
            if score > stand then stand = score end
            if score > alpha then
                if score >= beta then return score end
                alpha = score
            end
        end
    end

    if inCheck and legal == 0 then return -MATE + ply end
    return stand > alpha and stand or alpha
end

-- main search ----------------------------------------------------------------------
function Search:negamax(depth, alpha, beta, ply, allowNull)
    local nodes = self.nodes + 1
    self.nodes = nodes
    if nodes % 256 == 0 then self:checkTime() end
    if self.stop then return 0 end

    local b = self.board
    local c = b.count

    if ply > 0 then
        if b.halfmove >= 100 or b:isRepeated() then return 0 end
        if c[1] + c[7] + c[4] + c[10] + c[5] + c[11] == 0 and c[2] + c[3] + c[8] + c[9] <= 1 then return 0 end
        -- mate distance pruning
        local mated = -MATE + ply
        if alpha < mated then
            alpha = mated
            if beta <= alpha then return alpha end
        end
        local mating = MATE - ply - 1
        if beta > mating then
            beta = mating
            if alpha >= beta then return beta end
        end
    end

    local side = b.side
    local inCheck = b:isAttacked(b.ksq[side], 3 - side)
    if inCheck then depth = depth + 1 end
    if depth <= 0 then
        if self.noQuiesce then return evaluate(b) end
        return self:quiesce(alpha, beta, ply)
    end
    if ply >= MAXPLY then return evaluate(b) end

    -- transposition table probe
    local ttKey, ttMoveT, ttScoreT, ttDepthT, ttFlagT = self.ttKey, self.ttMove, self.ttScore, self.ttDepth, self.ttFlag
    local idx = b.h1 % TT_SIZE + 1
    local h2 = b.h2
    local hashMove = 0
    if ttKey[idx] == h2 then
        hashMove = ttMoveT[idx]
        if ply > 0 and ttDepthT[idx] >= depth then
            local s = ttScoreT[idx]
            if s > MATE_IN_MAX then s = s - ply elseif s < -MATE_IN_MAX then s = s + ply end
            local f = ttFlagT[idx]
            if f == EXACT then return s end
            if f == LOWER and s >= beta then return s end
            if f == UPPER and s <= alpha then return s end
        end
    end

    -- null-move pruning
    if allowNull and not inCheck and ply > 0 and depth >= 3 and beta < MATE_IN_MAX and beta > -MATE_IN_MAX then
        local nonPawn = (side == 1) and (c[2] + c[3] + c[4] + c[5]) or (c[8] + c[9] + c[10] + c[11])
        if nonPawn > 0 and evaluate(b) >= beta then
            local R = (depth >= 6) and 3 or 2
            b:makeNullMove()
            local score = -self:negamax(depth - 1 - R, -beta, -beta + 1, ply + 1, false)
            b:unmakeMove()
            if self.stop then return 0 end
            if score >= beta then
                if score > MATE_IN_MAX then score = beta end
                return score
            end
        end
    end

    -- generate and score moves
    local moves, scores = self.moves[ply], self.scores[ply]
    local n = b:generate(moves, false)
    local sq = b.sq
    local k1, k2 = self.killer1[ply], self.killer2[ply]
    local hist = self.history
    for i = 1, n do
        local m = moves[i]
        local s
        if m == hashMove then
            s = 10000000
        else
            local to = floor(m / 128) % 128
            local victim = sq[to]
            local hi = floor(m / 16384)
            if victim ~= 0 then
                s = 1000000 + VAL[TYPE[victim]] * 16 - TYPE[sq[m % 128]]
            elseif hi % 8 ~= 0 then
                s = 950000 + hi % 8
            elseif hi == 16 then -- en passant (flag 2, promo 0)
                s = 1000000 + 1600 - 1
            elseif m == k1 then
                s = 900000
            elseif m == k2 then
                s = 800000
            else
                s = hist[sq[m % 128] * 128 + to]
            end
        end
        scores[i] = s
    end

    local bestScore, bestMove = -INF, 0
    local legal = 0
    local origAlpha = alpha
    for i = 1, n do
        local bi, bs = i, scores[i]
        for j = i + 1, n do
            if scores[j] > bs then bi, bs = j, scores[j] end
        end
        local m = moves[bi]
        if bi ~= i then
            moves[bi] = moves[i]; moves[i] = m
            scores[bi] = scores[i]; scores[i] = bs
        end

        local from = m % 128
        local to = floor(m / 128) % 128
        local mover = sq[from]
        local quiet = (sq[to] == 0) and (floor(m / 16384) % 8 == 0) and (floor(m / 131072) ~= 2)

        if b:makeMove(m) then
            legal = legal + 1
            local score
            if legal == 1 then
                score = -self:negamax(depth - 1, -beta, -alpha, ply + 1, true)
            else
                local reduction = 0
                if depth >= 3 and legal > 3 and quiet and not inCheck and m ~= k1 and m ~= k2 then
                    reduction = (legal > 8 and depth >= 5) and 2 or 1
                    if b:isAttacked(b.ksq[b.side], side) then reduction = 0 end -- gives check
                end
                score = -self:negamax(depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, true)
                if score > alpha and reduction > 0 then
                    score = -self:negamax(depth - 1, -alpha - 1, -alpha, ply + 1, true)
                end
                if score > alpha and score < beta then
                    score = -self:negamax(depth - 1, -beta, -alpha, ply + 1, true)
                end
            end
            b:unmakeMove()
            if self.stop then return 0 end

            if score > bestScore then
                bestScore, bestMove = score, m
                if ply == 0 then self.rootBest, self.rootScore = m, score end
                if score > alpha then
                    alpha = score
                    if score >= beta then
                        if quiet then
                            if m ~= k1 then self.killer2[ply] = k1; self.killer1[ply] = m end
                            local hidx = mover * 128 + to
                            local hv = hist[hidx] + depth * depth
                            if hv > 200000 then
                                for h = 1, HIST_SIZE do hist[h] = floor(hist[h] / 2) end
                                hv = floor(hv / 2)
                            end
                            hist[hidx] = hv
                        end
                        break
                    end
                end
            end
        end
    end

    if legal == 0 then
        if inCheck then return -MATE + ply end
        return 0
    end

    local flag
    if bestScore <= origAlpha then flag = UPPER elseif bestScore >= beta then flag = LOWER else flag = EXACT end
    local store = bestScore
    if store > MATE_IN_MAX then store = store + ply elseif store < -MATE_IN_MAX then store = store - ply end
    if ttKey[idx] ~= h2 or depth >= ttDepthT[idx] then
        ttKey[idx] = h2; ttMoveT[idx] = bestMove; ttScoreT[idx] = store
        ttDepthT[idx] = depth; ttFlagT[idx] = flag
    end
    return bestScore
end

-- drivers ------------------------------------------------------------------------------
-- Iterative deepening; returns best move, score and depth reached.
function Search:iterate(maxDepth)
    local best, bestScore, reached = 0, 0, 0
    for depth = 1, maxDepth do
        self.rootBest = 0
        self.canStop = depth > 1 -- always finish depth 1
        local score = self:negamax(depth, -INF, INF, 0, false)
        if self.stop then
            if self.rootBest ~= 0 and depth > 1 then best = self.rootBest end
            break
        end
        best, bestScore, reached = self.rootBest, score, depth
        if score > MATE_IN_MAX or score < -MATE_IN_MAX then break end
    end
    return best, bestScore, reached
end

-- Exact score for every root move (no pruning between siblings). Weak bots
-- use this so they can pick "plausible but imperfect" moves.
function Search:scoreRootMoves(depth)
    local b = self.board
    local legal = b:legalMoves()
    local results = {}
    self.canStop = false
    for i = 1, #legal do
        local m = legal[i]
        b:makeMove(m)
        local score
        if depth <= 1 then
            -- one ply: score the reply position (with captures resolved if allowed)
            score = -self:negamax(0, -INF, INF, 1, false)
        else
            score = -self:negamax(depth - 1, -INF, INF, 1, true)
        end
        b:unmakeMove()
        if self.stop then break end
        results[#results + 1] = { move = m, score = score }
        self.canStop = true
    end
    table.sort(results, function(a, c) return a.score > c.score end)
    return results, legal
end

local function chooseWeak(results, legal, p, rng)
    if #results == 0 then return legal[floor(rng() * #legal) + 1] end
    local best = results[1].score
    if best > MATE_IN_MAX then return results[1].move end -- never miss a found mate
    if p.blunder and rng() < p.blunder then
        local pool = {}
        local margin = p.blunderMargin or INF
        for i = 1, #results do
            if results[i].score >= best - margin then pool[#pool + 1] = results[i] end
        end
        return pool[floor(rng() * #pool) + 1].move
    end
    local noise = p.noise or 0
    local pick, top = results[1], -INF
    for i = 1, #results do
        local r = results[i]
        local v = r.score + (rng() + rng() - 1) * noise
        if v > top then pick, top = r, v end
    end
    return pick.move
end

function Search:run()
    local p = self.params
    local legal = self.board:legalMoves()
    if #legal == 0 then return nil end
    if #legal == 1 then return legal[1] end
    local rng = p.rng or math.random
    if p.multiRoot then
        local results = self:scoreRootMoves(p.maxDepth or 1)
        self.depthReached = p.maxDepth
        return chooseWeak(results, legal, p, rng)
    end
    local best, score, depth = self:iterate(p.maxDepth or 64)
    self.depthReached, self.lastScore = depth, score
    if best == 0 then best = legal[1] end
    return best
end

-- Prepare a search from a game position. params:
--   maxDepth, cpuMs (strength budget), quiesce (bool), multiRoot (bool),
--   noise, blunder, blunderMargin (cp), rng (function returning [0,1))
function Search:begin(gameBoard, params)
    self:allocTT()
    self.board:copyFrom(gameBoard)
    self.params = params
    self.nodes = 0
    self.stop = false
    self.abortFlag = false
    self.cpuUsed = 0
    self.cpuBudget = params.cpuMs or 1000
    self.noQuiesce = (params.quiesce == false)
    self.canStop = false
    self.clock = (ns.Clock and ns.Clock.ms) or defaultClock
    local hist = self.history
    for i = 1, HIST_SIZE do hist[i] = floor(hist[i] / 8) end
    for i = 0, MAXPLY + 2 do self.killer1[i], self.killer2[i] = 0, 0 end
    self.result, self.error, self.done = nil, nil, false
    self.co = coroutine.create(function() return self:run() end)
end

-- Run for up to sliceMs of CPU time. Returns done, move (or nil), errorMessage.
function Search:step(sliceMs)
    if not self.co then return true, self.result, self.error end
    self.yieldable = true
    self.sliceStart = self.clock()
    self.sliceBudget = sliceMs or 5
    local ok, res = coroutine.resume(self.co)
    if not ok then
        self.co = nil
        self.error = tostring(res)
        self.done = true
        return true, nil, self.error
    end
    if coroutine.status(self.co) == "dead" then
        self.co = nil
        self.result = res
        self.done = true
        self.cpuUsed = self.cpuUsed + (self.clock() - self.sliceStart)
        return true, res
    end
    return false
end

function Search:abort()
    self.co = nil
    self.done = true
end

-- Blocking search (tests and tools only; never call this from WoW event code).
function Search:searchNow(gameBoard, params)
    self:begin(gameBoard, params)
    self.yieldable = false
    self.sliceStart = self.clock()
    self.sliceBudget = math.huge
    local co = self.co
    self.co = nil
    local ok, res = coroutine.resume(co)
    if not ok then error(res) end
    return res
end

return Search
