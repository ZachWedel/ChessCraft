--[[
    Chess Craft - Net/Live.lua
    Live games between two players over addon whispers.

    Reliable messages carry a per-sender sequence number and are re-sent
    every few seconds until the opponent acknowledges them (AK). Handlers are
    idempotent (moves are checked against the ply), so duplicates are harmless.

      GS~gid~seq                         game start (challenger -> acceptor)
      MV~gid~seq~ply~uci~clockMs~hash    move; clockMs = mover's clock after the move
      RS~gid~seq[~abandon]               resign (or leave an infinite game)
      AB~gid~seq                         abort (only before both sides moved)
      DO / DA / DD ~gid~seq~ply          draw offer / accept / decline
      TO~gid~seq~ply                     "my flag fell"
      TC~gid~seq~ply                     "your flag fell" (claim)
      TA~gid~seq / TN~gid~seq~clockMs    timeout claim agreed / denied
      CW~gid~seq                         victory claimed after a disconnect
      AK~gid~seq                         acknowledgement (unreliable)
      HB~gid~ply~clockMs                 heartbeat (unreliable)
      SY~gid~kind~ply~hash~clockMs~elapsedMs   sync request (q) / reply (r)
      SM~gid~fromPly~uci,uci,...         missing moves
      SR~gid~result~termination~loser    game already finished
      SG~gid                             game unknown

    Policy (chosen for Chess Craft):
      * timed games: the clock keeps running while a player is away; after
        60 s without any message the opponent may claim the win or wait;
      * infinite games: no clock; the game is saved and resumes when both
        players are online again; leaving before both sides have moved
        aborts with no result, leaving later counts as a resignation.
]]

local _, ns = ...
local Game, Compat, Comm, Names = ns.Game, ns.Compat, ns.Comm, ns.Names

local Live = ns:NewModule("Live")

local RETRY_INTERVAL = 3
local MAX_TRIES = 20
local HEARTBEAT_INTERVAL = 10
local UNSTABLE_AFTER = 25
local CLAIM_AFTER = 60
local FLAG_GRACE = 3
local CLAIM_REPLY_TIMEOUT = 15
local FIRST_MOVE_TIMEOUT = 60
local SYNC_RETRY = 5
local RECENT_RESULTS_TTL = 24 * 3600
local MOVES_PER_CHUNK = 35

Live.CLAIM_AFTER = CLAIM_AFTER
Live.pending = {}
Live.seen = {}

local function now() return ns.Clock.now() end

function Live:IsActive() return self.game ~= nil and not self.game.result end
function Live:Game() return self.game end

local function oppColor(g) return 3 - g.localColor end

-- persistence ---------------------------------------------------------------------
function Live:Save()
    local g = self.game
    if not g then return end
    if g.result then
        ns.db.char.live = nil
        return
    end
    local t = g:Serialize()
    t.extra = t.extra or {}
    t.extra.opp = self.opp
    t.extra.mySeq = self.mySeq or 0
    ns.db.char.live = t
end

local function rememberResult(g)
    local rr = ns.db.char.recentResults or {}
    ns.db.char.recentResults = rr
    rr[g.id] = { result = g.result, termination = g.termination, loser = g.loser, t = ns.Clock.server() }
    local cutoff = ns.Clock.server() - RECENT_RESULTS_TTL
    for id, r in pairs(rr) do
        if (r.t or 0) < cutoff then rr[id] = nil end
    end
end

-- messaging ------------------------------------------------------------------------
function Live:SendReliable(msgType, ...)
    local g = self.game
    if not g or not self.opp then return end
    self.mySeq = (self.mySeq or 0) + 1
    local seq = self.mySeq
    local args = { ... }
    self.pending[seq] = { msgType = msgType, gid = g.id, args = args, n = select("#", ...),
                          tries = 1, nextTry = now() + RETRY_INTERVAL, to = self.opp }
    Comm:Send(self.opp, msgType, g.id, seq, ...)
    self:Save()
