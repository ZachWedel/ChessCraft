--[[
    Chess Craft - Net/Comm.lua
    Addon-message transport. Messages are "TYPE~field~field..." on the
    "ChessCraft" prefix (whispers between players, plus small presence
    broadcasts on guild/party).

    Midnight-era rules handled here (they apply to WoW: Forever):
      * incoming chat payloads can be secret values (dungeons, raids,
        encounters): they are dropped before any comparison;
      * SendAddonMessage can report AddOnMessageLockdown: messages wait in
        the queue and go out when the lockdown lifts;
      * throttle results are retried; TargetOffline is reported upward.
]]

local _, ns = ...
local Compat = ns.Compat

local Comm = ns:NewModule("Comm")
Comm.PREFIX = "ChessCraft"
Comm.SEP = "~"

local SEP = Comm.SEP
local MAX_AGE = 90            -- seconds a queued message may wait before being dropped
local handlers = {}
local queue = {}
local recentWhispers = {}     -- lowercased target -> time of last send

Comm.locked = false

local function now() return ns.Clock.now() end

function Comm:Register(msgType, fn)
    handlers[msgType] = fn
end

function Comm.Encode(msgType, ...)
    local parts = { msgType }
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v == nil then v = "" end
        v = tostring(v)
        if v:find(SEP, 1, true) then v = v:gsub(SEP, "-") end
        parts[#parts + 1] = v
    end
    return table.concat(parts, SEP)
end

function Comm.Decode(text)
    local fields = { strsplit(SEP, text) }
    local msgType = table.remove(fields, 1)
    return msgType, fields
end

function Comm:CanSend()
    if Compat.IsTrial() then return false, "trial" end
    return true
end

-- Whisper a message to one player.
function Comm:Send(target, msgType, ...)
    if not target or target == "" then return false end
    return self:Enqueue("WHISPER", target, Comm.Encode(msgType, ...))
end

-- Broadcast to "GUILD", "PARTY" or "RAID".
function Comm:Broadcast(channel, msgType, ...)
    return self:Enqueue(channel, nil, Comm.Encode(msgType, ...))
end

function Comm:Enqueue(channel, target, text)
    if #text > 255 then
        ns.Debug("message too long (%d): %s", #text, text:sub(1, 40))
        return false
    end
    queue[#queue + 1] = { channel = channel, target = target, text = text, added = now(), notBefore = 0 }
    self:Flush()
    return true
end

function Comm:SetLocked(locked)
    if self.locked == locked then return end
    self.locked = locked
    ns:Fire("COMM_LOCKDOWN", locked)
end

function Comm:Flush()
    local t = now()
    local i = 1
    while i <= #queue do
        local item = queue[i]
        if t - item.added > MAX_AGE then
            table.remove(queue, i)
            ns:Fire("COMM_SEND_FAILED", item.target, "expired")
        elseif item.notBefore > t then
            i = i + 1
        else
            local res = Compat.SendAddonMessage(self.PREFIX, item.text, item.channel, item.target)
            if res == 0 then
                if item.target then recentWhispers[item.target:lower()] = t end
                table.remove(queue, i)
                if self.locked then self:SetLocked(false) end
            elseif res == 3 or res == 8 then        -- throttled: try again shortly
                item.notBefore = t + 1
                i = i + 1
            elseif res == 11 then                   -- chat messaging lockdown
                item.notBefore = t + 2
                self:SetLocked(true)
                i = i + 1
            elseif res == 12 then                   -- target offline
                table.remove(queue, i)
                ns:Fire("COMM_TARGET_OFFLINE", item.target)
            else
                table.remove(queue, i)
                ns.Debug("addon message failed (code %s) on %s", tostring(res), item.channel)
                ns:Fire("COMM_SEND_FAILED", item.target, res)
            end
        end
    end
end

function Comm:QueueSize() return #queue end

-- incoming ---------------------------------------------------------------------------
local function onAddonMessage(_, prefix, text, channel, sender)
    -- secret values (restricted maps/encounters) must not even be compared
    if Compat.AnySecret(prefix, text, channel, sender) then return end
    if prefix ~= Comm.PREFIX or type(text) ~= "string" or type(sender) ~= "string" then return end
    if channel ~= "WHISPER" and ns.Names.IsMe(sender) then return end
    local msgType, fields = Comm.Decode(text)
    local h = msgType and handlers[msgType]
    if h then h(sender, fields, channel) end
end

-- "No player named 'X' is currently playing." -> hide it for players we just
-- whispered over the addon channel, and tell the game logic they're offline.
local function formatToPattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end

local notFoundPattern
local function systemFilter(_, _, msg, ...)
    if type(msg) ~= "string" or Compat.IsSecret(msg) or not notFoundPattern then return false end
    local name = msg:match(notFoundPattern)
    if not name then return false end
    local t = recentWhispers[name:lower()]
    if t and now() - t < 10 then
        ns:Fire("COMM_TARGET_OFFLINE", name)
        return true
    end
    return false
end

function Comm:OnInitialize()
    Compat.RegisterPrefix(self.PREFIX)
end

function Comm:OnEnable()
    ns:RegisterEvent("CHAT_MSG_ADDON", onAddonMessage)
    if ERR_CHAT_PLAYER_NOT_FOUND_S then
        notFoundPattern = formatToPattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
        Compat.AddChatFilter("CHAT_MSG_SYSTEM", systemFilter)
    end
    ns:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", function()
        if not Compat.InChatLockdown() and self.locked then
            self:SetLocked(false)
            self:Flush()
        end
    end)
    local acc = 0
    ns:SetUpdater("comm", function(elapsed)
        acc = acc + elapsed
        if acc < 0.25 then return end
        acc = 0
        if #queue > 0 then Comm:Flush() end
        if Comm.locked and #queue == 0 and not Compat.InChatLockdown() then Comm:SetLocked(false) end
    end)
end

-- test hook
Comm._formatToPattern = formatToPattern
Comm._onAddonMessage = onAddonMessage

return Comm
