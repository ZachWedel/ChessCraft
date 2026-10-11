--[[
    Chess Craft - AI/Eval.lua
    Static evaluation used by the bots. Most of the work (material +
    piece-square tables, tapered by game phase) is maintained incrementally
    by the board; this file adds pawn structure (cached by pawn hash), the
    bishop pair, a mop-up term for lone-king endgames, and a tempo bonus.
    Returns a score in centipawns from the side to move's point of view.
]]

local _, ns = ...
local T = ns.ChessTables

local floor = math.floor
local FILE, RANK, SQ64 = T.FILE, T.RANK, T.SQ64

local Eval = {}
ns.Eval = Eval

local WP, BP, WB, BB = 1, 7, 3, 9

-- passed pawn bonus by relative rank (index = rank + 1; rank 1 = start)
local PASSED_MG = { 0, 5, 10, 18, 30, 50, 80, 0 }
local PASSED_EG = { 0, 10, 18, 32, 55, 90, 140, 0 }
local DOUBLED_MG, DOUBLED_EG = -8, -18
local ISOLATED_MG, ISOLATED_EG = -10, -14
local BISHOP_PAIR_MG, BISHOP_PAIR_EG = 30, 50
local TEMPO = 10

-- distance of each square from the center (0..6), for mop-up
local CENTER_DIST = {}
for i = 1, 64 do
    local s = SQ64[i]
    local f, r = FILE[s], RANK[s]
    local df = (f < 4) and (3 - f) or (f - 4)
    local dr = (r < 4) and (3 - r) or (r - 4)
    CENTER_DIST[s] = df + dr
end

local function kingDistance(a, b)
    local df, dr = FILE[a] - FILE[b], RANK[a] - RANK[b]
    if df < 0 then df = -df end
    if dr < 0 then dr = -dr end
    return df + dr
end

-- pawn structure cache ----------------------------------------------------------
local cacheMg, cacheEg, cacheSize = {}, {}, 0
local CACHE_LIMIT = 40000

-- scratch arrays, files shifted by one so f-1 / f+1 never leave the table
local wCount, bCount, wMin, bMax = {}, {}, {}, {}
local wPawns, bPawns = {}, {}

local function pawnStructure(b)
    local key = b.ph
    local mg = cacheMg[key]
    if mg then return mg, cacheEg[key] end

    for f = 0, 9 do wCount[f] = 0; bCount[f] = 0; wMin[f] = 8; bMax[f] = -1 end
    local nw, nb = 0, 0
    local sq = b.sq
    for i = 1, 64 do
        local s = SQ64[i]
        local p = sq[s]
        if p == WP then
            local f, r = FILE[s] + 1, RANK[s]
            wCount[f] = wCount[f] + 1
            if r < wMin[f] then wMin[f] = r end
            nw = nw + 1; wPawns[nw] = s
        elseif p == BP then
            local f, r = FILE[s] + 1, RANK[s]
            bCount[f] = bCount[f] + 1
            if r > bMax[f] then bMax[f] = r end
            nb = nb + 1; bPawns[nb] = s
        end
    end

    local eg = 0
    mg = 0
    for f = 1, 8 do
        if wCount[f] > 1 then mg = mg + DOUBLED_MG * (wCount[f] - 1); eg = eg + DOUBLED_EG * (wCount[f] - 1) end
        if bCount[f] > 1 then mg = mg - DOUBLED_MG * (bCount[f] - 1); eg = eg - DOUBLED_EG * (bCount[f] - 1) end
    end
    for i = 1, nw do
        local s = wPawns[i]
        local f, r = FILE[s] + 1, RANK[s]
        if wCount[f - 1] == 0 and wCount[f + 1] == 0 then
            mg = mg + ISOLATED_MG; eg = eg + ISOLATED_EG
        end
        if bMax[f - 1] <= r and bMax[f] <= r and bMax[f + 1] <= r then
            mg = mg + PASSED_MG[r + 1]; eg = eg + PASSED_EG[r + 1]
        end
    end
    for i = 1, nb do
        local s = bPawns[i]
        local f, r = FILE[s] + 1, RANK[s]
        if bCount[f - 1] == 0 and bCount[f + 1] == 0 then
            mg = mg - ISOLATED_MG; eg = eg - ISOLATED_EG
        end
        if wMin[f - 1] >= r and wMin[f] >= r and wMin[f + 1] >= r then
            local rel = 7 - r
            mg = mg - PASSED_MG[rel + 1]; eg = eg - PASSED_EG[rel + 1]
        end
    end

    if cacheSize >= CACHE_LIMIT then
        cacheMg, cacheEg, cacheSize = {}, {}, 0
    end
    cacheMg[key], cacheEg[key] = mg, eg
    cacheSize = cacheSize + 1
    return mg, eg
end

function Eval.clearCache()
    cacheMg, cacheEg, cacheSize = {}, {}, 0
end

-- main evaluation -------------------------------------------------------------------
function Eval.evaluate(b)
    local mg, eg = b.mg, b.eg
    local c = b.count
    if c[WB] >= 2 then mg = mg + BISHOP_PAIR_MG; eg = eg + BISHOP_PAIR_EG end
    if c[BB] >= 2 then mg = mg - BISHOP_PAIR_MG; eg = eg - BISHOP_PAIR_EG end
    local pmg, peg = pawnStructure(b)
    mg = mg + pmg; eg = eg + peg

    local phase = b.phase
    if phase > 24 then phase = 24 end
    local score = (mg * phase + eg * (24 - phase)) / 24

    -- mop-up: drive a lone king to the edge and bring our king closer
    local wPieces = c[2] + c[3] + c[4] + c[5]
    local bPieces = c[8] + c[9] + c[10] + c[11]
    if bPieces + c[BP] == 0 and (wPieces > 0 or c[WP] > 0) then
        local lk, wk = b.ksq[2], b.ksq[1]
        score = score + CENTER_DIST[lk] * 10 + (14 - kingDistance(lk, wk)) * 4
    elseif wPieces + c[WP] == 0 and (bPieces > 0 or c[BP] > 0) then
        local lk, bk = b.ksq[1], b.ksq[2]
        score = score - CENTER_DIST[lk] * 10 - (14 - kingDistance(lk, bk)) * 4
    end

    score = floor(score)
    if b.side == 1 then return score + TEMPO end
    return TEMPO - score
end

return Eval