end

local function resend(seq, p)
    Comm:Send(p.to, p.msgType, p.gid, seq, unpack(p.args, 1, p.n))
end

function Live:ProcessPending(t)
    for seq, p in pairs(self.pending) do
        if t >= p.nextTry then
            if p.tries >= MAX_TRIES then
                self.pending[seq] = nil
                ns.Debug("gave up re-sending %s #%d", p.msgType, seq)
            else
                p.tries = p.tries + 1
                p.nextTry = t + RETRY_INTERVAL
                resend(seq, p)
            end
        end
    end
end

function Live:Heard()
    self.lastHeard = now()
    if self.oppOffline then
        self.oppOffline = false
        ns:Fire("LIVE_CONNECTION", "ok")
    end
end

-- Validate that a game message belongs to our game and comes from the opponent.
function Live:Accepts(gid, sender)
    local g = self.game
    return g and g.id == gid and self.opp and Names.Same(self.opp, sender)
end

-- Wrap a handler for a reliable message: ack, dedupe, then run.
local function reliable(handler)
    return function(sender, f)
        local gid, seq = f[1], tonumber(f[2])
        if not gid or not seq then return end
        if not Live:Accepts(gid, sender) then
            -- unknown or finished game: tell the sender so it doesn't wait forever
            Comm:Send(sender, "AK", gid, seq)
            local rr = ns.db.char.recentResults and ns.db.char.recentResults[gid]
            if rr then
                Comm:Send(sender, "SR", gid, rr.result, rr.termination, rr.loser or 0)
            else
                Comm:Send(sender, "SG", gid)
            end
            return
        end
        Comm:Send(sender, "AK", gid, seq)
        Live:Heard()
        if Live.seen[seq] then return end
        Live.seen[seq] = true
        handler(Live, sender, f[3], f[4], f[5], f[6], f[7])
    end
end

-- game lifecycle ------------------------------------------------------------------------
local function buildGame(id, opp, myColor, tc)
    local me = { name = Names.Me(), kind = "human" }
    local them = { name = opp, kind = "remote" }
    return Game.new({
        id = id, mode = "live",
        white = (myColor == 1) and me or them,
        black = (myColor == 2) and me or them,
        localColor = myColor, tc = tc or nil,
        extra = { opp = opp },
    })
end

function Live:Attach(game, opp)
    self.game = game
    self.opp = opp
    self.mySeq = game.extra and game.extra.mySeq or 0
    self.pending, self.seen = {}, {}
    self.lastHeard = now()
    self.lastHeartbeat = 0
    self.oppOffline = false
    self.flagWaitSince, self.claim = nil, nil
    self.startedAt = now()
    if ns.BotGame and ns.BotGame.game then ns.BotGame:Detach(true) end
    ns.activeGame = game
    ns:SetUpdater("live", function() Live:OnUpdate() end)
    ns:Fire("LIVE_STATE_CHANGED", true)
end

-- c: { id, target|from, tc, myColor }
function Live:StartFromChallenge(c, isChallenger)
    local opp = c.target or c.from
    local game = buildGame(c.id, opp, c.myColor, c.tc)
    self:Attach(game, opp)
    if isChallenger then self:SendReliable("GS") end
    self:Save()
    Compat.PlaySound("start")
    ns.Print("Game on! %s vs %s (%s).", Names.Display(game.players[1].name), Names.Display(game.players[2].name),
        ns.Challenge.Describe(game.tc))
    ns:Fire("GAME_STARTED", game)
end

