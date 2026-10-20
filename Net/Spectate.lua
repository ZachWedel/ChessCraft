--[[
    Chess Craft - Net/Spectate.lua
    Watching other players' live games, with a chat for the spectators.

    The spectator asks one of the two players (the "host"); the host's addon
    sends the game so far and then every move with both clocks. Spectators
    can talk to each other through the host, who passes messages on to all
    spectators. The players themselves never see the spectator chat (so
    nobody can be fed moves), but they do see who is watching.

    Spectator -> host                       Host -> spectator
      WQ~nonce          watch request          WA~gid~nonce~white~black~tc~fen    accepted
      WG~gid~havePly    "I'm missing moves"    WN~nonce~reason                    refused
      WH~gid            still watching         WV~gid~fromPly~uci,uci,...         moves (chunks)
      WC~gid~text       chat message           WK~gid~ply~clockW~clockB~runMs     clocks / heartbeat
      WX~gid            stopped watching       WM~gid~ply~uci~clockW~clockB       a new move
                                               WR~gid~from~text                   chat (to everyone)
                                               WE~gid~result~termination~loser    game over
    Host -> opponent:   WL~gid~name,name,...   who is watching through me
                        WF~gid~from~text       spectator chat for the opponent's spectators

    All are new message types: older versions ignore them. Spectator traffic
    goes through Comm's low-priority queue so it never delays the game itself.
]]

local _, ns = ...
local Comm, Names, Compat = ns.Comm, ns.Names, ns.Compat

local Spectate = ns:NewModule("Spectate")
Spectate.watchers = {}       -- host side: name -> { heard, lastChat }
Spectate.oppWatchers = {}    -- names watching through our opponent
Spectate.chat = {}           -- spectator side: { from, text, at, system }

local MAX_WATCHERS = 10
local WATCHER_TIMEOUT = 60
local HOST_HEARTBEAT = 15
local SPECTATOR_HEARTBEAT = 20
local HOST_SILENT = 40
local CHAT_GAP = 1.5
local CHAT_MAX = 180
local CHAT_KEEP = 80
local MOVES_PER_CHUNK = 30
local JOIN_TIMEOUT = 8

local function now() return ns.Clock.now() end
local function liveGame()
    local g = ns.Live and ns.Live.game
    if g and not g.result then return g end
    return nil
end

-- who may watch my games -------------------------------------------------------------------
function Spectate:Allows(sender)
    local mode = ns.db.settings.allowSpectators or "everyone"
    if mode == "nobody" then return false end
    if mode == "friends" then return ns.Presence.IsKnown(sender) end
    return true
end

