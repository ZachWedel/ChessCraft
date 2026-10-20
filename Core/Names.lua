--[[
    Chess Craft - Core/Names.lua
    Player names. Retail formats full names as "Name-Realm"; WoW: Forever
    uses regionally unique first + last names on mega-realms. Rather than
    guessing the exact format, Chess Craft treats the sender string the
    server puts on addon messages as the canonical id for a player, learns
    its own id by whispering itself at login, and matches loosely (case,
    missing suffix) when a name was typed by hand.
]]

local _, ns = ...
local Compat = ns.Compat

local Names = ns:NewModule("Names")

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Name as returned for a unit, joined in link/whisper form ("A-B").
function Names.FromUnit(unit)
    if not UnitExists or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local getName = UnitNameUnmodified or UnitName
    local name, second = getName(unit)
    if Compat.AnySecret(name, second) or not name or name == "" then return nil end
    if second and second ~= "" then return name .. "-" .. second end
    return name
end

-- Best guess of our own canonical name until the self-whisper confirms it.
function Names.Me()
    if Names.self then return Names.self end
    local name, second = UnitFullName("player")
    if not name or Compat.AnySecret(name, second) then return UnitName("player") end
    if second and second ~= "" then return name .. "-" .. second end
    if not Compat.RegionalNames() and GetNormalizedRealmName then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then return name .. "-" .. realm end
    end
    return name
end

function Names.Base(name)
    return name and name:match("^[^-]+") or name
end

-- Loose equality: exact, case-insensitive, or one side missing its suffix.
function Names.Same(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local la, lb = a:lower(), b:lower()
    if la == lb then return true end
    la, lb = la:gsub("%s+", "-"), lb:gsub("%s+", "-")
    if la == lb then return true end
    if not la:find("-", 1, true) or not lb:find("-", 1, true) then
        return Names.Base(la) == Names.Base(lb)
    end
    -- one side carries an extra suffix ("first-last" vs "first-last-realm")
    if la:sub(1, #lb + 1) == lb .. "-" or lb:sub(1, #la + 1) == la .. "-" then return true end
    return false
end

function Names.IsMe(name)
    if not name then return false end
    if Names.self then return Names.self == name or Names.self:lower() == name:lower() end
    return Names.Same(name, Names.Me()) or Names.Same(name, UnitName("player"))
end

-- Turn user input into a whisper target ("john smith" -> "john-smith" on Forever).
function Names.Normalize(input)
    if type(input) ~= "string" then return nil end
    local s = trim(input)
    if s == "" then return nil end
    if s:lower() == "%t" or s:lower() == "target" then return Names.FromUnit("target") end
    if Compat.RegionalNames() then s = s:gsub("%s+", "-") end
    return s
end

-- How a name is shown in the UI.
function Names.Display(name)
    if not name then return "?" end
    if Compat.RegionalNames() then return (name:gsub("%-", " ")) end
    if Ambiguate then return Ambiguate(name, "none") end
    return name
end

function Names:OnEnable()
    -- Learn our own canonical sender name by whispering ourselves once.
    local nonce = tostring(math.random(100000, 999999))
    ns.Comm:Register("ME", function(sender, fields)
        if fields[1] == nonce and not Names.self then
            Names.self = sender
            ns.Debug("own name resolved as %s", sender)
            ns:Fire("SELF_NAME_RESOLVED", sender)
        end
    end, true)
    C_Timer.After(2, function()
        ns.Comm:Send(UnitName("player"), "ME", nonce)
    end)
end