function Live:OnFinished()
    local g = self.game
    if not g or not g.result then return end
    rememberResult(g)
    ns.db.char.live = nil
    local outcome = g:Outcome(g.localColor)
    ns.Database.AddHistory({
        id = g.id, date = ns.Clock.server(), mode = "live", opponent = self.opp,
        myColor = g.localColor, outcome = outcome, termination = g.termination,
        plies = g:Ply(), moves = table.concat(g.moves, " "), result = g.result,
        timeControl = g.tc and ns.Challenge.TimeControlToWire(g.tc) or "0",
    })
    Compat.PlaySound("finish")
    local text = g:ResultText()
    if outcome == "win" then ns.Print("You won! %s.", text)
    elseif outcome == "loss" then ns.Print("You lost. %s.", text)
    elseif outcome == "draw" then ns.Print("Draw. %s.", text)
    else ns.Print("%s.", text) end
    ns:Fire("GAME_UPDATED", g)
    ns:Fire("GAME_ENDED", g)
    ns:Fire("LIVE_STATE_CHANGED", false)
end

-- Remove a finished game from view (pending messages keep retrying).
function Live:Close()
    if self.game and not self.game.result then return end
    if ns.activeGame == self.game then ns.activeGame = nil end
    self.game = nil
    ns:Fire("GAME_CLOSED")
end

-- local actions ---------------------------------------------------------------------------
function Live:CanMove()
    local g = self.game
    return g ~= nil and not g.result and not self.syncing and g.board.side == g.localColor
end

function Live:HumanMove(uci)
    if not self:CanMove() then return false, self.syncing and "syncing" or "not your turn" end
    local g = self.game
    local info, err = g:Move(uci)
    if not info then return false, err end
    local clock = g.clock and math.floor(g.clock[info.side]) or 0
    self:SendReliable("MV", g:Ply(), info.uci, clock, g.board:hashString())
    self:AfterMove(info)
    return true
end

function Live:AfterMove(info)
    local g = self.game
    if info.check then Compat.PlaySound("check")
    elseif info.capture then Compat.PlaySound("capture")
    else Compat.PlaySound("move") end
    g.drawOfferFrom = nil
    self.flagWaitSince, self.claim = nil, nil
    self.lastMoveAt = now()
    self:Save()
    ns:Fire("GAME_UPDATED", g, info)
    if g.result then self:OnFinished() end
end

function Live:CanAbort()
    local g = self.game
    return g ~= nil and not g.result and g:Ply() < 2
end

function Live:Abort()
    if not self:CanAbort() then return false end
    self.game:Abort()
    self:SendReliable("AB")
    self:OnFinished()
    return true
end

function Live:Resign()
    local g = self.game
    if not g or g.result then return false end
    if g:Ply() < 2 then return self:Abort() end
    g:Resign(g.localColor)
    self:SendReliable("RS")
    self:OnFinished()
    return true
end

-- "Leave": abort before both sides moved, otherwise forfeit.
function Live:Leave()
    local g = self.game
    if not g or g.result then return false end
    if g:Ply() < 2 then return self:Abort() end
    g:Finish(g.localColor == 1 and "0-1" or "1-0", "abandon", g.localColor)
    self:SendReliable("RS", "abandon")
    self:OnFinished()
    return true
end

function Live:OfferDraw()
    local g = self.game
    if not g or g.result or g.drawOfferFrom == g.localColor then return false end
    if g.drawOfferFrom == oppColor(g) then return self:AcceptDraw() end
    g.drawOfferFrom = g.localColor
    self:SendReliable("DO", g:Ply())
    ns:Fire("GAME_UPDATED", g)
    return true
end

function Live:AcceptDraw()
    local g = self.game
    if not g or g.result or g.drawOfferFrom ~= oppColor(g) then return false end
    g:Finish("1/2-1/2", "agreement")
    self:SendReliable("DA", g:Ply())
    self:OnFinished()
    return true
end

function Live:DeclineDraw()
    local g = self.game
    if not g or g.result or g.drawOfferFrom ~= oppColor(g) then return false end
    g.drawOfferFrom = nil
    self:SendReliable("DD", g:Ply())
    ns:Fire("GAME_UPDATED", g)
    return true
end

