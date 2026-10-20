--[[
    Chess Craft - Net/Presence.lua
    Finds other Chess Craft players (guild, group, friends) so the lobby can
    list who is available, and notices newer addon versions so players know
    when to update.

      HI~proto~version~status    broadcast on GUILD / PARTY / RAID
      HR~proto~version~status    whispered reply to HI
      PI~nonce                   direct ping (friends, "does X have the addon?")
      PO~nonce~proto~version~status
      ST~proto~version~status    status change (idle <-> busy), whispered to every listed player

    Only players whose addon has answered appear in the list. A reply to a
    friends-list ping only counts when it comes from someone on our friends
    list (a first-name-only whisper could reach a stranger).
]]

local _, ns = ...
local Compat, Comm, Names = ns.Compat, ns.Comm, ns.Names

local Presence = ns:NewModule("Presence")
Presence.players = {}

local ANNOUNCE_INTERVAL = 60
local STATUS_GAP = 10
local FRIEND_PING_INTERVAL = 120
local STALE_AFTER = 15 * 60
local MAX_FRIEND_PINGS = 40
local RECHECK_GAP = 5
local RECHECK_WINDOW = 8

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

-- Whisper targets for every friend who is online in this game: character
-- friends and Battle.net friends playing WoW: Forever. Names are turned into
-- whisper form ("First Surname" -> "First-Surname"); a Battle.net friend also
-- gets a "Name-Realm" candidate, since the two lists format names differently.
function Presence:OnlineFriendTargets()
    local targets, seen = {}, {}
    local function add(name)
        if not name or name == "" or Compat.IsSecret(name) then return end
        local target = Names.Normalize(name)
        if target and not seen[target:lower()] and not Names.IsMe(target) then
            seen[target:lower()] = true
            targets[#targets + 1] = target
        end
    end
    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, C_FriendList.GetNumFriends() or 0 do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.connected then add(info.name) end
        end
    end
    if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
        local myProject = WOW_PROJECT_ID
        for i = 1, (BNGetNumFriends()) or 0 do
            for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
                local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if g and g.isOnline and g.clientProgram == (BNET_CLIENT_WOW or "WoW")
                    and (not myProject or not g.wowProjectID or g.wowProjectID == myProject)
                    and g.isInCurrentRegion ~= false and g.characterName then
                    add(g.characterName)
                    local realm = g.realmName
                    if realm and realm ~= "" and not Compat.IsSecret(realm) and not g.characterName:find("-", 1, true) then
                        add(g.characterName .. "-" .. realm:gsub("%s+", ""))
                    end
                end
            end
        end
    end
    return targets
end

-- force: ask every online friend; otherwise only friends not asked lately
-- (e.g. someone who just logged in).
function Presence:PingFriends(force)
    if Compat.IsTrial() then return end
    local t = now()
    self.friendPinged = self.friendPinged or {}
    local targets = self:OnlineFriendTargets()
    -- forget friends who went offline, so they are asked again when they return
    local online = {}
    for _, target in ipairs(targets) do online[target:lower()] = true end
    for key in pairs(self.friendPinged) do
        if not online[key] then self.friendPinged[key] = nil end
    end
    local sent = 0
    for _, target in ipairs(targets) do
        if sent >= MAX_FRIEND_PINGS then break end
        local last = self.friendPinged[target:lower()]
        if force or not last or t - last >= FRIEND_PING_INTERVAL then
            self.friendPinged[target:lower()] = t
            Comm:Send(target, "PI", "f")
            sent = sent + 1
        end
    end
end

-- The "double check" run each time the window opens: ask the guild, group
-- and every online friend who has Chess Craft, re-confirm everyone already
-- listed, and drop listed players who don't answer within RECHECK_WINDOW.
function Presence:Recheck()
    if Compat.IsTrial() then return end
    local t = now()
    if self.recheckStarted and t - self.recheckStarted < RECHECK_GAP then return end
    self.recheckStarted = t
    self.checking = true
    if C_FriendList and C_FriendList.ShowFriends then pcall(C_FriendList.ShowFriends) end
    self:Announce(true)
    self:PingFriends(true)
    for name, p in pairs(self.players) do
        if t - (p.seen or 0) < STALE_AFTER then Comm:Send(name, "PI", "v") end
    end
    ns:Fire("PRESENCE_CHANGED")
    C_Timer.After(RECHECK_WINDOW, function()
        if self.recheckStarted ~= t then return end
        self.checking = false
        for name, p in pairs(self.players) do
            if (p.seen or 0) < t then self.players[name] = nil end -- no answer: gone
        end
        ns:Fire("PRESENCE_CHANGED")
    end)
end

function Presence:IsChecking() return self.checking == true end

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

-- Is this player one of our (character or Battle.net) friends?
function Presence:IsFriend(name)
    if C_FriendList and C_FriendList.GetFriendInfo then
        local info = C_FriendList.GetFriendInfo(name) or C_FriendList.GetFriendInfo(Names.Base(name))
        if info then return true end
    end
    for _, target in ipairs(self:OnlineFriendTargets()) do
        if Names.Same(target, name) then return true end
    end
    return false
end

-- Is this player busy in a match (as far as we know)?
function Presence:IsBusy(name)
    local p = self:Get(name)
    return p ~= nil and p.status == "busy" and now() - (p.seen or 0) < STALE_AFTER
end

-- Is this player someone we know (friend, guildmate, group member)?
function Presence.IsKnown(name)
    if C_FriendList and C_FriendList.GetFriendInfo then
        local info = C_FriendList.GetFriendInfo(name) or C_FriendList.GetFriendInfo(Names.Base(name))
        if info then return true end
    end
    for _, target in ipairs(Presence:OnlineFriendTargets()) do
        if Names.Same(target, name) then return true end
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
    Comm:Register("ST", function(sender, f)
        local p = self.players[sender]
        if p then self:Seen(sender, f[2], f[1], f[3], p.source) end
    end)
    Comm:Register("PO", function(sender, f)
        local nonce = f[1]
        local known = self.players[sender]
        if nonce == "f" and not known and not self:IsFriend(sender) then return end
        local source = (nonce == "f") and "friend" or (nonce == "v" and known and known.source) or "direct"
        local p = self:Seen(sender, f[3], f[2], f[4], source)
        local pending = pendingPings[nonce]
        if pending then
            pendingPings[nonce] = nil
            if pending.callback then pending.callback(true, p, sender) end
        end
    end)

    C_Timer.After(12, function()
        self:Announce(true)
        self:PingFriends(true)
    end)
    -- friends coming online (or the friends list finishing loading)
    local friendCheckQueued = false
    local function friendsChanged()
        if friendCheckQueued then return end
        friendCheckQueued = true
        C_Timer.After(3, function()
            friendCheckQueued = false
            self:PingFriends(false)
        end)
    end
    ns:RegisterEvent("FRIENDLIST_UPDATE", friendsChanged)
    ns:RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE", friendsChanged)
    ns:RegisterEvent("BN_FRIEND_INFO_CHANGED", friendsChanged)
    local lastGroupAnnounce = 0
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if now() - lastGroupAnnounce > 30 then
            lastGroupAnnounce = now()
            C_Timer.After(3, function() self:Announce(true) end)
        end
    end)
    ns:On("LIVE_STATE_CHANGED", function()
        -- tell everyone who lists us that we are now busy / free again
        local status = self:MyStatus()
        if status ~= self.lastPushed then
            self.lastPushed = status
            for name in pairs(self.players) do
                Comm:Send(name, "ST", ns.PROTOCOL, ns.version, status)
            end
        end
        self:Announce(false)
    end)
end

return Presence
