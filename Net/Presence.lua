--[[
    Chess Craft - Net/Presence.lua
    Finds other Chess Craft players (guild, group, friends) so the lobby can
    list who is available, and notices newer addon versions so players know
    when to update.

      HI~proto~version~status    broadcast on GUILD / PARTY / RAID
      HR~proto~version~status    whispered reply to HI
      PI~nonce                   direct ping (friends, "does X have the addon?")
      PO~nonce~proto~version~status
]]

local _, ns = ...
local Compat, Comm, Names = ns.Compat, ns.Comm, ns.Names

local Presence = ns:NewModule("Presence")
Presence.players = {}

local ANNOUNCE_INTERVAL = 60
local STATUS_GAP = 10
local FRIEND_PING_INTERVAL = 120
local STALE_AFTER = 15 * 60
local MAX_FRIEND_PINGS = 25

local function now() return ns.Clock.now() end

function Presence:MyStatus()
    if ns.Live and ns.Live:IsActive() then return "busy" end
    return "idle"
end

function Presence:Seen(name, version, proto, status, source)
    local p = self.players[name]
    if not p then p = {}; self.players[name] = p end
    p.version, p.proto, p.status = version, tonumber(proto), status or "idle"
    p.seen = now()
    p.source = source or p.source
    self:CheckVersion(version, name)
    ns:Fire("PRESENCE_CHANGED", name)
    return p
end

function Presence:CheckVersion(version, from)
    if not version or version == "" then return end
    if Compat.CompareVersions(version, ns.version) <= 0 then return end
    local g = ns.db.global
    if not g.newestVersionSeen or Compat.CompareVersions(version, g.newestVersionSeen) > 0 then
        g.newestVersionSeen = version
    end
    if not self.notifiedNewer or Compat.CompareVersions(version, self.notifiedNewer) > 0 then
        self.notifiedNewer = version
        ns.Print("A newer version of Chess Craft is out (%s; you have %s). Update to keep playing friends on the latest version.",
            version, ns.version)
        ns:Fire("NEWER_VERSION", version)
    end
end

-- Players seen recently, sorted: available first, then by name.
function Presence:List()
    local out, t = {}, now()
    for name, p in pairs(self.players) do
        if t - (p.seen or 0) < STALE_AFTER then
            out[#out + 1] = { name = name, status = p.status, version = p.version, proto = p.proto,
                              source = p.source, seen = p.seen }
        end
    end
    table.sort(out, function(a, b)
        if (a.status == "idle") ~= (b.status == "idle") then return a.status == "idle" end
        return a.name < b.name
    end)
    return out
end

function Presence:Get(name)
    for n, p in pairs(self.players) do
        if Names.Same(n, name) then return p, n end
    end
end

-- Broadcast our presence. Unforced calls are rate limited, but a change of
-- status (idle <-> busy) goes out within STATUS_GAP seconds.
function Presence:Announce(force)
    if Compat.IsTrial() then return end
    local t = now()
    local status = self:MyStatus()
    if not force and self.lastAnnounce then
        local gap = (status ~= self.lastStatus) and STATUS_GAP or ANNOUNCE_INTERVAL
        local wait = gap - (t - self.lastAnnounce)
        if wait > 0 then
            if status ~= self.lastStatus and not self.announceQueued then
                self.announceQueued = true
                C_Timer.After(wait + 0.1, function()
                    self.announceQueued = false
                    self:Announce(false)
                end)
            end
            return
        end
    end
    self.lastAnnounce = t
    self.lastStatus = status
    if IsInGuild and IsInGuild() then
        Comm:Broadcast("GUILD", "HI", ns.PROTOCOL, ns.version, status)
    end
    -- home groups only: instance chat is locked down on restricted maps
    local home = LE_PARTY_CATEGORY_HOME
    if IsInRaid and IsInRaid(home) then
        Comm:Broadcast("RAID", "HI", ns.PROTOCOL, ns.version, status)
    elseif IsInGroup and IsInGroup(home) then
        Comm:Broadcast("PARTY", "HI", ns.PROTOCOL, ns.version, status)
    end
end

function Presence:PingFriends(force)
    if Compat.IsTrial() or not C_FriendList then return end
    local t = now()
    if not force and self.lastFriendPing and t - self.lastFriendPing < FRIEND_PING_INTERVAL then return end
    self.lastFriendPing = t
    local sent = 0
    local n = C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0
    for i = 1, n do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.name and sent < MAX_FRIEND_PINGS then
            Comm:Send(info.name, "PI", "f")
            sent = sent + 1
        end
    end
end

-- Ask one player whether they have the addon; callback(found, info) within 6s.
local pendingPings = {}
function Presence:Ping(name, callback)
    local nonce = tostring(math.random(100000, 999999))
    pendingPings[nonce] = { name = name, callback = callback }
    Comm:Send(name, "PI", nonce)
    C_Timer.After(6, function()
        local p = pendingPings[nonce]
        if p then
            pendingPings[nonce] = nil
            if p.callback then p.callback(false) end
        end
    end)
end

-- Is this player someone we know (friend, guildmate, group member)?
function Presence.IsKnown(name)
    if C_FriendList and C_FriendList.GetFriendInfo then
        local info = C_FriendList.GetFriendInfo(name) or C_FriendList.GetFriendInfo(Names.Base(name))
        if info then return true end
    end
    if UnitInParty and (UnitInParty(name) or UnitInParty(Names.Base(name))) then return true end
    if UnitInRaid and (UnitInRaid(name) or UnitInRaid(Names.Base(name))) then return true end
    if IsGuildMember and (IsGuildMember(name) or IsGuildMember(Names.Base(name))) then return true end
    local p = Presence.players[name]
    if p and p.source == "guild" then return true end
    return false
end

function Presence:OnEnable()
    Comm:Register("HI", function(sender, f, channel)
        local source = (channel == "GUILD") and "guild" or "group"
        self:Seen(sender, f[2], f[1], f[3], source)
        -- answer each announcer at most every 30s
        local p = self.players[sender]
        if not p.repliedAt or now() - p.repliedAt > 30 then
            p.repliedAt = now()
            Comm:Send(sender, "HR", ns.PROTOCOL, ns.version, self:MyStatus())
        end
    end)
    Comm:Register("HR", function(sender, f)
        local p = self.players[sender]
        self:Seen(sender, f[2], f[1], f[3], p and p.source or "reply")
    end)
    Comm:Register("PI", function(sender, f)
        Comm:Send(sender, "PO", f[1] or "", ns.PROTOCOL, ns.version, self:MyStatus())
    end)
    Comm:Register("PO", function(sender, f)
        local nonce = f[1]
        local source = (nonce == "f") and "friend" or "direct"
        local p = self:Seen(sender, f[3], f[2], f[4], source)
        local pending = pendingPings[nonce]
        if pending then
            pendingPings[nonce] = nil
            if pending.callback then pending.callback(true, p, sender) end
        end
    end)

    C_Timer.After(12, function() self:Announce(true) end)
    local lastGroupAnnounce = 0
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if now() - lastGroupAnnounce > 30 then
            lastGroupAnnounce = now()
            C_Timer.After(3, function() self:Announce(true) end)
        end
    end)
    ns:On("LIVE_STATE_CHANGED", function()
        -- let guildmates know when we become busy/free (rate limited)
        self:Announce(false)
    end)
end

return Presence