function Live:SilentFor()
    return now() - (self.lastHeard or now())
end

-- Timed games only: after CLAIM_AFTER seconds without hearing from the opponent.
function Live:CanClaim()
    local g = self.game
    if not g or g.result or not g.tc then return false end
    return self:SilentFor() >= CLAIM_AFTER
end

function Live:ClaimDisconnectWin()
    if not self:CanClaim() then return false end
    local g = self.game
    local opp = oppColor(g)
    g:Finish(opp == 1 and "0-1" or "1-0", "disconnect", opp)
    self:SendReliable("CW")
    self:OnFinished()
    return true
end

-- connection state for the UI: "ok" | "unstable" | "offline" | "syncing" | "locked"
function Live:ConnectionState()
    if not self:IsActive() then return "ok" end
    if Comm.locked then return "locked" end
    if self.syncing then return "syncing" end
    if self.oppOffline then return "offline" end
    if self:SilentFor() >= UNSTABLE_AFTER then return "unstable" end
    return "ok"
end

-- clocks, heartbeats, retries ------------------------------------------------------------
function Live:OnUpdate()
    local t = now()
    if next(self.pending) then self:ProcessPending(t) end
    local g = self.game
    if not g or g.result then return end

    if t - (self.lastHeartbeat or 0) >= HEARTBEAT_INTERVAL then
        self.lastHeartbeat = t
        local mine = g.tc and math.floor(g:Remaining(g.localColor, t)) or 0
        Comm:Send(self.opp, "HB", g.id, g:Ply(), mine)
        local state = self:ConnectionState()
        if state ~= self.lastState then
            self.lastState = state
            ns:Fire("LIVE_CONNECTION", state)
        end
    end

    if self.syncing then
        -- retry quickly at first, then back off while the opponent is away
        local interval = (t - (self.syncStarted or t) < 30) and SYNC_RETRY or 15
        if t - (self.lastSyncSent or 0) >= interval then self:SendSync("q") end
        return
    end

    -- first move must be made in time (timed games), otherwise abort
    if g.tc and g:Ply() < 2 then
        local since = math.max(self.startedAt or t, self.lastMoveAt or 0)
        if t - since > FIRST_MOVE_TIMEOUT then
            if g.board.side == g.localColor then
                ns.Print("You didn't make your first move in time; the game was aborted.")
            else
                ns.Print("%s didn't make a first move in time; the game was aborted.", Names.Display(self.opp))
            end
            self:Abort()
            return
        end
    end

    if g.tc then
        local flagged = g:CheckFlag(t)
        if flagged == g.localColor then
            g:FlagFall(g.localColor)
            self:SendReliable("TO", g:Ply())
            self:OnFinished()
        elseif flagged then
            -- opponent's flag: their client normally reports it; claim if it doesn't
            self.flagWaitSince = self.flagWaitSince or t
            if not self.claim and t - self.flagWaitSince >= FLAG_GRACE then
                self.claim = { at = t }
                self:SendReliable("TC", g:Ply())
            elseif self.claim and t - self.claim.at >= CLAIM_REPLY_TIMEOUT then
                g:FlagFall(oppColor(g))
                self:OnFinished()
            end
        end
    end
end

-- sync ----------------------------------------------------------------------------------------
function Live:SendSync(kind)
    local g = self.game
    if not g then return end
    local t = now()
    self.lastSyncSent = t
    local mine = g.tc and math.floor(g:RawRemaining(g.localColor, t)) or 0
    local elapsed = (g.turnStart and g.tc) and math.floor((t - g.turnStart) * 1000) or 0
    Comm:Send(self.opp, "SY", g.id, kind, g:Ply(), g.board:hashString(), mine, elapsed)
end

function Live:RequestSync(reason)
    if not self.game or self.game.result then return end
    ns.Debug("sync requested (%s)", tostring(reason))
    if not self.syncing then
        self.syncing = true
        self.syncStarted = now()
        ns:Fire("LIVE_CONNECTION", "syncing")
    end
    self:SendSync("q")
