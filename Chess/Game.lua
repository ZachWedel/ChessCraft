--[[
    Chess Craft - Chess/Game.lua
    A game session: the two players, the move list, the chess clock and the
    result. Shared by bot games and live games; persistence goes through
    Serialize/Deserialize so a game survives /reload, logout and crashes.

    Clock rules (as on popular chess servers): each side's first move is
    untimed and the clock starts once both sides have moved; after that the
    mover's elapsed time is charged and the increment added. Each client is
    authoritative for its own player's clock in live games.
]]

local _, ns = ...
local Board = ns.Board
local T = ns.ChessTables

local floor = math.floor
local WHITE, BLACK = 1, 2

local Game = {}
Game.__index = Game
ns.Game = Game
Game.WHITE, Game.BLACK = WHITE, BLACK

local LAG_TOLERANCE_MS = 2000

local function now() return ns.Clock.now() end
local function serverNow() return ns.Clock.server() end

local function copyPlayer(p)
    if not p then return { name = "?" } end
    return { name = p.name, kind = p.kind, botId = p.botId }
end

--[[ opts:
     id, mode ("bot" | "live"),
     white = { name, kind = "human" | "bot" | "remote", botId }, black = { ... },
     localColor (1 white / 2 black), startFEN, tc = { base = ms, inc = ms } (nil = untimed)
]]
function Game.new(opts)
    local g = setmetatable({}, Game)
    g.id = opts.id or ns.NewId()
    g.mode = opts.mode or "bot"
    g.players = { copyPlayer(opts.white), copyPlayer(opts.black) }
    g.localColor = opts.localColor or WHITE
    g.startFEN = opts.startFEN or Board.START_FEN
    g.board = Board.new()
    local ok, err = g.board:setFEN(g.startFEN)
    if not ok then error("invalid start position: " .. tostring(err)) end
    g.moves, g.sans, g.moveInts = {}, {}, {}
    if opts.tc then
        g.tc = { base = opts.tc.base, inc = opts.tc.inc or 0 }
        g.clock = { g.tc.base, g.tc.base }
    end
    g.turnStart, g.turnStartServer = nil, nil
    g.result, g.termination, g.loser = nil, nil, nil
    g.createdAt = serverNow()
    g.updatedAt = g.createdAt
    g.extra = opts.extra or {}
    return g
end

