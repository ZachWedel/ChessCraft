--[[
    Chess Craft - Net/Challenge.lua
    Challenging another player, Peggle-duel style.

      CH~id~proto~version~yourColor(w|b)~tc      challenger -> target (re-sent until answered)
      CR~id                                       target -> challenger: "challenge received"
      CA~id~proto~version                         target accepts (re-sent until the game starts)
      CD~id~reason[~proto~version]                target declines (declined|busy|version|nobody)
      CX~id                                       challenger cancels / challenge no longer valid

    After CA the challenger shows "accepted, starting shortly", waits
    START_DELAY seconds, then starts the game and sends GS (Net/Live.lua).

    Every message is matched by challenge id, never by the typed name: the
    name a player types ("Bob Ironforge") need not match the exact sender
    string the server puts on addon messages, so the sender of the first
    reply becomes the opponent's canonical name.
]]

local _, ns = ...
local Compat, Comm, Names = ns.Compat, ns.Comm, ns.Names

local Challenge = ns:NewModule("Challenge")
Challenge.outgoing = nil
Challenge.incoming = {}

local CHALLENGE_TIMEOUT = 60
local NO_ANSWER_HINT = 12
local START_TIMEOUT = 25
local RESEND_INTERVAL = 4
local ACCEPT_RESEND = 3
Challenge.START_DELAY = 3

local function now() return ns.Clock.now() end

-- time controls (seconds) -------------------------------------------------------
Challenge.TIME_CONTROLS = {
    { key = "1+0",   base = 60,   inc = 0,  label = "Bullet 1+0" },
    { key = "2+1",   base = 120,  inc = 1,  label = "Bullet 2+1" },
    { key = "3+2",   base = 180,  inc = 2,  label = "Blitz 3+2" },
    { key = "5+0",   base = 300,  inc = 0,  label = "Blitz 5+0" },
    { key = "5+3",   base = 300,  inc = 3,  label = "Blitz 5+3" },
    { key = "10+0",  base = 600,  inc = 0,  label = "Rapid 10+0" },
    { key = "10+5",  base = 600,  inc = 5,  label = "Rapid 10+5" },
    { key = "15+10", base = 900,  inc = 10, label = "Rapid 15+10" },
    { key = "30+0",  base = 1800, inc = 0,  label = "Classical 30+0" },
    { key = "inf",   label = "Infinite (no clock)" },
}

-- "5+3" -> { base = 300000, inc = 3000 }; "inf" -> false (untimed); bad -> nil
function Challenge.ParseTimeControl(text)
    if not text or text == "" then text = ns.db and ns.db.char.lastTimeControl or "5+3" end
    text = tostring(text):lower():gsub("%s", "")
    if text == "inf" or text == "infinite" or text == "none" or text == "untimed" or text == "0" or text == "0+0" then
        return false
    end
    local m, i = text:match("^(%d+%.?%d*)%+(%d+)$")
    if not m then m = text:match("^(%d+%.?%d*)$"); i = "0" end
    m, i = tonumber(m), tonumber(i)
    if not m or m <= 0 or m > 180 or i > 180 then return nil end
    return { base = math.floor(m * 60000), inc = math.floor(i * 1000) }
end

function Challenge.TimeControlToWire(tc)
    if not tc then return "0" end
    return string.format("%d+%d", math.floor(tc.base / 1000), math.floor(tc.inc / 1000))
end

function Challenge.WireToTimeControl(w)
    local b, i = tostring(w or ""):match("^(%d+)%+(%d+)$")
    b, i = tonumber(b), tonumber(i)
    if not b or b <= 0 then return nil end
    return { base = b * 1000, inc = (i or 0) * 1000 }
end

function Challenge.Describe(tc)
    if not tc then return "Infinite (no clock)" end
    local mins = tc.base / 60000
    local key = (mins == math.floor(mins) and tostring(math.floor(mins)) or string.format("%.1f", mins))
        .. "+" .. math.floor(tc.inc / 1000)
    for _, p in ipairs(Challenge.TIME_CONTROLS) do
        if p.key == key then return p.label end
    end
    return key
end

local function colorName(c) return c == 1 and "White" or "Black" end

-- Remember how the last challenge ended so the board can say so.
local function setOutcome(text)
    Challenge.lastOutcome = { text = text, at = now() }
end

