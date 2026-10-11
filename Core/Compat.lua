--[[
    Chess Craft - Core/Compat.lua
    Thin wrappers over client APIs so the rest of the addon does not care
    which build it runs on. Targets WoW: Forever (Mainline family, 12.1.5
    base), where Midnight's addon restrictions apply:
      * chat events can carry "secret" values on restricted maps (dungeons,
        raids) and during encounters, which must never be compared;
      * addon messages can be refused while chat messaging is locked down;
      * trial accounts cannot send addon messages at all.
]]

local ADDON_NAME, ns = ...

local Compat = {}
ns.Compat = Compat

-- clocks: ms = high resolution CPU-ish timer, now = seconds (smooth, survives
-- /reload), server = wall-clock epoch seconds shared by every client.
ns.Clock = {
    ms = debugprofilestop or function() return os.clock() * 1000 end,
    now = GetTime or os.clock,
    server = GetServerTime or os.time,
}

function Compat.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

function Compat.AnySecret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

function Compat.InChatLockdown()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and locked then return true end
    end
    return false
end

function Compat.IsTrial()
    if IsTrialAccount and IsTrialAccount() then return true end
    if IsVeteranTrialAccount and IsVeteranTrialAccount() then return true end
    return false
end

function Compat.InCombat()
    return InCombatLockdown ~= nil and InCombatLockdown() == true
end

function Compat.IsForever()
    if WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then return true end
    local _, _, _, toc = GetBuildInfo()
    return toc and toc >= 16000 and toc < 20000 or false
end

function Compat.RegionalNames()
    return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true
end

-- Sends an addon message, returning a normalized result code:
-- 0 success, 3/8 throttled, 11 lockdown, 12 target offline, anything else = error.
function Compat.SendAddonMessage(prefix, text, chatType, target)
    local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if not send then return 9 end
    local ok, a, b = pcall(send, prefix, text, chatType, target)
    if not ok then return 9 end
    local res = (b ~= nil) and b or a
    if res == nil or res == true then return 0 end
    if res == false then return 9 end
    return res
end

function Compat.RegisterPrefix(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        return C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    elseif RegisterAddonMessagePrefix then
        return RegisterAddonMessagePrefix(prefix)
    end
end

function Compat.SendChat(msg, chatType, target)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if send then return pcall(send, msg, chatType, nil, target) end
end

function Compat.AddChatFilter(event, fn)
    if ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter then
        ChatFrameUtil.AddMessageEventFilter(event, fn)
        return true
    elseif ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter(event, fn)
        return true
    end
    return false
end

-- sounds (named SOUNDKIT keys; silently skipped if a key is missing)
local SOUNDS = {
    move = "U_CHAT_SCROLL_BUTTON",
    capture = "IG_BACKPACK_COIN_SELECT",
    check = "IG_QUEST_LIST_OPEN",
    challenge = "READY_CHECK",
    start = "PVP_THROUGH_QUEUE",
    finish = "IG_MAINMENU_OPEN",
    lowtime = "ALARM_CLOCK_WARNING_3",
    click = "IG_MAINMENU_OPTION_CHECKBOX_ON",
}
function Compat.PlaySound(key)
    if ns.db and ns.db.settings and not ns.db.settings.sound then return end
    local name = SOUNDS[key] or key
    local id = SOUNDKIT and SOUNDKIT[name]
    if id and PlaySound then pcall(PlaySound, id, "SFX") end
end

-- Try texture paths in order (icons differ between clients); first that loads wins.
function Compat.SetTextureFromList(tex, list)
    if type(list) == "string" then list = { list } end
    for _, path in ipairs(list) do
        local ok = tex:SetTexture(path)
        if ok ~= false then return path end
    end
    tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    return nil
end

function Compat.GetMetadata(field)
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMeta and getMeta(ADDON_NAME, field)
end

-- "1.2.10" > "1.2.9"; returns -1, 0, 1
function Compat.CompareVersions(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or "0"):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return -1 elseif x > y then return 1 end
    end
    return 0
end