-- queries ---------------------------------------------------------------------
function Game:SideToMove() return self.board.side end
function Game:Ply() return #self.moves end
function Game:IsOver() return self.result ~= nil end
function Game:IsLocalTurn() return not self.result and self.board.side == self.localColor end
function Game:Player(side) return self.players[side] end
function Game:LocalPlayer() return self.players[self.localColor] end
function Game:Opponent() return self.players[3 - self.localColor] end
function Game:LastMove() return self.moveInts[#self.moveInts] end
function Game:IsTimed() return self.tc ~= nil end
function Game:IsStandardStart() return self.startFEN == Board.START_FEN end

-- Legal moves from a square (for click/drag highlighting).
function Game:MovesFrom(sq)
    local out = {}
    if self.result then return out end
    local moves = self.board:legalMoves()
    for i = 1, #moves do
        if Board.MoveFrom(moves[i]) == sq then out[#out + 1] = moves[i] end
    end
    return out
end

-- clocks ----------------------------------------------------------------------
-- Remaining ms for a side right now (can be negative once a flag has fallen).
function Game:RawRemaining(side, t)
    if not self.tc then return nil end
    local r = self.clock[side]
    if self.turnStart and not self.result and self.board.side == side then
        r = r - ((t or now()) - self.turnStart) * 1000
    end
    return r
end

function Game:Remaining(side, t)
    local r = self:RawRemaining(side, t)
    if r and r < 0 then r = 0 end
    return r
end

function Game:ClockRunning() return self.turnStart ~= nil and not self.result end

-- Side whose flag has fallen (nil if none).
function Game:CheckFlag(t)
    if not self.tc or self.result or not self.turnStart then return nil end
    local side = self.board.side
    if self:RawRemaining(side, t) <= 0 then return side end
    return nil
end

local function chargeClock(self, side, t, reported)
    local c = self.clock
    if self.turnStart then
        local spent = (t - self.turnStart) * 1000
        if spent < 0 then spent = 0 end
        c[side] = c[side] - spent
    end
    -- a side's first move is free; increments apply from the move the clock started
    if self.turnStart then c[side] = c[side] + self.tc.inc end
    if reported then
        -- the mover's client is authoritative, capped at our estimate + lag tolerance
        local cap = c[side] + LAG_TOLERANCE_MS
        c[side] = (reported < cap) and reported or cap
    end
    if c[side] < 0 then c[side] = 0 end
end

-- moves ------------------------------------------------------------------------
-- Play a move (UCI string or engine move). opts.at = time of the move
-- (seconds, defaults to now), opts.remaining = mover's reported clock (ms).
-- Returns an info table, or nil plus an error string.
function Game:Move(input, opts)
    if self.result then return nil, "game is over" end
    local b = self.board
    local legal = b:legalMoves()
    local m
    if type(input) == "number" then
        for i = 1, #legal do if legal[i] == input then m = input break end end
    else
        m = b:uciToMove(input)
    end
    if not m then return nil, "illegal move" end
    opts = opts or {}

    local side = b.side
    local san = b:moveToSAN(m, legal)
    local to = Board.MoveTo(m)
    local captured = b.sq[to]
    if Board.MoveFlag(m) == 2 then captured = (side == WHITE) and 7 or 1 end
    local t = opts.at or now()
    if self.tc then chargeClock(self, side, t, opts.remaining) end

    b:makeMove(m)
    local uci = Board.MoveToUCI(m)
    self.moves[#self.moves + 1] = uci
    self.sans[#self.sans + 1] = san
    self.moveInts[#self.moveInts + 1] = m
    self.updatedAt = serverNow()
    self.drawOffer = nil

    if self.tc then
        if #self.moves >= 2 then
            self.turnStart = t
            self.turnStartServer = serverNow() - (now() - t)
        else
            self.turnStart, self.turnStartServer = nil, nil
        end
    end

    local status = b:status()
    local info = {
        move = m, uci = uci, san = san, side = side,
        capture = captured ~= 0, captured = captured,
        check = b:inCheck(), status = status,
        promotion = Board.MovePromo(m) ~= 0,
    }
    if status == "checkmate" then
        self:Finish(side == WHITE and "1-0" or "0-1", "checkmate")
    elseif status ~= "ongoing" then
        self:Finish("1/2-1/2", status)
    end
    return info
end

-- Append a move without touching clocks or result (rebuilding a game).
function Game:Replay(uci)
    local b = self.board
    local m = b:uciToMove(uci)
    if not m then return false end
    self.sans[#self.sans + 1] = b:moveToSAN(m)
    b:makeMove(m)
    self.moves[#self.moves + 1] = uci
    self.moveInts[#self.moveInts + 1] = m
    return true
end

-- After replaying, end the game if the final position is decisive.
function Game:SettleStatus()
    if self.result or #self.moves == 0 then return end
    local status = self.board:status()
    if status == "checkmate" then
        self:Finish(self.board.side == WHITE and "0-1" or "1-0", "checkmate")
    elseif status ~= "ongoing" then
        self:Finish("1/2-1/2", status)
    end
end

-- Take back up to n half-moves (bot games, agreed takebacks).
function Game:Undo(n)
    n = n or 1
    local undone = 0
    while undone < n and #self.moves > 0 do
        if not self.board:unmakeMove() then break end
        self.moves[#self.moves] = nil
        self.sans[#self.sans] = nil
        self.moveInts[#self.moveInts] = nil
        undone = undone + 1
    end
    if undone > 0 then
        self.result, self.termination, self.loser = nil, nil, nil
        self.updatedAt = serverNow()
    end
    return undone
end

-- results ------------------------------------------------------------------------
-- result: "1-0" | "0-1" | "1/2-1/2" | "*" (aborted). loser: side for resign/timeout/abandon.
function Game:Finish(result, termination, loser)
    if self.result then return false end
    if self.tc and self.turnStart then
        local side = self.board.side
        local r = self.clock[side] - (now() - self.turnStart) * 1000
        self.clock[side] = r > 0 and r or 0
    end
    self.turnStart, self.turnStartServer = nil, nil
    self.result, self.termination, self.loser = result, termination, loser
    self.updatedAt = serverNow()
    return true
end

function Game:Resign(side)
    return self:Finish(side == WHITE and "0-1" or "1-0", "resign", side)
end

function Game:FlagFall(side)
    local opp = 3 - side
    if self.clock then self.clock[side] = 0 end
    if self.board:hasMatingMaterial(opp) then
        return self:Finish(opp == WHITE and "1-0" or "0-1", "timeout", side)
    end
    return self:Finish("1/2-1/2", "timeout-draw", side)
end

function Game:Abort()
    return self:Finish("*", "aborted")
end

-- "win" | "loss" | "draw" | "aborted" from a side's point of view.
function Game:Outcome(side)
    side = side or self.localColor
    if not self.result then return nil end
    if self.result == "*" then return "aborted" end
    if self.result == "1/2-1/2" then return "draw" end
    local winner = (self.result == "1-0") and WHITE or BLACK
    return (winner == side) and "win" or "loss"
end

local TERMINATION_TEXT = {
    checkmate = "Checkmate",
    stalemate = "Stalemate",
    repetition = "Draw by threefold repetition",
    fifty = "Draw by the fifty-move rule",
    material = "Draw by insufficient material",
    agreement = "Draw by agreement",
    resign = "%s resigned",
    timeout = "%s ran out of time",
    ["timeout-draw"] = "%s ran out of time, but the opponent cannot mate: draw",
    abandon = "%s left the game",
    disconnect = "%s disconnected; victory claimed",
    aborted = "Game aborted",
}

function Game:ResultText()
    if not self.result then return nil end
    local text = TERMINATION_TEXT[self.termination] or (self.termination or "")
    if text:find("%%s") then
        local who = self.loser and self.players[self.loser] and self.players[self.loser].name or "A player"
        text = text:format(ns.Names and ns.Names.Display(who) or who)
    end
    return text
end

-- material ---------------------------------------------------------------------------
local START_COUNT = { 8, 2, 2, 2, 1 }
-- Pieces each side has lost (by type) and the material balance (white positive).
function Game:Material()
    local c = self.board.count
    local lost = { {}, {} }
    for side = 1, 2 do
        local off = (side == WHITE) and 0 or 6
        for t = 1, 5 do
            local missing = START_COUNT[t] - c[off + t]
            lost[side][t] = missing > 0 and missing or 0
        end
    end
    local balance = 0
    for t = 1, 5 do balance = balance + (c[t] - c[6 + t]) * T.VALUE[t] end
    return lost, floor(balance / 100 + 0.5)
end

-- persistence -------------------------------------------------------------------------
function Game:Serialize()
    return {
        v = 1,
        id = self.id,
        mode = self.mode,
        players = { copyPlayer(self.players[1]), copyPlayer(self.players[2]) },
        localColor = self.localColor,
        startFEN = (self.startFEN ~= Board.START_FEN) and self.startFEN or nil,
        moves = table.concat(self.moves, " "),
        tc = self.tc and { base = self.tc.base, inc = self.tc.inc } or nil,
        clock = self.clock and { self.clock[1], self.clock[2] } or nil,
        turnStartNow = self.turnStart,
        turnStartServer = self.turnStartServer,
        result = self.result,
        termination = self.termination,
        loser = self.loser,
        createdAt = self.createdAt,
        updatedAt = self.updatedAt,
        extra = self.extra,
    }
end

-- Rebuild from Serialize() output. Returns the game (game.corrupt is set if a
-- stored move turned out to be illegal; play continues from the last good move).
function Game.Deserialize(t)
    local g = Game.new({
        id = t.id, mode = t.mode, white = t.players and t.players[1], black = t.players and t.players[2],
        localColor = t.localColor, startFEN = t.startFEN, tc = t.tc, extra = t.extra,
    })
    for uci in (t.moves or ""):gmatch("%S+") do
        if not g:Replay(uci) then g.corrupt = true break end
    end
    if t.clock then g.clock = { t.clock[1], t.clock[2] } end
    if t.turnStartServer and not t.result and g.tc then
        local nowT, nowS = now(), serverNow()
        local byServer = nowS - t.turnStartServer
        local byNow = t.turnStartNow and (nowT - t.turnStartNow) or nil
        -- GetTime survives /reload; fall back to server time after a restart/reboot
        if byNow and byNow >= 0 and math.abs(byNow - byServer) <= 5 then
            g.turnStart = t.turnStartNow
        else
            g.turnStart = nowT - byServer
        end
        g.turnStartServer = t.turnStartServer
    end
    g.result, g.termination, g.loser = t.result, t.termination, t.loser
    g.createdAt, g.updatedAt = t.createdAt or g.createdAt, t.updatedAt or g.updatedAt
    g:SettleStatus()
    return g
end

-- PGN export ------------------------------------------------------------------------------
local function pgnName(p)
    if not p then return "?" end
    if p.kind == "bot" and ns.Bots and ns.Bots.byId[p.botId] then
        return ns.Bots.byId[p.botId].name .. " (Chess Craft bot)"
    end
    return ns.Names and ns.Names.Display(p.name) or p.name or "?"
end

function Game:ToPGN()
    local tc = "-"
    if self.tc then tc = floor(self.tc.base / 1000) .. "+" .. floor(self.tc.inc / 1000) end
    local d = (date and date("%Y.%m.%d", self.createdAt)) or "????.??.??"
    local headers = {
        { "Event", self.mode == "bot" and "Chess Craft: casual game vs bot" or "Chess Craft: live game" },
        { "Site", "World of Warcraft: Forever" },
        { "Date", d },
        { "Round", "-" },
        { "White", pgnName(self.players[1]) },
        { "Black", pgnName(self.players[2]) },
        { "Result", (self.result and self.result ~= "*") and self.result or "*" },
        { "TimeControl", tc },
    }
    if self.result then headers[#headers + 1] = { "Termination", self:ResultText() or "" } end
    if self.startFEN ~= Board.START_FEN then
        headers[#headers + 1] = { "SetUp", "1" }
        headers[#headers + 1] = { "FEN", self.startFEN }
    end
    local out = {}
    for _, h in ipairs(headers) do
        out[#out + 1] = string.format('[%s "%s"]', h[1], (tostring(h[2]):gsub('"', "'")))
    end
    out[#out + 1] = ""

    local start = Board.new(self.startFEN)
    local moveNo, side = start.fullmove, start.side
    local tokens = {}
    for i, san in ipairs(self.sans) do
        if side == WHITE then
            tokens[#tokens + 1] = moveNo .. ". " .. san
        else
            if i == 1 then tokens[#tokens + 1] = moveNo .. "... " .. san else tokens[#tokens + 1] = san end
            moveNo = moveNo + 1
        end
        side = 3 - side
    end
    tokens[#tokens + 1] = (self.result and self.result ~= "*") and self.result or "*"
    local line, lines = "", {}
    for _, tok in ipairs(tokens) do
        if #line + #tok + 1 > 79 then lines[#lines + 1] = line; line = tok
        else line = (line == "") and tok or (line .. " " .. tok) end
    end
    if line ~= "" then lines[#lines + 1] = line end
    out[#out + 1] = table.concat(lines, "\n")
    return table.concat(out, "\n")
end

return Game