-- outgoing -----------------------------------------------------------------------------
function Challenge:CanChallenge()
    if Compat.IsTrial() then
        return false, "Trial accounts can't send addon messages, so live games aren't available. You can still play the bots."
    end
    if ns.Live and ns.Live:IsActive() then return false, "Finish or leave your current live game first." end
    return true
end

local function sendCH(o)
    o.lastSent = now()
    local prof = ns.Profile and ns.Profile:Data()
    Comm:Send(o.target, "CH", o.id, ns.PROTOCOL, ns.version, (o.myColor == 1) and "b" or "w",
        Challenge.TimeControlToWire(o.tc), prof and prof.rating or "", prof and prof.games or "")
end

-- tc: table (timed) or false/nil (infinite). colorPref: "white" | "black" | "random"
function Challenge:SendTo(name, tc, colorPref)
    local ok, why = self:CanChallenge()
    if not ok then ns.Print(why); return false end
    if tc == nil then tc = false end
    local target = Names.Normalize(name)
    if not target then ns.Print("Enter a player name (or target someone first)."); return false end
    if Names.IsMe(target) then ns.Print("You can't challenge yourself."); return false end
    if ns.Presence and ns.Presence:IsBusy(target) then
        local text = string.format("%s is in a match right now. You can watch it instead (Watch on the Play tab).",
            Names.Display(target))
        ns.Print(text)
        setOutcome(text)
        ns:Fire("CHALLENGES_CHANGED")
        return false
    end
    local prev = self.outgoing
    if prev then
        -- asking the same player again just re-sends the open challenge
        if Names.Same(prev.target, target) and prev.state == "pending" then
            sendCH(prev)
            ns:Fire("CHALLENGE_SENT", prev)
            return true
        end
        self:Cancel(true)
    end

    local myColor
    if colorPref == "white" then myColor = 1 elseif colorPref == "black" then myColor = 2 else myColor = math.random(1, 2) end
    local o = { id = ns.NewId(), target = target, tc = tc or nil, myColor = myColor, sentAt = now(), state = "pending" }
    self.outgoing = o
    Challenge.lastOutcome = nil
    sendCH(o)
    ns.db.char.lastColor = colorPref or "random"
    ns.Print("Challenge sent to %s: %s, you play %s.", Names.Display(target), Challenge.Describe(o.tc), colorName(myColor))
    ns:Fire("CHALLENGE_SENT", o)
    ns:Fire("CHALLENGES_CHANGED")

    C_Timer.After(NO_ANSWER_HINT, function()
        if self.outgoing == o and o.state == "pending" and not o.heard then
            ns.Print("No answer from %s yet. They may be away, offline, or not have Chess Craft installed.", Names.Display(o.target))
        end
    end)
    C_Timer.After(CHALLENGE_TIMEOUT, function()
        if self.outgoing == o and o.state == "pending" then
            self.outgoing = nil
            Comm:Send(o.target, "CX", o.id)
            local text = string.format("%s didn't answer your challenge.", Names.Display(o.target))
            setOutcome(text)
            ns.Print("Your challenge to %s expired.", Names.Display(o.target))
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)
    return true
end

function Challenge:Cancel(silent)
    local o = self.outgoing
    if not o then return end
    self.outgoing = nil
    Comm:Send(o.target, "CX", o.id)
    if not silent then
        ns.Print("Challenge to %s cancelled.", Names.Display(o.target))
        setOutcome("You cancelled the challenge.")
    end
    ns:Fire("CHALLENGES_CHANGED")
end

-- What the board should show while a game is being set up (or nil):
-- { role = "challenger"|"acceptor", name, tc, myColor, state = "pending"|"seen"|"starting"|"accepted", startAt }
function Challenge:PendingStart()
    local o = self.outgoing
    if o then
        return { role = "challenger", id = o.id, name = o.target, tc = o.tc, myColor = o.myColor,
                 state = (o.state == "starting") and "starting" or (o.heard and "seen" or "pending"), startAt = o.startAt }
    end
    for _, c in pairs(self.incoming) do
        if c.state == "accepted" then
            return { role = "acceptor", id = c.id, name = c.from, tc = c.tc, myColor = c.myColor, state = "accepted" }
        end
    end
    return nil
end

-- incoming -------------------------------------------------------------------------------
function Challenge:ListIncoming()
    local out = {}
    for _, c in pairs(self.incoming) do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.receivedAt < b.receivedAt end)
    return out