end

function Live:SendMoves(fromPly, reset)
    local g = self.game
    local moves = g.moves
    local i = fromPly
    if i > #moves then return end
    while i <= #moves do
        local chunk = {}
        for j = i, math.min(#moves, i + MOVES_PER_CHUNK - 1) do chunk[#chunk + 1] = moves[j] end
        -- only the first chunk of a reset rebuilds; later chunks append
        local flag = (reset and i == fromPly) and "r" or ""
        Comm:Send(self.opp, "SM", g.id, i, table.concat(chunk, ","), flag)
        i = i + MOVES_PER_CHUNK
    end
end

-- Rebuild our game from the opponent's move list (desync recovery).
function Live:ResetFromMoves(moves)
    local old = self.game
    local g = buildGame(old.id, self.opp, old.localColor, old.tc)
    g.createdAt = old.createdAt
    for _, uci in ipairs(moves) do
        if not g:Replay(uci) then break end
    end
    if old.clock then g.clock = { old.clock[1], old.clock[2] } end
    if g.tc and g:Ply() >= 2 then
        g.turnStart = now()
        g.turnStartServer = ns.Clock.server()
    end
    g:SettleStatus()
    self.game = g
    ns.activeGame = g
    self:Save()
end

function Live:FinishSync(theirClock, theirElapsed)
    local g = self.game
    self.syncing = false
    self.syncStarted = nil
    if g.tc and theirClock then
        local opp = oppColor(g)
        local t = now()
        g.clock[opp] = math.max(0, theirClock)
        if g.board.side == opp and g:Ply() >= 2 and theirElapsed then
            -- their clock value already excludes the running turn; restart it from their elapsed
            g.clock[opp] = math.max(0, theirClock + theirElapsed)
            g.turnStart = t - theirElapsed / 1000
        end
    end
    self:Save()
    ns:Fire("LIVE_CONNECTION", "ok")
    ns:Fire("GAME_UPDATED", g)
end

function Live:OnSync(sender, f)
    local gid, kind = f[1], f[2]
    local ply, hash = tonumber(f[3]) or 0, f[4]
    local theirClock, theirElapsed = tonumber(f[5]), tonumber(f[6]) or 0
    local g = self.game
    if not g or g.id ~= gid then
        local rr = ns.db.char.recentResults and ns.db.char.recentResults[gid]
        if rr then
            Comm:Send(sender, "SR", gid, rr.result, rr.termination, rr.loser or 0)
        else
            Comm:Send(sender, "SG", gid)
        end
        return
    end
    if not Names.Same(self.opp, sender) then return end
    self:Heard()
    if g.result then
        Comm:Send(sender, "SR", gid, g.result, g.termination, g.loser or 0)
        return
    end
    local mine = g:Ply()
    if ply < mine then
        self:SendMoves(ply + 1)
        self:SendSync("r")
    elseif ply > mine then
        -- they're ahead: ask for the rest (our "q" carries our ply)
        if kind == "q" then self:SendSync("r") else self:RequestSync("behind") end
    elseif hash ~= g.board:hashString() then
        -- same length, different moves: white's client is authoritative
        if g.localColor == 1 then
            self:SendMoves(1, true)
            self:SendSync("r")
        else
            self:RequestSync("desync")
        end
    else
        if kind == "q" then self:SendSync("r") end
        if self.syncing or kind == "r" then self:FinishSync(theirClock, theirElapsed) end
    end
end

function Live:OnMoves(sender, f)
    local gid, fromPly, list, flag = f[1], tonumber(f[2]), f[3], f[4]
    if not self:Accepts(gid, sender) or not fromPly or not list then return end
    self:Heard()
    local moves = { strsplit(",", list) }
    if flag == "r" then
        if fromPly ~= 1 then return end
        self.resetBuffer = moves
        self:ResetFromMoves(moves)
    else
        local g = self.game
        local applied = false
        for idx, uci in ipairs(moves) do
            local ply = fromPly + idx - 1
            if ply == g:Ply() + 1 then
                if not g:Replay(uci) then break end
                applied = true
            end
        end
        if applied and g.tc and g:Ply() >= 2 then
            g.turnStart = now()
            g.turnStartServer = ns.Clock.server()
        end
        g:SettleStatus()
        if g.result then self:OnFinished(); return end
    end
    self:Save()
    ns:Fire("GAME_UPDATED", self.game)
    self:SendSync("q")
end

-- message handlers -------------------------------------------------------------------------
local H = {}

function H.MV(self, sender, ply, uci, clock, hash)
    local g = self.game
    if g.result then return end
    ply = tonumber(ply)
    local cur = g:Ply()
    if not ply or ply <= cur then return end
    if ply > cur + 1 or g.board.side == g.localColor then
        self:RequestSync("gap")
        return
    end
    local info = g:Move(uci, { remaining = tonumber(clock) })
    if not info then
        self:RequestSync("illegal " .. tostring(uci))
        return
    end
    self.lastMoveAt = now()
    if hash and hash ~= g.board:hashString() then self:RequestSync("hash") end
    self:AfterMove(info)
end

function H.RS(self, sender, how)
    local g = self.game
    if g.result then return end
    local opp = oppColor(g)
    if how == "abandon" then
        g:Finish(opp == 1 and "0-1" or "1-0", "abandon", opp)
    else
        g:Resign(opp)
    end
    self:OnFinished()
end

function H.AB(self)
    local g = self.game
    if g.result then return end
    if g:Ply() <= 2 then
        g:Abort()
    else
        local opp = oppColor(g)
        g:Finish(opp == 1 and "0-1" or "1-0", "abandon", opp)
    end
    self:OnFinished()
end

function H.DO(self, sender, ply)
    local g = self.game
    if g.result or tonumber(ply) ~= g:Ply() then return end
    if g.drawOfferFrom == g.localColor then
        -- both offered at once: that's agreement
        g:Finish("1/2-1/2", "agreement")
        self:OnFinished()
        return
    end
    g.drawOfferFrom = oppColor(g)
    ns:Fire("DRAW_OFFERED", g)
    ns:Fire("GAME_UPDATED", g)
end

function H.DA(self, sender, ply)
    local g = self.game
    if g.result or g.drawOfferFrom ~= g.localColor or tonumber(ply) ~= g:Ply() then return end
    g:Finish("1/2-1/2", "agreement")
    self:OnFinished()
end

function H.DD(self)
    local g = self.game
    if g.result then return end
    if g.drawOfferFrom == g.localColor then
        g.drawOfferFrom = nil
        ns.Print("%s declined your draw offer.", Names.Display(self.opp))
        ns:Fire("GAME_UPDATED", g)
    end
end

function H.TO(self)
    local g = self.game
    if g.result then return end
    g:FlagFall(oppColor(g))
    self:OnFinished()
end

function H.TC(self)
    local g = self.game
    if g.result then return end
    local mine = g:RawRemaining(g.localColor)
    if g.board.side == g.localColor and mine and mine <= 1000 then
        g:FlagFall(g.localColor)
        self:SendReliable("TA")
        self:OnFinished()
    else
        self:SendReliable("TN", math.floor(math.max(mine or 0, 0)))
    end
end

function H.TA(self)
    local g = self.game
    if g.result then return end
    g:FlagFall(oppColor(g))
    self:OnFinished()
end

function H.TN(self, sender, clock)
    local g = self.game
    if g.result then return end
    local opp = oppColor(g)
    clock = tonumber(clock)
    if clock and g.tc and g.board.side == opp then
        g.clock[opp] = clock
        g.turnStart = now()
    end
    self.flagWaitSince, self.claim = nil, nil
    ns:Fire("GAME_UPDATED", g)
end

function H.CW(self)
    local g = self.game
    if g.result then return end
    g:Finish(g.localColor == 1 and "0-1" or "1-0", "disconnect", g.localColor)
    self:OnFinished()
end

function Live:OnEnable()
    for msgType, fn in pairs(H) do
        Comm:Register(msgType, reliable(fn))
    end

    -- GS creates the game on the acceptor's side, so it's handled before Accepts()
    Comm:Register("GS", function(sender, f)
        local gid, seq = f[1], tonumber(f[2])
        if not gid or not seq then return end
        if self.game and self.game.id == gid then
            Comm:Send(sender, "AK", gid, seq)
            return
        end
        local c = ns.Challenge:TakeAccepted(gid, sender)
        if not c then
            -- we didn't (or no longer) expect this game: abort it on their side
            Comm:Send(sender, "AK", gid, seq)
            Comm:Send(sender, "AB", gid, 1)
            return
        end
        if self:IsActive() then
            Comm:Send(sender, "AK", gid, seq)
            Comm:Send(sender, "AB", gid, 1)
            return
        end
        c.from = sender
        self:StartFromChallenge(c, false)
        Comm:Send(sender, "AK", gid, seq)
        self.seen[seq] = true
        self:Heard()
    end)

    Comm:Register("AK", function(sender, f)
        local gid, seq = f[1], tonumber(f[2])
        local p = seq and self.pending[seq]
        if p and p.gid == gid and Names.Same(p.to, sender) then self.pending[seq] = nil end
        if self.game and self.game.id == gid and Names.Same(self.opp, sender) then self:Heard() end
    end)

    Comm:Register("HB", function(sender, f)
        if not self:Accepts(f[1], sender) then return end
        self:Heard()
        local g = self.game
        local theirPly = tonumber(f[2])
        if theirPly and not g.result and not self.syncing then
            if theirPly > g:Ply() + 1 or (theirPly > g:Ply() and g.board.side == g.localColor) then
                self:RequestSync("heartbeat")
            end
        end
    end)

    Comm:Register("SY", function(sender, f) self:OnSync(sender, f) end)
    Comm:Register("SM", function(sender, f) self:OnMoves(sender, f) end)

    Comm:Register("SR", function(sender, f)
        local g = self.game
        if not self:Accepts(f[1], sender) or g.result then return end
        local loser = tonumber(f[4])
        g:Finish(f[2], f[3], (loser and loser > 0) and loser or nil)
        self.syncing = false
        self:OnFinished()
    end)

    Comm:Register("SG", function(sender, f)
        local g = self.game
        if not self:Accepts(f[1], sender) or g.result then return end
        ns.Print("%s no longer has this game; it was aborted.", Names.Display(self.opp))
        self.syncing = false
        g:Abort()
        self:OnFinished()
    end)

    ns:On("COMM_TARGET_OFFLINE", function(name)
        if self.game and not self.game.result and name and Names.Same(self.opp, name) then
            if not self.oppOffline then
                self.oppOffline = true
                ns:Fire("LIVE_CONNECTION", "offline")
            end
        end
    end)

    ns:On("LOGOUT", function() self:Save() end)

    -- resume a game interrupted by /reload, logout or a crash
    local t = ns.db.char.live
    if t then
        local ok, g = pcall(Game.Deserialize, t)
        if ok and g and not g.result then
            local opp = t.extra and t.extra.opp
            self:Attach(g, opp)
            self.mySeq = t.extra and t.extra.mySeq or 0
            self.syncing = true
            self.syncStarted = now()
            self.lastSyncSent = 0
            C_Timer.After(3, function()
                if self.syncing then self:SendSync("q") end
            end)
            ns.Print("Resuming your game against %s. Reconnecting...", Names.Display(opp))
            ns:Fire("GAME_STARTED", g)
        else
            ns.db.char.live = nil
        end
    end
end

return Live
