--[[
    Chess Craft - AI/Book.lua
    A small opening book of mainstream lines (UCI notation). Bots pick a
    weighted-random continuation while the game is still "in book", which
    gives them variety without spending search time. Only used for games
    that start from the standard position.
]]

local _, ns = ...

local Book = {}
ns.Book = Book

local LINES = {
    -- 1.e4 e5
    "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3 d7d6 c2c3 e8g8 h2h3", -- Ruy Lopez, Closed
    "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f6e4 d2d4 b7b5 a4b3 d7d5 d4e5 c8e6",      -- Ruy Lopez, Open
    "e2e4 e7e5 g1f3 b8c6 f1b5 g8f6 e1g1 f6e4 f1e1 e4d6 f3e5 f8e7 b5f1 c6e5 e1e5 e8g8",       -- Berlin
    "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5c6 d7c6 e1g1 f7f6 d2d4 e5d4 f3d4 c6c5",                 -- Exchange Ruy
    "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 c2c3 g8f6 d2d3 d7d6 e1g1 a7a6 a2a4 e8g8",                 -- Giuoco Piano
    "e2e4 e7e5 g1f3 b8c6 f1c4 g8f6 d2d3 f8e7 e1g1 e8g8 f1e1 d7d6 c2c3",                      -- Two Knights, quiet
    "e2e4 e7e5 g1f3 b8c6 f1c4 g8f6 f3g5 d7d5 e4d5 c6a5 c4b5 c7c6 d5c6 b7c6",                 -- Two Knights, Ng5
    "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 b2b4 c5b4 c2c3 b4a5 d2d4 e5d4 e1g1",                      -- Evans Gambit
    "e2e4 e7e5 g1f3 b8c6 d2d4 e5d4 f3d4 g8f6 d4c6 b7c6 e4e5 d8e7 d1e2 f6d5 c2c4",            -- Scotch
    "e2e4 e7e5 g1f3 b8c6 d2d4 e5d4 f3d4 f8c5 d4b3 c5b6 a2a4 a7a6 b1c3",                      -- Scotch, Bc5
    "e2e4 e7e5 g1f3 b8c6 b1c3 g8f6 f1b5 f8b4 e1g1 e8g8 d2d3 d7d6",                           -- Four Knights
    "e2e4 e7e5 g1f3 g8f6 f3e5 d7d6 e5f3 f6e4 d2d4 d6d5 f1d3 b8c6 e1g1 f8e7",                 -- Petroff
    "e2e4 e7e5 g1f3 d7d6 d2d4 g8f6 b1c3 b8d7 f1c4 f8e7 e1g1 e8g8",                           -- Philidor
    "e2e4 e7e5 f2f4 e5f4 g1f3 g7g5 h2h4 g5g4 f3e5 g8f6",                                     -- King's Gambit
    "e2e4 e7e5 b1c3 g8f6 f2f4 d7d5 f4e5 f6e4 g1f3 f8e7",                                     -- Vienna
    -- Sicilian
    "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 a7a6 c1e3 e7e5 d4b3 c8e6 f2f3",            -- Najdorf, English Attack
    "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 g7g6 c1e3 f8g7 f2f3 e8g8 d1d2 b8c6",       -- Dragon
    "e2e4 c7c5 g1f3 b8c6 d2d4 c5d4 f3d4 g8f6 b1c3 e7e5 d4b5 d7d6 c1g5 a7a6 b5a3 b7b5",       -- Sveshnikov
    "e2e4 c7c5 g1f3 e7e6 d2d4 c5d4 f3d4 a7a6 f1d3 g8f6 e1g1 d8c7",                           -- Kan
    "e2e4 c7c5 g1f3 e7e6 d2d4 c5d4 f3d4 b8c6 b1c3 d8c7 c1e3 a7a6",                           -- Taimanov
    "e2e4 c7c5 g1f3 d7d6 f1b5 c8d7 b5d7 d8d7 e1g1 b8c6 c2c3 g8f6",                           -- Moscow
    "e2e4 c7c5 b1c3 b8c6 g2g3 g7g6 f1g2 f8g7 d2d3 d7d6 f2f4",                                -- Closed Sicilian
    "e2e4 c7c5 c2c3 g8f6 e4e5 f6d5 d2d4 c5d4 g1f3 b8c6 c3d4 d7d6",                           -- Alapin
    -- French / Caro-Kann / others vs 1.e4
    "e2e4 e7e6 d2d4 d7d5 b1c3 g8f6 c1g5 f8e7 e4e5 f6d7 g5e7 d8e7 f2f4",                      -- French Classical
    "e2e4 e7e6 d2d4 d7d5 b1c3 f8b4 e4e5 c7c5 a2a3 b4c3 b2c3 g8e7",                           -- Winawer
    "e2e4 e7e6 d2d4 d7d5 e4e5 c7c5 c2c3 b8c6 g1f3 d8b6 a2a3",                                -- French Advance
    "e2e4 e7e6 d2d4 d7d5 b1d2 g8f6 e4e5 f6d7 f1d3 c7c5 c2c3 b8c6",                           -- Tarrasch
    "e2e4 c7c6 d2d4 d7d5 b1c3 d5e4 c3e4 c8f5 e4g3 f5g6 h2h4 h7h6 g1f3 b8d7",                 -- Caro-Kann Classical
    "e2e4 c7c6 d2d4 d7d5 e4e5 c8f5 g1f3 e7e6 f1e2 c6c5 e1g1",                                -- Caro-Kann Advance
    "e2e4 c7c6 d2d4 d7d5 e4d5 c6d5 c2c4 g8f6 b1c3 e7e6 g1f3",                                -- Panov
    "e2e4 d7d5 e4d5 d8d5 b1c3 d5a5 d2d4 g8f6 g1f3 c8f5 f1c4 e7e6",                           -- Scandinavian
    "e2e4 d7d6 d2d4 g8f6 b1c3 g7g6 g1f3 f8g7 f1e2 e8g8 e1g1",                                -- Pirc
    "e2e4 g7g6 d2d4 f8g7 b1c3 d7d6 c1e3 a7a6 d1d2 b7b5",                                     -- Modern
    "e2e4 g8f6 e4e5 f6d5 d2d4 d7d6 g1f3 c8g4 f1e2 e7e6 e1g1",                                -- Alekhine
    -- 1.d4 d5
    "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c1g5 f8e7 e2e3 e8g8 g1f3 b8d7 a1c1 c7c6",                 -- QGD Orthodox
    "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c4d5 e6d5 c1g5 c7c6 e2e3 f8e7 f1d3",                      -- QGD Exchange
    "d2d4 d7d5 c2c4 d5c4 g1f3 g8f6 e2e3 e7e6 f1c4 c7c5 e1g1 a7a6",                           -- QGA
    "d2d4 d7d5 c2c4 c7c6 g1f3 g8f6 b1c3 d5c4 a2a4 c8f5 e2e3 e7e6 f1c4",                      -- Slav
    "d2d4 d7d5 c2c4 c7c6 g1f3 g8f6 b1c3 e7e6 e2e3 b8d7 f1d3 d5c4 d3c4 b7b5",                 -- Semi-Slav Meran
    "d2d4 d7d5 g1f3 g8f6 c1f4 e7e6 e2e3 c7c5 c2c3 b8c6 b1d2",                                -- London
    "d2d4 d7d5 c2c4 b8c6 g1f3 c8g4 c4d5 g4f3 g2f3 d8d5",                                     -- Chigorin
    -- 1.d4 Nf6
    "d2d4 g8f6 c2c4 g7g6 b1c3 f8g7 e2e4 d7d6 g1f3 e8g8 f1e2 e7e5 e1g1 b8c6 d4d5 c6e7",       -- King's Indian
    "d2d4 g8f6 c2c4 g7g6 b1c3 d7d5 c4d5 f6d5 e2e4 d5c3 b2c3 f8g7 g1f3 c7c5",                 -- Grünfeld
    "d2d4 g8f6 c2c4 e7e6 b1c3 f8b4 e2e3 e8g8 f1d3 d7d5 g1f3 c7c5 e1g1",                      -- Nimzo-Indian
    "d2d4 g8f6 c2c4 e7e6 g1f3 b7b6 g2g3 c8b7 f1g2 f8e7 e1g1 e8g8 b1c3",                      -- Queen's Indian
    "d2d4 g8f6 c2c4 e7e6 g2g3 d7d5 f1g2 f8e7 g1f3 e8g8 e1g1 d5c4",                           -- Catalan
    "d2d4 g8f6 c2c4 c7c5 d4d5 e7e6 b1c3 e6d5 c4d5 d7d6 e2e4 g7g6",                           -- Modern Benoni
    "d2d4 g8f6 c2c4 c7c5 d4d5 b7b5 c4b5 a7a6 b5a6 g7g6 b1c3 c8a6",                           -- Benko Gambit
    "d2d4 g8f6 c1g5 e7e6 e2e4 h7h6 g5f6 d8f6 b1c3",                                          -- Trompowsky
    "d2d4 g8f6 g1f3 e7e6 c1f4 c7c5 e2e3 b8c6 c2c3 d7d5",                                     -- London vs Nf6
    "d2d4 f7f5 g2g3 g8f6 f1g2 g7g6 g1f3 f8g7 e1g1 e8g8 c2c4 d7d6",                           -- Leningrad Dutch
    "d2d4 f7f5 c2c4 g8f6 g2g3 e7e6 f1g2 f8e7 g1f3 e8g8 e1g1 d7d5",                           -- Stonewall Dutch
    -- flank openings
    "c2c4 e7e5 b1c3 g8f6 g1f3 b8c6 g2g3 d7d5 c4d5 f6d5 f1g2 d5b6 e1g1 f8e7",                 -- English, Four Knights
    "c2c4 c7c5 b1c3 b8c6 g2g3 g7g6 f1g2 f8g7 g1f3 e7e6 e1g1 g8e7",                           -- Symmetrical English
    "c2c4 g8f6 b1c3 e7e6 e2e4 d7d5 e4e5 d5d4",                                               -- Mikenas
    "g1f3 d7d5 g2g3 g8f6 f1g2 c7c6 e1g1 c8g4 d2d3 b8d7",                                     -- Réti / KIA
    "g1f3 g8f6 c2c4 g7g6 b1c3 f8g7 e2e4 d7d6 d2d4 e8g8",                                     -- Réti into KID
    "b2b3 e7e5 c1b2 b8c6 e2e3 g8f6 f1b5 d7d6",                                               -- Larsen
    "f2f4 d7d5 g1f3 g8f6 e2e3 g7g6 f1e2 f8g7 e1g1 e8g8",                                     -- Bird
}

-- prefix tree: tree["e2e4 e7e5"] = { g1f3 = weight, ... }
local tree = {}
for _, line in ipairs(LINES) do
    local prefix = ""
    for mv in line:gmatch("%S+") do
        local node = tree[prefix]
        if not node then node = {}; tree[prefix] = node end
        node[mv] = (node[mv] or 0) + 1
        prefix = (prefix == "") and mv or (prefix .. " " .. mv)
    end
end

Book.LINES = LINES

-- history: array of UCI moves played from the standard start.
-- Returns a UCI move or nil when out of book (or past maxPly).
function Book.Next(history, maxPly, rng)
    rng = rng or math.random
    local n = #history
    if maxPly and n >= maxPly then return nil end
    local node = tree[table.concat(history, " ")]
    if not node then return nil end
    local keys, total = {}, 0
    for mv, w in pairs(node) do keys[#keys + 1] = mv; total = total + w end
    table.sort(keys)
    local r = rng() * total
    for _, mv in ipairs(keys) do
        r = r - node[mv]
        if r < 0 then return mv end
    end
    return keys[#keys]
end

return Book
