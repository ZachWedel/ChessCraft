--[[
    Chess Craft - Core/Database.lua
    SavedVariables with defaults and versioned migrations.

    ChessCraftDB       (account)    settings, minimap, window position
    ChessCraftCharDB   (character)  saved bot games, the live game, history, stats
]]

local _, ns = ...

local Database = ns:NewModule("Database")

local SCHEMA = 1
local HISTORY_LIMIT = 100
local SAVED_BOT_GAMES_LIMIT = 20

local DEFAULT_SETTINGS = {
    theme = "classic",          -- "classic" | "faction"
    boardStyle = "wood",        -- classic theme board: "wood" | "green" | "slate"
    showLegalMoves = true,
    showCoordinates = true,
    highlightLastMove = true,
    animateMoves = true,
    autoQueen = false,
    confirmResign = true,
    sound = true,
    showQuips = true,
    acceptFrom = "everyone",    -- "everyone" | "friends" | "nobody"
    botSpeed = "balanced",      -- "smooth" | "balanced" | "fast"
    pauseBotInCombat = true,
    autoFlip = true,            -- show the board from your side
    scale = 1.0,
    debug = false,
}

local DEFAULT_GLOBAL = {
    schema = SCHEMA,
    settings = DEFAULT_SETTINGS,
    minimap = { hide = false, angle = 205 },
    window = {},
    newestVersionSeen = nil,
}

local DEFAULT_CHAR = {
    schema = SCHEMA,
    botGames = {},        -- id -> serialized game
    lastBotGame = nil,    -- id of the most recently played bot game
    live = nil,           -- serialized live (player vs player) game
    history = {},         -- finished games, newest first
    stats = { bots = {}, players = {} },
    lastBot = 3,
    lastColor = "random",
    lastTimeControl = "5+3",
}

local function copyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            copyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- schema migrations: MIGRATIONS[n] upgrades from n-1 to n
local MIGRATIONS = {
    -- [2] = function(global, char) ... end,
}

local function migrate(store, which)
    local from = store.schema or 1
    for v = from + 1, SCHEMA do
        local fn = MIGRATIONS[v]
        if fn then
            ns.safecall(fn, store, which)
        end
    end
    store.schema = SCHEMA
end

function Database:OnInitialize()
    ChessCraftDB = ChessCraftDB or {}
    ChessCraftCharDB = ChessCraftCharDB or {}
    migrate(ChessCraftDB, "global")
    migrate(ChessCraftCharDB, "char")
    copyDefaults(ChessCraftDB, DEFAULT_GLOBAL)
    copyDefaults(ChessCraftCharDB, DEFAULT_CHAR)
    -- drop settings that no longer exist
    for k in pairs(ChessCraftDB.settings) do
        if DEFAULT_SETTINGS[k] == nil then ChessCraftDB.settings[k] = nil end
    end
    ns.db = {
        global = ChessCraftDB,
        settings = ChessCraftDB.settings,
        char = ChessCraftCharDB,
    }
end

function Database.DefaultSetting(key) return DEFAULT_SETTINGS[key] end

function Database.ResetSettings()
    wipe(ns.db.settings)
    copyDefaults(ns.db.settings, DEFAULT_SETTINGS)
    ns:Fire("SETTINGS_CHANGED")
end

function Database.Set(key, value)
    ns.db.settings[key] = value
    ns:Fire("SETTINGS_CHANGED", key, value)
end

-- saved bot games ------------------------------------------------------------------
function Database.SaveBotGame(serialized)
    local games = ns.db.char.botGames
    games[serialized.id] = serialized
    ns.db.char.lastBotGame = serialized.id
    -- keep the newest N
    local list = {}
    for id, g in pairs(games) do list[#list + 1] = { id = id, t = g.updatedAt or 0 } end
    if #list > SAVED_BOT_GAMES_LIMIT then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = SAVED_BOT_GAMES_LIMIT + 1, #list do games[list[i].id] = nil end
    end
end

function Database.DeleteBotGame(id)
    ns.db.char.botGames[id] = nil
    if ns.db.char.lastBotGame == id then ns.db.char.lastBotGame = nil end
end

function Database.ListBotGames()
    local out = {}
    for _, g in pairs(ns.db.char.botGames) do out[#out + 1] = g end
    table.sort(out, function(a, b) return (a.updatedAt or 0) > (b.updatedAt or 0) end)
    return out
end

-- history & stats ----------------------------------------------------------------
-- entry: { id, date, mode, opponent, botId, myColor, outcome ("win"|"loss"|"draw"|"aborted"),
--          termination, plies, startFEN, moves (space separated UCI), timeControl }
function Database.AddHistory(entry)
    local h = ns.db.char.history
    table.insert(h, 1, entry)
    while #h > HISTORY_LIMIT do table.remove(h) end
    if entry.outcome == "aborted" then return end
    local stats = ns.db.char.stats
    local bucket
    if entry.mode == "bot" then
        stats.bots[entry.botId] = stats.bots[entry.botId] or { w = 0, l = 0, d = 0 }
        bucket = stats.bots[entry.botId]
    else
        stats.players[entry.opponent] = stats.players[entry.opponent] or { w = 0, l = 0, d = 0 }
        bucket = stats.players[entry.opponent]
    end
    if entry.outcome == "win" then bucket.w = bucket.w + 1
    elseif entry.outcome == "loss" then bucket.l = bucket.l + 1
    else bucket.d = bucket.d + 1 end
end

-- Undo a recorded result (e.g. a bot game reopened by taking moves back).
function Database.RemoveHistory(id)
    local h = ns.db.char.history
    for i, entry in ipairs(h) do
        if entry.id == id then
            table.remove(h, i)
            if entry.outcome ~= "aborted" then
                local stats = ns.db.char.stats
                local bucket = (entry.mode == "bot") and stats.bots[entry.botId] or stats.players[entry.opponent]
                if bucket then
                    if entry.outcome == "win" then bucket.w = math.max(0, bucket.w - 1)
                    elseif entry.outcome == "loss" then bucket.l = math.max(0, bucket.l - 1)
                    else bucket.d = math.max(0, bucket.d - 1) end
                end
            end
            return true
        end
    end
    return false
end

function Database.Totals()
    local w, l, d = 0, 0, 0
    local stats = ns.db.char.stats
    for _, group in pairs({ stats.bots, stats.players }) do
        for _, s in pairs(group) do w, l, d = w + s.w, l + s.l, d + s.d end
    end
    return w, l, d
end