end

function Challenge:Accept(id)
    local c = self.incoming[id]
    if not c then return false end
    if ns.Live and ns.Live:IsActive() then
        ns.Print("Finish or leave your current live game first.")
        return false
    end
    if c.state == "accepted" then return true end
    -- only one accepted challenge at a time
    for oid, other in pairs(self.incoming) do
        if oid ~= id and other.state == "accepted" then self:Decline(oid, "busy") end
    end
    if self.outgoing then self:Cancel(true) end
    c.state = "accepted"
    c.acceptedAt = now()
    c.lastSent = now()
    Challenge.lastOutcome = nil
    Comm:Send(c.from, "CA", id, ns.PROTOCOL, ns.version)
    ns:Fire("CHALLENGE_ACCEPTED_LOCAL", c)
    ns:Fire("CHALLENGES_CHANGED")
    C_Timer.After(START_TIMEOUT, function()
        if self.incoming[id] == c and c.state == "accepted" then
            self.incoming[id] = nil
            setOutcome(string.format("%s never started the game. Try challenging them again.", Names.Display(c.from)))
            ns.Print("%s did not confirm the game start; the challenge was dropped.", Names.Display(c.from))
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)
    return true
end

function Challenge:Decline(id, reason)
    local c = self.incoming[id]
    if not c then return end
    self.incoming[id] = nil
    Comm:Send(c.from, "CD", id, reason or "declined")
    ns:Fire("CHALLENGES_CHANGED")
end

-- Called by Live when GS arrives: returns the accepted challenge (and forgets it).
function Challenge:TakeAccepted(id, sender)
    local c = self.incoming[id]
    if c and c.state == "accepted" then
        self.incoming[id] = nil
        c.from = sender -- canonical name from the server
        ns:Fire("CHALLENGES_CHANGED")
        return c
    end
    return nil
end

-- retries ------------------------------------------------------------------------------------
function Challenge:OnUpdate()
    local t = now()
    local o = self.outgoing
    if o and o.state == "pending" and t - (o.lastSent or 0) >= RESEND_INTERVAL then
        sendCH(o)
    end
    for _, c in pairs(self.incoming) do
        if c.state == "accepted" and t - (c.lastSent or 0) >= ACCEPT_RESEND then
            c.lastSent = t
            Comm:Send(c.from, "CA", c.id, ns.PROTOCOL, ns.version)
        end
    end
end

local DECLINE_TEXT = {
    declined = "%s declined your challenge.",
    busy = "%s is already in a game.",
    nobody = "%s isn't accepting challenges right now.",
    version = "%s can't play you: your Chess Craft versions are incompatible. One of you needs to update.",
}