-- the names watching the game I'm playing (mine and my opponent's)
function Spectate:WatcherNames()
    local out, seen = {}, {}
    for name in pairs(self.watchers) do
        out[#out + 1] = name; seen[name:lower()] = true
    end
    for _, name in ipairs(self.oppWatchers) do
        if not seen[name:lower()] then out[#out + 1] = name; seen[name:lower()] = true end
    end
    table.sort(out)
    return out
end

-- host side --------------------------------------------------------------------------------------
local function clocks(g)
    if not g.tc then return 0, 0, 0 end
    local t = now()
    local run = (g.turnStart and not g.result) and math.floor((t - g.turnStart) * 1000) or 0
    return math.floor(g.clock[1]), math.floor(g.clock[2]), run
end

function Spectate:SendGameTo(name, g, fromPly)
    local moves = g.moves
    local i = fromPly or 1
    while i <= #moves do
        local chunk = {}
        for j = i, math.min(#moves, i + MOVES_PER_CHUNK - 1) do chunk[#chunk + 1] = moves[j] end
        Comm:SendLow(name, "WV", g.id, i, table.concat(chunk, ","))
        i = i + MOVES_PER_CHUNK
    end
    local w, b, run = clocks(g)
    Comm:SendLow(name, "WK", g.id, g:Ply(), w, b, run)
end

function Spectate:BroadcastWatchers()
    local g = liveGame()
    if not g then return end
    local names = {}
    for name in pairs(self.watchers) do names[#names + 1] = name end
    table.sort(names)
    -- the opponent shows them too (names are short; keep under the size limit)
    local list = table.concat(names, ","):sub(1, 200)
    Comm:SendLow(ns.Live.opp, "WL", g.id, list)
    self:PushListToSpectators()
    ns:Fire("SPECTATORS_CHANGED")
end

-- spectators see everyone watching the game (through either player)
function Spectate:PushListToSpectators()
    local g = liveGame()
    if not g or not next(self.watchers) then return end
    local list = table.concat(self:WatcherNames(), ","):sub(1, 200)
    for name in pairs(self.watchers) do Comm:SendLow(name, "WL", g.id, list) end
end

function Spectate:DropWatcher(name, quiet)
    if not self.watchers[name] then return end
    self.watchers[name] = nil
    if not quiet then self:BroadcastWatchers() end
end

function Spectate:OnHostMove(g, info)
    if not next(self.watchers) then return end
    local w, b = clocks(g)
    for name in pairs(self.watchers) do
        Comm:SendLow(name, "WM", g.id, g:Ply(), info.uci, w, b)
    end
end

function Spectate:OnHostEnded(g)
    for name in pairs(self.watchers) do
        Comm:SendLow(name, "WE", g.id, g.result or "*", g.termination or "", g.loser or 0)
    end
    self.watchers = {}
    self.oppWatchers = {}
    ns:Fire("SPECTATORS_CHANGED")
end

function Spectate:HostTick(t)
    local g = liveGame()
    if not g then
        if next(self.watchers) then self.watchers = {} end
        return
    end
    local changed = false
    for name, w in pairs(self.watchers) do
        if t - w.heard > WATCHER_TIMEOUT then
            self.watchers[name] = nil
            changed = true
        end
    end
    if changed then self:BroadcastWatchers() end
    if next(self.watchers) and t - (self.lastHostBeat or 0) >= HOST_HEARTBEAT then
        self.lastHostBeat = t
        local w, b, run = clocks(g)
        for name in pairs(self.watchers) do Comm:SendLow(name, "WK", g.id, g:Ply(), w, b, run) end
        self:BroadcastWatchers()
    end
end

-- spectator side ------------------------------------------------------------------------------
function Spectate:IsWatching() return self.game ~= nil end
function Spectate:Game() return self.game end

function Spectate:CanWatch()
    if Compat.IsTrial() then return false, "Trial accounts can't send addon messages, so watching games isn't available." end
    if ns.Live and ns.Live:IsActive() then return false, "You can't watch while you are playing a live game." end
    return true
end

-- Games can be watched through players on 0.3.1 or later.
Spectate.MIN_HOST_VERSION = "0.3.1"
function Spectate.HostSupports(version)
    return not version or version == "" or Compat.CompareVersions(version, Spectate.MIN_HOST_VERSION) >= 0
end

-- What the board shows while joining (or nil).
function Spectate:PendingInfo()
    local p = self.joining
    if p and now() - p.at < JOIN_TIMEOUT then return p end
    return nil
end

function Spectate:Watch(name)
    local ok, why = self:CanWatch()
    if not ok then ns.Print(why); return false end
    local target = Names.Normalize(name)
    if not target then ns.Print("Enter the name of the player whose game you want to watch."); return false end
    if Names.IsMe(target) then return false end
    local known = ns.Presence and ns.Presence:Get(target)
    if known and not Spectate.HostSupports(known.version) then
        ns.Print("%s has Chess Craft %s. Games can be watched once both players have %s or later.",
            Names.Display(target), known.version, Spectate.MIN_HOST_VERSION)
        return false
    end
    self:Stop(true)
    local nonce = tostring(math.random(100000, 999999))
    self.joining = { name = target, nonce = nonce, at = now() }
    self.lastOutcome = nil
    Comm:Send(target, "WQ", nonce)
    ns:Fire("SPECTATE_JOINING", target)
    C_Timer.After(JOIN_TIMEOUT, function()
        if self.joining and self.joining.nonce == nonce then
            self.joining = nil
            self.lastOutcome = string.format("%s didn't answer. They may not be in a match, or may have an older Chess Craft.",
                Names.Display(target))
            ns.Print(self.lastOutcome)
            ns:Fire("SPECTATE_CHANGED")
        end
    end)
    return true
end

-- Stop watching (quiet: no message, e.g. when starting something else).
function Spectate:Stop(quiet)
    local g = self.game
    if self.joining then self.joining = nil end
    if not g then return end
    if self.host and not g.result then Comm:SendLow(self.host, "WX", g.id) end
    self.game, self.host = nil, nil
    self.chat = {}
    self.spectators = {}
    if ns.activeGame == g then ns.activeGame = nil end
    ns:SetUpdater("spectate-watch", nil)
    ns:Fire("SPECTATE_CHANGED")
    if not quiet then ns:Fire("GAME_CLOSED") end
end

local function addChat(self, from, text, system)
    local c = self.chat
    c[#c + 1] = { from = from, text = text, at = now(), system = system }
    while #c > CHAT_KEEP do table.remove(c, 1) end
    ns:Fire("SPECTATE_CHAT")
end

function Spectate:SendChat(text)
    local g = self.game
    if not g or not self.host then return false, "You are not watching a game." end
    text = ns.Profile.Sanitize(text, CHAT_MAX)
    if text == "" then return false end
    if ns.WordFilter.IsBlocked(text) then
        return false, "Message not sent: it contains words that aren't allowed."
    end
    local t = now()
    if self.lastChatSent and t - self.lastChatSent < CHAT_GAP then
        return false, "Slow down a little."
    end
    self.lastChatSent = t
    Comm:Send(self.host, "WC", g.id, text)
    return true
end

function Spectate:BeginGame(host, gid, white, black, tcWire, fen)
    local Game = ns.Game
    local tc = (tcWire and tcWire ~= "0") and ns.Challenge.WireToTimeControl(tcWire) or nil
    local ok, g = pcall(Game.new, {
        id = gid, mode = "spectate",
        white = { name = white, kind = "remote" }, black = { name = black, kind = "remote" },
        localColor = 1, tc = tc, startFEN = (fen and fen ~= "") and fen or nil,
    })
    if not ok or not g then return end
    g.spectating = true
    self.game, self.host = g, host
    self.lastHostHeard = now()
    self.lastBeat = now()
    self.chat = {}
    self.spectators = {}
    ns.activeGame = g
    addChat(self, nil, string.format("You are watching %s vs %s. The players can't see this chat.",
        Names.Display(white), Names.Display(black)), true)
    ns:SetUpdater("spectate-watch", function() Spectate:WatchTick() end)
    ns.Profile:Request(white)
    ns.Profile:Request(black)
    ns:Fire("GAME_STARTED", g)
    ns:Fire("SPECTATE_CHANGED")
end

function Spectate:ApplyClocks(ply, w, b, run)
    local g = self.game
    if not g or not g.tc then return end
    w, b, run = tonumber(w), tonumber(b), tonumber(run) or 0
    if w then g.clock[1] = w end
    if b then g.clock[2] = b end
    if g:Ply() >= 2 and not g.result then
        g.turnStart = now() - run / 1000
    else
        g.turnStart = nil
    end
end

function Spectate:WatchTick()
    local g = self.game
    if not g then return end
    local t = now()
    if not g.result and t - self.lastBeat >= SPECTATOR_HEARTBEAT then
        self.lastBeat = t
        Comm:SendLow(self.host, "WH", g.id)
    end
    if not g.result and t - self.lastHostHeard >= HOST_SILENT and not self.reconnecting then
        -- the host may have reloaded: ask to watch again
        self.reconnecting = true
        addChat(self, nil, "Lost contact with the game. Reconnecting...", true)
        Comm:Send(self.host, "WQ", "re")
        C_Timer.After(10, function() self.reconnecting = false; self.lastHostHeard = now() end)
    end
end

-- messages -------------------------------------------------------------------------------------
function Spectate:OnEnable()
    -- host side
    Comm:Register("WQ", function(sender, f)
        local nonce = f[1] or ""
        local g = liveGame()
        if not g then Comm:Send(sender, "WN", nonce, "notplaying"); return end
        if not self:Allows(sender) then Comm:Send(sender, "WN", nonce, "private"); return end
        if Names.Same(sender, ns.Live.opp) then Comm:Send(sender, "WN", nonce, "opponent"); return end
        local count = 0
        for _ in pairs(self.watchers) do count = count + 1 end
        if not self.watchers[sender] and count >= MAX_WATCHERS then Comm:Send(sender, "WN", nonce, "full"); return end
        local isNew = not self.watchers[sender]
        self.watchers[sender] = { heard = now() }
        local white, black = g.players[1].name, g.players[2].name
        Comm:Send(sender, "WA", g.id, nonce, white, black, ns.Challenge.TimeControlToWire(g.tc),
            g:IsStandardStart() and "" or g.startFEN)
        self:SendGameTo(sender, g, 1)
        if isNew then
            for name in pairs(self.watchers) do
                if name ~= sender then
                    Comm:SendLow(name, "WR", g.id, "", Names.Display(sender) .. " started watching.")
                end
            end
            self:BroadcastWatchers()
        end
    end)
    Comm:Register("WG", function(sender, f)
        local g = liveGame()
        if not g or g.id ~= f[1] or not self.watchers[sender] then return end
        self.watchers[sender].heard = now()
        self:SendGameTo(sender, g, (tonumber(f[2]) or 0) + 1)
    end)
    Comm:Register("WH", function(sender, f)
        local w = self.watchers[sender]
        if w then w.heard = now() end
    end)
    Comm:Register("WX", function(sender, f)
        local g = liveGame()
        if self.watchers[sender] then
            self:DropWatcher(sender)
            if g then
                for name in pairs(self.watchers) do
                    Comm:SendLow(name, "WR", g.id, "", Names.Display(sender) .. " stopped watching.")
                end
            end
        end
    end)
    Comm:Register("WC", function(sender, f)
        local g = liveGame()
        local w = self.watchers[sender]
        if not g or g.id ~= f[1] or not w then return end
        local t = now()
        w.heard = t
        if w.lastChat and t - w.lastChat < CHAT_GAP then return end
        w.lastChat = t
        local text = ns.Profile.Sanitize(f[2], CHAT_MAX)
        if text == "" or ns.WordFilter.IsBlocked(text) then return end
        for name in pairs(self.watchers) do
            Comm:SendLow(name, "WR", g.id, sender, text)
        end
        -- spectators watching through the other player get it too
        Comm:SendLow(ns.Live.opp, "WF", g.id, sender, text)
    end)
    Comm:Register("WF", function(sender, f)
        local g = liveGame()
        if not g or g.id ~= f[1] or not Names.Same(sender, ns.Live.opp) then return end
        local text = ns.Profile.Sanitize(f[3], CHAT_MAX)
        if text == "" or ns.WordFilter.IsBlocked(text) then return end
        for name in pairs(self.watchers) do
            Comm:SendLow(name, "WR", g.id, f[2], text)
        end
    end)
    Comm:Register("WL", function(sender, f)
        local list = {}
        for name in tostring(f[2] or ""):gmatch("[^,]+") do list[#list + 1] = name end
        local g = liveGame()
        if g and g.id == f[1] and Names.Same(sender, ns.Live.opp) then
            self.oppWatchers = list
            self:PushListToSpectators()
            ns:Fire("SPECTATORS_CHANGED")
        elseif self.game and self.game.id == f[1] and Names.Same(self.host, sender) then
            self.spectators = list
            ns:Fire("SPECTATE_CHAT")
        end
    end)

    -- spectator side
    Comm:Register("WA", function(sender, f)
        local gid, nonce = f[1], f[2]
        local j = self.joining
        if self.game and self.game.id == gid and Names.Same(self.host, sender) then
            -- reconnected to the same game: catch up on moves
            self.lastHostHeard = now()
            self.reconnecting = false
            return
        end
        if not j or j.nonce ~= nonce then return end
        self.joining = nil
        self:BeginGame(sender, gid, f[3], f[4], f[5], f[6])
    end)
    Comm:Register("WN", function(sender, f)
        local j = self.joining
        if not j or j.nonce ~= f[1] then return end
        self.joining = nil
        local why = ({
            notplaying = "%s isn't playing a live game right now.",
            private = "%s doesn't allow spectators.",
            full = "%s's game already has the most spectators allowed.",
            opponent = "You're playing %s already.",
        })[f[2] or ""] or "%s's game can't be watched right now."
        self.lastOutcome = string.format(why, Names.Display(sender))
        ns.Print(self.lastOutcome)
        ns:Fire("SPECTATE_CHANGED")
    end)
    Comm:Register("WV", function(sender, f)
        local g = self.game
        if not g or g.id ~= f[1] or not Names.Same(self.host, sender) then return end
        self.lastHostHeard = now()
        local fromPly = tonumber(f[2]) or 1
        local applied, last = false, nil
        local i = fromPly
        for uci in tostring(f[3] or ""):gmatch("[^,]+") do
            if i == g:Ply() + 1 then
                if not g:Replay(uci) then break end
                applied, last = true, i
            end
            i = i + 1
        end
        if applied then
            g:SettleStatus()
            ns:Fire("GAME_UPDATED", g)
        end
    end)
    Comm:Register("WK", function(sender, f)
        local g = self.game
        if not g or g.id ~= f[1] or not Names.Same(self.host, sender) then return end
        self.lastHostHeard = now()
        local ply = tonumber(f[2]) or 0
        if ply > g:Ply() then
            Comm:SendLow(sender, "WG", g.id, g:Ply())
        elseif ply == g:Ply() then
            self:ApplyClocks(ply, f[3], f[4], f[5])
            ns:Fire("GAME_UPDATED", g)
        end
    end)
    Comm:Register("WM", function(sender, f)
        local g = self.game
        if not g or g.id ~= f[1] or not Names.Same(self.host, sender) or g.result then return end
        self.lastHostHeard = now()
        local ply = tonumber(f[2]) or 0
        if ply ~= g:Ply() + 1 then
            if ply > g:Ply() + 1 then Comm:SendLow(sender, "WG", g.id, g:Ply()) end
            return
        end
        local side = g.board.side
        if not g:Replay(f[3]) then
            Comm:SendLow(sender, "WG", g.id, g:Ply())
            return
        end
        self:ApplyClocks(ply, f[4], f[5], 0)
        g:SettleStatus()
        local m = g.moveInts[#g.moveInts]
        ns:Fire("GAME_UPDATED", g, { move = m, uci = f[3], side = side, san = g.sans[#g.sans] })
    end)
    Comm:Register("WE", function(sender, f)
        local g = self.game
        if not g or g.id ~= f[1] or not Names.Same(self.host, sender) then return end
        if not g.result then
            local loser = tonumber(f[4])
            g:Finish(f[2], f[3], (loser and loser > 0) and loser or nil)
            addChat(self, nil, "The game is over: " .. (g:ResultText() or "") .. ".", true)
            ns:Fire("GAME_UPDATED", g)
            ns:Fire("GAME_ENDED", g)
        end
    end)
    Comm:Register("WR", function(sender, f)
        local g = self.game
        if not g or g.id ~= f[1] or not Names.Same(self.host, sender) then return end
        self.lastHostHeard = now()
        local from = f[2]
        local text = ns.Profile.Sanitize(f[3], CHAT_MAX)
        if text == "" then return end
        if from == nil or from == "" then
            addChat(self, nil, text, true)
            return
        end
        if ns.WordFilter.IsBlocked(text) then return end
        local list = self.spectators
        local known = false
        for _, n in ipairs(list) do if Names.Same(n, from) then known = true end end
        if not known then list[#list + 1] = from end
        addChat(self, from, text)
    end)

    -- hooks into our own live games
    ns:On("GAME_UPDATED", function(g, info)
        if info and g == liveGame() then self:OnHostMove(g, info) end
        if g == ns.Live.game and not info and next(self.watchers) and not g.result then
            -- a resync rebuilt the game: send everyone a fresh clock/ply so they can catch up
            local w, b, run = clocks(g)
            for name in pairs(self.watchers) do Comm:SendLow(name, "WK", g.id, g:Ply(), w, b, run) end
        end
    end)
    ns:On("GAME_ENDED", function(g)
        if g == ns.Live.game then self:OnHostEnded(g) end
    end)
    -- starting anything else ends spectating
    ns:On("GAME_STARTED", function(g)
        if self.game and g ~= self.game then self:Stop(true) end
    end)
    ns:On("CHALLENGE_SENT", function() self:Stop(true) end)
    ns:On("CHALLENGE_ACCEPTED_LOCAL", function() self:Stop(true) end)
    ns:On("LIVE_STATE_CHANGED", function(active)
        if active and self.game then self:Stop(true) end
        if not active then self.oppWatchers = {} end
    end)

    local acc = 0
    ns:SetUpdater("spectate-host", function(elapsed)
        acc = acc + elapsed
        if acc < 1 then return end
        acc = 0
        Spectate:HostTick(now())
    end)
end

return Spectate
