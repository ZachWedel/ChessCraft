--[[
    Chess Craft - Net/Challenge.lua
    Challenging another player, Peggle-duel style.

      CH~id~proto~version~yourColor(w|b)~tc      challenger -> target
      CA~id~proto~version                         target accepts
      CD~id~reason[~proto~version]                target declines (declined|busy|version|nobody)
      CX~id                                       challenger cancels / challenge no longer valid
    After CA the challenger starts the game and sends GS (see Net/Live.lua).
]]

local _, ns = ...
local Compat, Comm, Names = ns.Compat, ns.Comm, ns.Names

local Challenge = ns:NewModule("Challenge")
Challenge.outgoing = nil
Challenge.incoming = {}

local CHALLENGE_TIMEOUT = 60
local NO_ANSWER_HINT = 12
local START_TIMEOUT = 20

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

-- outgoing -----------------------------------------------------------------------------
local function colorName(c) return c == 1 and "White" or "Black" end

function Challenge:CanChallenge()
    if Compat.IsTrial() then
        return false, "Trial accounts can't send addon messages, so live games aren't available. You can still play the bots."
    end
    if ns.Live and ns.Live:IsActive() then return false, "Finish or leave your current live game first." end
    return true
end

-- tc: table (timed) or false/nil (infinite). colorPref: "white" | "black" | "random"
function Challenge:SendTo(name, tc, colorPref)
    local ok, why = self:CanChallenge()
    if not ok then ns.Print(why); return false end
    if tc == nil then tc = false end
    local target = Names.Normalize(name)
    if not target then ns.Print("Enter a player name (or target someone first)."); return false end
    if Names.IsMe(target) then ns.Print("You can't challenge yourself."); return false end
    if self.outgoing then self:Cancel(true) end

    local myColor
    if colorPref == "white" then myColor = 1 elseif colorPref == "black" then myColor = 2 else myColor = math.random(1, 2) end
    local id = ns.NewId()
    local o = { id = id, target = target, tc = tc or nil, myColor = myColor, sentAt = ns.Clock.now(), state = "pending" }
    self.outgoing = o
    Comm:Send(target, "CH", id, ns.PROTOCOL, ns.version, (myColor == 1) and "b" or "w", Challenge.TimeControlToWire(o.tc))
    ns.db.char.lastColor = colorPref or "random"
    ns.Print("Challenge sent to %s: %s, you play %s.", Names.Display(target), Challenge.Describe(o.tc), colorName(myColor))
    ns:Fire("CHALLENGES_CHANGED")

    C_Timer.After(NO_ANSWER_HINT, function()
        if self.outgoing == o and o.state == "pending" and not o.heard then
            ns.Print("No answer from %s yet. They may be away, offline, or not have Chess Craft installed.", Names.Display(target))
        end
    end)
    C_Timer.After(CHALLENGE_TIMEOUT, function()
        if self.outgoing == o and o.state == "pending" then
            self.outgoing = nil
            ns.Print("Your challenge to %s expired.", Names.Display(target))
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
    if not silent then ns.Print("Challenge to %s cancelled.", Names.Display(o.target)) end
    ns:Fire("CHALLENGES_CHANGED")
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
    c.state = "accepted"
    c.acceptedAt = ns.Clock.now()
    Comm:Send(c.from, "CA", id, ns.PROTOCOL, ns.version)
    ns:Fire("CHALLENGES_CHANGED")
    C_Timer.After(START_TIMEOUT, function()
        if self.incoming[id] == c and c.state == "accepted" then
            self.incoming[id] = nil
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
    if c and c.state == "accepted" and Names.Same(c.from, sender) then
        self.incoming[id] = nil
        ns:Fire("CHALLENGES_CHANGED")
        return c
    end
    return nil
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
            ns.Print("%s challenged you, but uses Chess Craft %s (incompatible with your %s). One of you needs to update.",
                Names.Display(sender), tostring(version), ns.version)
            return
        end
        if self.incoming[id] then return end
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
                    version = version, receivedAt = ns.Clock.now(), state = "pending" }
        self.incoming[id] = c
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

    Comm:Register("CA", function(sender, f)
        local id = f[1]
        local o = self.outgoing
        if not o or o.id ~= id or not Names.Same(o.target, sender) then
            Comm:Send(sender, "CX", id) -- stale accept: tell them it's off
            return
        end
        if tonumber(f[2]) ~= ns.PROTOCOL then
            self.outgoing = nil
            Comm:Send(sender, "CX", id)
            ns.Print(DECLINE_TEXT.version, Names.Display(sender))
            ns:Fire("CHALLENGES_CHANGED")
            return
        end
        self.outgoing = nil
        o.target = sender -- canonical name from the server
        o.opponentVersion = f[3]
        ns:Fire("CHALLENGES_CHANGED")
        ns.Live:StartFromChallenge(o, true)
    end)

    Comm:Register("CD", function(sender, f)
        local o = self.outgoing
        if not o or o.id ~= f[1] then return end
        o.heard = true
        self.outgoing = nil
        local reason = f[2] or "declined"
        ns.Print(DECLINE_TEXT[reason] or DECLINE_TEXT.declined, Names.Display(sender))
        if reason == "version" and f[4] and ns.Presence then ns.Presence:CheckVersion(f[4], sender) end
        ns:Fire("CHALLENGES_CHANGED")
    end)

    Comm:Register("CX", function(sender, f)
        local c = self.incoming[f[1]]
        if c and Names.Same(c.from, sender) then
            self.incoming[f[1]] = nil
            ns:Fire("CHALLENGE_CANCELLED", c)
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)

    ns:On("COMM_TARGET_OFFLINE", function(name)
        local o = self.outgoing
        if o and name and Names.Same(o.target, name) then
            self.outgoing = nil
            ns.Print("%s is offline.", Names.Display(o.target))
            ns:Fire("CHALLENGES_CHANGED")
        end
    end)
end

return Challenge