function Challenge:OnEnable()
    Comm:Register("CH", function(sender, f)
        local id, proto, version, colorCode, tcWire = f[1], tonumber(f[2]), f[3], f[4], f[5]
        if not id or id == "" then return end
        if ns.Presence then ns.Presence:Seen(sender, version, proto, "idle", nil) end
        if proto ~= ns.PROTOCOL then
            Comm:Send(sender, "CD", id, "version", ns.PROTOCOL, ns.version)
            if not self.warnedVersion or self.warnedVersion ~= id then
                self.warnedVersion = id
                ns.Print("%s challenged you, but uses Chess Craft %s (incompatible with your %s). One of you needs to update.",
                    Names.Display(sender), tostring(version), ns.version)
            end
            return
        end
        local existing = self.incoming[id]
        if existing then
            -- a re-sent challenge: confirm again (and our acceptance, if given)
            Comm:Send(sender, "CR", id)
            if existing.state == "accepted" then Comm:Send(sender, "CA", id, ns.PROTOCOL, ns.version) end
            return
        end
        if ns.Live and ns.Live.game and ns.Live.game.id == id then return end -- already playing it
        if ns.Live and ns.Live:IsActive() then
            Comm:Send(sender, "CD", id, "busy")
            return
        end
        local mode = ns.db.settings.acceptFrom
        if mode == "nobody" or (mode == "friends" and not ns.Presence.IsKnown(sender)) then
            Comm:Send(sender, "CD", id, "nobody")
            return
        end
        local tc = nil
        if tcWire and tcWire ~= "0" then
            tc = Challenge.WireToTimeControl(tcWire)
            if not tc then Comm:Send(sender, "CD", id, "version"); return end
        end
        local c = { id = id, from = sender, tc = tc, myColor = (colorCode == "w") and 1 or 2,
                    version = version, receivedAt = now(), state = "pending",
                    rating = tonumber(f[6]), ratingGames = tonumber(f[7]) }
        self.incoming[id] = c
        Comm:Send(sender, "CR", id)
        Compat.PlaySound("challenge")
        ns:Fire("CHALLENGE_RECEIVED", c)
        ns:Fire("CHALLENGES_CHANGED")
        C_Timer.After(CHALLENGE_TIMEOUT, function()
            if self.incoming[id] == c and c.state == "pending" then
                self.incoming[id] = nil
                ns:Fire("CHALLENGE_EXPIRED", c)
                ns:Fire("CHALLENGES_CHANGED")
            end
        end)
    end)

    Comm:Register("CR", function(sender, f)
        local o = self.outgoing
        if not o or o.id ~= f[1] then return end
        o.target = sender
        if not o.heard then
            o.heard = true
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)

    Comm:Register("CA", function(sender, f)
        local id = f[1]
        local o = self.outgoing
        if ns.Live and ns.Live.game and ns.Live.game.id == id then return end -- duplicate after the start
        if not o or o.id ~= id then
            Comm:Send(sender, "CX", id) -- stale accept: tell them it's off
            return
        end
        if tonumber(f[2]) ~= ns.PROTOCOL then
            self.outgoing = nil
            Comm:Send(sender, "CX", id)
            ns.Print(DECLINE_TEXT.version, Names.Display(sender))
            setOutcome(string.format(DECLINE_TEXT.version, Names.Display(sender)))
            ns:Fire("CHALLENGES_CHANGED")
            return
        end
        if o.state == "starting" then return end -- duplicate accept
        o.target = sender -- canonical name from the server
        o.heard = true
        o.opponentVersion = f[3]
        o.state = "starting"
        o.startAt = now() + Challenge.START_DELAY
        Compat.PlaySound("challenge")
        ns.Print("%s accepted! The match starts in a moment.", Names.Display(sender))
        ns:Fire("CHALLENGE_ACCEPTED", o)
        ns:Fire("CHALLENGES_CHANGED")
        C_Timer.After(Challenge.START_DELAY, function()
            if self.outgoing ~= o then return end
            self.outgoing = nil
            ns:Fire("CHALLENGES_CHANGED")
            ns.Live:StartFromChallenge(o, true)
        end)
    end)

    Comm:Register("CD", function(sender, f)
        local o = self.outgoing
        if not o or o.id ~= f[1] then return end
        o.heard = true
        self.outgoing = nil
        local reason = f[2] or "declined"
        local text = string.format(DECLINE_TEXT[reason] or DECLINE_TEXT.declined, Names.Display(sender))
        ns.Print(text)
        setOutcome(text)
        if reason == "version" and f[4] and ns.Presence then ns.Presence:CheckVersion(f[4], sender) end
        if reason == "busy" and ns.Presence then
            local p = ns.Presence:Get(sender)
            ns.Presence:Seen(sender, p and p.version, p and p.proto or ns.PROTOCOL, "busy", p and p.source)
        end
        ns:Fire("CHALLENGES_CHANGED")
    end)

    Comm:Register("CX", function(sender, f)
        local c = self.incoming[f[1]]
        if not c then return end
        if c.state == "accepted" and ns.Live and ns.Live.game and ns.Live.game.id == f[1] then return end
        self.incoming[f[1]] = nil
        if c.state == "accepted" then
            setOutcome(string.format("%s cancelled the challenge before the game started.", Names.Display(c.from)))
        end
        ns:Fire("CHALLENGE_CANCELLED", c)
        ns:Fire("CHALLENGES_CHANGED")
    end)

    ns:On("COMM_TARGET_OFFLINE", function(name)
        local o = self.outgoing
        if o and name and Names.Same(o.target, name) then
            self.outgoing = nil
            local text = string.format("%s is offline.", Names.Display(o.target))
            ns.Print(text)
            setOutcome(text)
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)

    local acc = 0
    ns:SetUpdater("challenge", function(elapsed)
        acc = acc + elapsed
        if acc < 0.5 then return end
        acc = 0
        Challenge:OnUpdate()
    end)
end

return Challenge
