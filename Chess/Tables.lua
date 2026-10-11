--[[
    Chess Craft - Chess/Tables.lua
    Static data shared by the rules engine and the bot evaluation:
    piece codes, square geometry, material values and piece-square tables.

    Piece codes:   1..6  = white pawn, knight, bishop, rook, queen, king
                   7..12 = black pawn, knight, bishop, rook, queen, king
                   0 = empty, 13 = off-board sentinel
    Squares use a 10x12 "mailbox": index = 22 + file + 10 * rank
    (file/rank 0..7), so a1 = 22, h1 = 29, a8 = 92, h8 = 99.
]]

local _, ns = ...

local T = {}
ns.ChessTables = T

T.EMPTY, T.OFF = 0, 13
T.WHITE, T.BLACK = 1, 2

-- color of each piece code (0 = empty, 3 = off-board)
T.COLOR = { [0] = 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3 }
-- piece type (1 pawn .. 6 king) of each code
T.TYPE = { [0] = 0, 1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 0 }
-- PIECE[color][type] -> code
T.PIECE = { { 1, 2, 3, 4, 5, 6 }, { 7, 8, 9, 10, 11, 12 } }

T.PIECE_CHAR = { [0] = ".", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k" }
T.CHAR_PIECE = { P = 1, N = 2, B = 3, R = 4, Q = 5, K = 6, p = 7, n = 8, b = 9, r = 10, q = 11, k = 12 }

-- square geometry ----------------------------------------------------------
local FILE, RANK, NAME, SQ = {}, {}, {}, {}
local SQ64 = {}     -- 1..64 -> mailbox index (a1 first)
for i = 1, 120 do FILE[i] = -1; RANK[i] = -1 end
for r = 0, 7 do
    for f = 0, 7 do
        local s = 22 + f + 10 * r
        FILE[s], RANK[s] = f, r
        local name = string.char(97 + f) .. (r + 1)
        NAME[s] = name
        SQ[name] = s
        SQ64[r * 8 + f + 1] = s
    end
end
T.FILE, T.RANK, T.NAME, T.SQ, T.SQ64 = FILE, RANK, NAME, SQ, SQ64

function T.Square(file, rank) return 22 + file + 10 * rank end

-- material and phase --------------------------------------------------------
--                 P    N    B    R    Q   K
T.VALUE_MG     = { 100, 320, 335, 480, 960, 0 }
T.VALUE_EG     = { 125, 300, 315, 530, 980, 0 }
T.VALUE        = { 100, 320, 330, 500, 900, 2000 }  -- move ordering / SEE-ish
T.PHASE_WEIGHT = { 0, 1, 1, 2, 4, 0 }
T.PHASE_TOTAL  = 24

-- piece-square tables, White's point of view, rank 8 listed first -----------
local PST_MG = {
    { -- pawn
          0,   0,   0,   0,   0,   0,   0,   0,
         60,  70,  75,  80,  80,  75,  70,  60,
         20,  25,  35,  45,  45,  35,  25,  20,
          5,  10,  15,  30,  30,  15,  10,   5,
          0,   0,   8,  22,  22,   5,   0,   0,
          4,   2,  -4,   4,   4, -10,   2,   4,
          4,   8,   8, -18, -18,   8,   8,   4,
          0,   0,   0,   0,   0,   0,   0,   0,
    },
    { -- knight
        -60, -35, -25, -20, -20, -25, -35, -60,
        -30, -15,   0,   5,   5,   0, -15, -30,
        -20,   5,  15,  20,  20,  15,   5, -20,
        -15,  10,  20,  28,  28,  20,  10, -15,
        -15,   5,  18,  25,  25,  18,   5, -15,
        -20,   2,  12,  15,  15,  12,   2, -20,
        -30, -15,   0,   4,   4,   0, -15, -30,
        -55, -30, -22, -18, -18, -22, -30, -55,
    },
    { -- bishop
        -20, -10, -10, -10, -10, -10, -10, -20,
        -10,   0,   0,   0,   0,   0,   0, -10,
        -10,   0,   5,  10,  10,   5,   0, -10,
        -10,   5,   5,  10,  10,   5,   5, -10,
        -10,   0,  10,  10,  10,  10,   0, -10,
        -10,  10,  10,  10,  10,  10,  10, -10,
        -10,  12,   0,   0,   0,   0,  12, -10,
        -20, -10, -12, -10, -10, -12, -10, -20,
    },
    { -- rook
          5,  10,  10,  12,  12,  10,  10,   5,
         20,  25,  25,  25,  25,  25,  25,  20,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -5,   0,   0,   0,   0,   0,   0,  -5,
         -8,  -3,   0,   0,   0,   0,  -3,  -8,
         -2,   0,   4,   8,   8,   6,   0,  -2,
    },
    { -- queen
        -20, -10, -10,  -5,  -5, -10, -10, -20,
        -10,   0,   0,   0,   0,   0,   0, -10,
        -10,   0,   5,   5,   5,   5,   0, -10,
         -5,   0,   5,   5,   5,   5,   0,  -5,
         -5,   0,   5,   5,   5,   5,   0,  -5,
        -10,   2,   5,   5,   5,   5,   2, -10,
        -10,   0,   2,   0,   0,   0,   0, -10,
        -20, -10, -10,  -2,  -5, -10, -10, -20,
    },
    { -- king
        -40, -50, -50, -60, -60, -50, -50, -40,
        -40, -50, -50, -60, -60, -50, -50, -40,
        -40, -50, -50, -60, -60, -50, -50, -40,
        -40, -50, -50, -60, -60, -50, -50, -40,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -20, -30, -30, -40, -40, -30, -30, -20,
         10,  10,  -5, -20, -20,  -5,  10,  10,
         20,  35,  15, -10,   0, -10,  35,  20,
    },
}

local PST_EG = {
    { -- pawn
          0,   0,   0,   0,   0,   0,   0,   0,
         90,  90,  85,  80,  80,  85,  90,  90,
         55,  55,  50,  45,  45,  50,  55,  55,
         30,  28,  25,  20,  20,  25,  28,  30,
         15,  14,  12,  10,  10,  12,  14,  15,
          6,   6,   4,   4,   4,   4,   6,   6,
          2,   2,   2,   2,   2,   2,   2,   2,
          0,   0,   0,   0,   0,   0,   0,   0,
    },
    { -- knight
        -50, -30, -20, -15, -15, -20, -30, -50,
        -25, -10,   0,   5,   5,   0, -10, -25,
        -15,   5,  10,  15,  15,  10,   5, -15,
        -12,   8,  15,  20,  20,  15,   8, -12,
        -12,   8,  15,  20,  20,  15,   8, -12,
        -15,   2,  10,  12,  12,  10,   2, -15,
        -25, -10,   0,   2,   2,   0, -10, -25,
        -50, -30, -20, -15, -15, -20, -30, -50,
    },
    { -- bishop
        -15, -10,  -8,  -5,  -5,  -8, -10, -15,
        -10,  -2,   0,   2,   2,   0,  -2, -10,
         -8,   0,   5,   6,   6,   5,   0,  -8,
         -5,   2,   6,   8,   8,   6,   2,  -5,
         -5,   2,   6,   8,   8,   6,   2,  -5,
         -8,   0,   5,   6,   6,   5,   0,  -8,
        -10,  -2,   0,   2,   2,   0,  -2, -10,
        -15, -10,  -8,  -5,  -5,  -8, -10, -15,
    },
    { -- rook
         10,  10,  10,  10,  10,  10,  10,  10,
         12,  14,  14,  14,  14,  14,  14,  12,
          4,   4,   4,   4,   4,   4,   4,   4,
          0,   0,   0,   0,   0,   0,   0,   0,
         -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,
         -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,
         -6,  -6,  -6,  -6,  -6,  -6,  -6,  -6,
         -6,  -4,  -2,   0,   0,  -2,  -4,  -6,
    },
    { -- queen
        -10,  -5,  -2,   0,   0,  -2,  -5, -10,
         -5,   0,   5,   8,   8,   5,   0,  -5,
         -2,   5,  10,  12,  12,  10,   5,  -2,
          0,   8,  12,  15,  15,  12,   8,   0,
          0,   8,  12,  15,  15,  12,   8,   0,
         -2,   5,  10,  12,  12,  10,   5,  -2,
         -5,   0,   5,   8,   8,   5,   0,  -5,
        -10,  -5,  -2,   0,   0,  -2,  -5, -10,
    },
    { -- king
        -50, -35, -25, -20, -20, -25, -35, -50,
        -30, -15,  -5,   0,   0,  -5, -15, -30,
        -25,  -5,  15,  20,  20,  15,  -5, -25,
        -20,   0,  20,  30,  30,  20,   0, -20,
        -20,   0,  20,  30,  30,  20,   0, -20,
        -25,  -5,  15,  20,  20,  15,  -5, -25,
        -30, -15,  -5,   0,   0,  -5, -15, -30,
        -50, -35, -25, -20, -20, -25, -35, -50,
    },
}

-- Expand into per-piece-code, per-mailbox-square tables that already include
-- material, signed from White's point of view (black entries are negative).
-- The board keeps a running sum of these, so evaluation is nearly free.
local PMG, PEG = {}, {}
for p = 1, 12 do
    local t = T.TYPE[p]
    local white = p <= 6
    local mgT, egT = {}, {}
    for i = 1, 120 do mgT[i] = 0; egT[i] = 0 end
    for s, f in pairs(FILE) do
        if f >= 0 then
            local r = RANK[s]
            local idx
            if white then idx = (7 - r) * 8 + f + 1 else idx = r * 8 + f + 1 end
            local mg = T.VALUE_MG[t] + PST_MG[t][idx]
            local eg = T.VALUE_EG[t] + PST_EG[t][idx]
            if white then mgT[s], egT[s] = mg, eg else mgT[s], egT[s] = -mg, -eg end
        end
    end
    PMG[p], PEG[p] = mgT, egT
end
T.PMG, T.PEG = PMG, PEG

-- Deterministic pseudo-random numbers (Park-Miller). Both players' clients
-- must produce identical position hashes, so math.random is not used.
local seed = 20261104
local function rand30()
    seed = (seed * 16807) % 2147483647
    return seed % 1073741824
end

-- Additive Zobrist keys: a position hash is the plain sum of its feature
-- keys, which stays an exact integer in a double and needs no bit library.
local Z1, Z2 = {}, {}
for p = 1, 12 do
    local a, b = {}, {}
    for i = 1, 120 do a[i] = 0; b[i] = 0 end
    for i = 1, 64 do
        local s = SQ64[i]
        a[s] = rand30(); b[s] = rand30()
    end
    Z1[p], Z2[p] = a, b
end
local ZC1, ZC2 = {}, {}      -- castling rights state 0..15 stored at [c + 1]
for c = 1, 16 do ZC1[c] = rand30(); ZC2[c] = rand30() end
local ZEP1, ZEP2 = {}, {}    -- en passant target square
for i = 1, 120 do ZEP1[i] = 0; ZEP2[i] = 0 end
for i = 1, 64 do local s = SQ64[i]; ZEP1[s] = rand30(); ZEP2[s] = rand30() end
T.Z1, T.Z2, T.ZC1, T.ZC2, T.ZEP1, T.ZEP2 = Z1, Z2, ZC1, ZC2, ZEP1, ZEP2
T.ZSIDE1, T.ZSIDE2 = rand30(), rand30()

-- 4-bit AND table for castling rights: BAND4[a * 16 + b + 1] = a AND b
local BAND4 = {}
for a = 0, 15 do
    for b = 0, 15 do
        local r, bit, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if x % 2 == 1 and y % 2 == 1 then r = r + bit end
            x, y, bit = math.floor(x / 2), math.floor(y / 2), bit * 2
        end
        BAND4[a * 16 + b + 1] = r
    end
end
T.BAND4 = BAND4

-- castling rights kept when a piece moves from/to a square (nil = untouched)
T.CKEEP = { [22] = 13, [26] = 12, [29] = 14, [92] = 7, [96] = 3, [99] = 11 }
T.CASTLE_WK, T.CASTLE_WQ, T.CASTLE_BK, T.CASTLE_BQ = 1, 2, 4, 8

return T
