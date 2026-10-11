--[[
    Chess Craft - Core/Init.lua
    Addon namespace, module lifecycle, event dispatch, internal callbacks,
    per-frame updaters, slash commands and the small public API.
]]

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.TITLE = "Chess Craft"
-- Bump PROTOCOL whenever the addon-message format changes incompatibly.
ns.PROTOCOL = 1
ns.version = "0.1.0"

do
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if getMeta then
        local v = getMeta(ADDON_NAME, "Version")
        if v and v ~= "" and not v:find("@") then ns.version = v end
    end
end

-- modules ---------------------------------------------------------------------
ns.modules = {}
function ns:NewModule(name)
    local m = { moduleName = name }
    ns[name] = m
    ns.modules[#ns.modules + 1] = m
    return m
end

local function safecall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) else print(err) end
    end
    return ok
end
ns.safecall = safecall

-- WoW events ----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "ChessCraftEventFrame")
ns.eventFrame = eventFrame
local eventHandlers = {}

function ns:RegisterEvent(event, handler)
    local list = eventHandlers[event]
    if not list then
        -- unknown events raise an error, so probe safely (events differ per client)
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return false end
        list = {}
        eventHandlers[event] = list
    end
    list[#list + 1] = handler
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then return end
    for i = 1, #list do safecall(list[i], event, ...) end
end)

-- internal callbacks (UI listens to game logic through these) ----------------------
local callbacks = {}
function ns:On(message, fn)
    local list = callbacks[message]
    if not list then list = {}; callbacks[message] = list end
    list[#list + 1] = fn
end

function ns:Fire(message, ...)
    local list = callbacks[message]
    if not list then return end
    for i = 1, #list do safecall(list[i], ...) end
end

-- per-frame updaters ---------------------------------------------------------------
local updaters, updaterKeys, updatersDirty = {}, {}, false
function ns:SetUpdater(key, fn)
    updaters[key] = fn
    updatersDirty = true
end

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if updatersDirty then
        wipe(updaterKeys)
        for k in pairs(updaters) do updaterKeys[#updaterKeys + 1] = k end
        updatersDirty = false
    end
    for i = 1, #updaterKeys do
        local fn = updaters[updaterKeys[i]]
        if fn then safecall(fn, elapsed) end
    end
end)

-- printing ----------------------------------------------------------------------------
local PREFIX = "|cff6fbf73Chess Craft|r: "
function ns.Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    local frame = DEFAULT_CHAT_FRAME or ChatFrame1
    if frame then frame:AddMessage(PREFIX .. msg) else print(PREFIX .. msg) end
end

function ns.Debug(msg, ...)
    if not (ns.db and ns.db.settings and ns.db.settings.debug) then return end
    if select("#", ...) > 0 then msg = msg:format(...) end
    ns.Print("|cff888888[debug]|r " .. msg)
end

-- unique ids (game ids travel in addon messages, so keep them short) -----------------
local idCounter = 0
function ns.NewId()
    idCounter = (idCounter + 1) % 1296
    local t = (GetServerTime and GetServerTime() or os.time()) % 2176782336
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local function b36(v, width)
        local s = ""
        for _ = 1, width do
            local d = v % 36
            s = digits:sub(d + 1, d + 1) .. s
            v = math.floor(v / 36)
        end
        return s
    end
    return b36(t, 6) .. b36(idCounter, 2) .. b36(math.random(0, 1295), 2)
end

-- lifecycle ---------------------------------------------------------------------------
ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON_NAME then return end
    for _, m in ipairs(ns.modules) do
        if m.OnInitialize then safecall(m.OnInitialize, m) end
    end
    ns.initialized = true
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    for _, m in ipairs(ns.modules) do
        if m.OnEnable then safecall(m.OnEnable, m) end
    end
    ns.enabled = true
    ns:Fire("ENABLED")
end)

ns:RegisterEvent("PLAYER_LOGOUT", function()
    ns:Fire("LOGOUT")
end)

-- slash commands ----------------------------------------------------------------------
local function help()
    ns.Print("v%s commands:", ns.version)
    print("  /chess - open or close the board")
    print("  /chess bot [1-8] - start a game against a bot")
    print("  /chess resume - resume your most recent bot game")
    print("  /chess challenge <name> [minutes+increment|infinite] - challenge a player")
    print("  /chess options - settings")
    print("  /chess version - show version information")
end

local function slash(input)
    input = input and input:match("^%s*(.-)%s*$") or ""
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        if ns.UI and ns.UI.Toggle then ns.UI:Toggle() end
    elseif cmd == "help" or cmd == "?" then
        help()
    elseif cmd == "bot" then
        local level = tonumber(rest) or 3
        if ns.BotGame then ns.BotGame:StartNew(level, "random") end
    elseif cmd == "resume" then
        if ns.BotGame then ns.BotGame:ResumeLatest() end
    elseif cmd == "challenge" or cmd == "duel" then
        local name, tc = rest:match("^(%S+)%s*(.-)$")
        if not name then
            ns.Print("Usage: /chess challenge <name> [5+3|infinite]")
        elseif ns.Challenge then
            ns.Challenge:SendTo(name, ns.Challenge.ParseTimeControl(tc), "random")
        end
    elseif cmd == "options" or cmd == "settings" or cmd == "config" then
        if ns.UI and ns.UI.ShowTab then ns.UI:Show(); ns.UI:ShowTab("settings") end
    elseif cmd == "version" then
        ns.Print("version %s, protocol %d%s", ns.version, ns.PROTOCOL,
            (ns.db and ns.db.global.newestVersionSeen) and (", newest seen: " .. ns.db.global.newestVersionSeen) or "")
    elseif cmd == "debug" then
        if ns.db then
            ns.db.settings.debug = not ns.db.settings.debug
            ns.Print("debug %s", ns.db.settings.debug and "on" or "off")
        end
    else
        help()
    end
end

SLASH_CHESSCRAFT1 = "/chess"
SLASH_CHESSCRAFT2 = "/chesscraft"
SlashCmdList.CHESSCRAFT = slash
ns.HandleSlash = slash

-- public API + addon compartment hooks -----------------------------------------------
ChessCraft = {
    version = function() return ns.version end,
    Toggle = function() if ns.UI then ns.UI:Toggle() end end,
}

function ChessCraft_OnAddonCompartmentClick(_, buttonName)
    if not ns.UI then return end
    if buttonName == "RightButton" then
        ns.UI:Show(); ns.UI:ShowTab("settings")
    else
        ns.UI:Toggle()
    end
end

function ChessCraft_OnAddonCompartmentEnter(_, frame)
    if ns.UI and ns.UI.ShowSummaryTooltip then ns.UI:ShowSummaryTooltip(frame) end
end

function ChessCraft_OnAddonCompartmentLeave()
    if GameTooltip then GameTooltip:Hide() end
end
