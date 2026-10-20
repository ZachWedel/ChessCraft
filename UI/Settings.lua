--[[
    Chess Craft - UI/Settings.lua
    Settings, built from one description and shown twice: on the window's
    Settings tab and in the game's Options > AddOns panel.
]]

local _, ns = ...
local Theme, W = ns.Theme, ns.Widgets
local C = Theme.COLORS

local SettingsUI = {}
ns.SettingsUI = SettingsUI

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.7, 1.4, 0.05

local function get(key) return ns.db.settings[key] end
local function set(key, value) ns.Database.Set(key, value) end

local SECTIONS = {
    {
        title = "Board",
        items = {
            { kind = "segmented", key = "theme", label = "Pieces and board", width = 134, options = {
                { value = "classic", label = "Classic", tip = "Staunton pieces on a wood, tournament green or slate board." },
                { value = "faction", label = "Alliance vs Horde", tip = "Blue Alliance pieces face crimson Horde pieces on a stone board." },
            } },
            { kind = "segmented", key = "boardStyle", label = "Classic board", width = 88, options = {
                { value = "wood", label = "Wood" },
                { value = "green", label = "Tournament" },
                { value = "slate", label = "Slate" },
            }, enabled = function() return get("theme") ~= "faction" end },
            { kind = "check", key = "showCoordinates", label = "Show coordinates" },
            { kind = "check", key = "highlightLastMove", label = "Highlight the last move" },
            { kind = "check", key = "showLegalMoves", label = "Show where the selected piece can go" },
            { kind = "check", key = "animateMoves", label = "Animate moves" },
            { kind = "check", key = "botPieces", label = "Bots play with their own pieces",
              tip = "Each bot has a piece set of its own: candle wax for the Kobold, brass for the Tinker, arcane marble for the Archmage and so on." },
            { kind = "check", key = "autoFlip", label = "Show the board from my side",
              tip = "When you play Black, Black is at the bottom. The Flip button turns the board either way." },
            { kind = "scale", key = "scale", label = "Window size" },
        },
    },
    {
        title = "Playing",
        items = {
            { kind = "check", key = "autoQueen", label = "Always promote to a queen" },
            { kind = "check", key = "confirmResign", label = "Ask before resigning or leaving" },
            { kind = "check", key = "sound", label = "Sound effects" },
            { kind = "check", key = "showQuips", label = "Bot chatter" },
            { kind = "check", key = "pauseBotInCombat", label = "Pause bots while I'm in combat" },
            { kind = "segmented", key = "botSpeed", label = "Bot thinking", width = 88, options = {
                { value = "smooth", label = "Smooth", tip = "Uses the least time per frame; bots take a little longer to answer." },
                { value = "balanced", label = "Balanced", tip = "A good mix of frame rate and answer speed." },
                { value = "fast", label = "Fast", tip = "Bots answer sooner but use more time each frame." },
            } },
        },
    },
    {
        title = "Challenges",
        items = {
            { kind = "segmented", key = "acceptFrom", label = "Accept challenges from", width = 88, options = {
                { value = "everyone", label = "Everyone" },
                { value = "friends", label = "Friends", tip = "Friends, guildmates and group members only." },
                { value = "nobody", label = "Nobody", tip = "Challenges are declined automatically." },
            } },
            { kind = "segmented", key = "allowSpectators", label = "Who can watch my games", width = 88, options = {
                { value = "everyone", label = "Everyone" },
                { value = "friends", label = "Friends", tip = "Friends, guildmates and group members only." },
                { value = "nobody", label = "Nobody", tip = "Nobody can watch your games." },
            } },
            { kind = "check", label = "Show the minimap button",
              get = function() return not ns.db.global.minimap.hide end,
              set = function(v)
                  ns.db.global.minimap.hide = not v
                  ns:Fire("MINIMAP_SETTING_CHANGED")
              end },
        },
    },
}

local function sectionTitle(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(C.panelBorder[1], C.panelBorder[2], C.panelBorder[3], 0.5)
    return fs, line
end

-- Build the controls into `parent`; returns an object with :Refresh().
function SettingsUI.Build(parent, width)
    local panel = { controls = {} }
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 420)
    panel.frame = f
    local colW = math.floor((width - 20) / 2)
    local columns = { { x = 0, y = 0 }, { x = colW + 20, y = 0 } }
    local placement = { 1, 2, 2 } -- section -> column

    for si, section in ipairs(SECTIONS) do
        local col = columns[placement[si]]
        if col.y ~= 0 then col.y = col.y - 14 end
        local title, line = sectionTitle(f, section.title)
        title:SetPoint("TOPLEFT", col.x, col.y)
        line:SetPoint("TOPLEFT", col.x, col.y - 20)
        line:SetWidth(colW)
        col.y = col.y - 28
        for _, item in ipairs(section.items) do
            local getter = item.get or function() return get(item.key) end
            local setter = item.set or function(v) set(item.key, v) end
            if item.kind == "check" then
                local c = W.Check(f, item.label, getter, setter, item.tip)
                c:SetPoint("TOPLEFT", col.x - 2, col.y)
                panel.controls[#panel.controls + 1] = c
                col.y = col.y - 26
            elseif item.kind == "segmented" then
                local l = W.Label(f, item.label, "GameFontNormalSmall")
                l:SetPoint("TOPLEFT", col.x, col.y - 2)
                local seg = W.Segmented(f, item.options, getter, setter, item.width or 88, 20)
                seg:SetPoint("TOPLEFT", col.x, col.y - 18)
                seg.label = l
                seg.enabledFn = item.enabled
                panel.controls[#panel.controls + 1] = seg
                col.y = col.y - 46
            elseif item.kind == "scale" then
                local l = W.Label(f, item.label, "GameFontNormalSmall")
                l:SetPoint("TOPLEFT", col.x, col.y - 6)
                local minus = W.FlatButton(f, "-", 24, 20, function()
                    set("scale", math.max(SCALE_MIN, math.floor((get("scale") - SCALE_STEP) * 100 + 0.5) / 100))
                end)
                minus:SetPoint("TOPLEFT", col.x + 90, col.y - 2)
                local value = W.Label(f, "", "GameFontHighlight", "CENTER")
                value:SetPoint("LEFT", minus, "RIGHT", 4, 0)
                value:SetWidth(48)
                local plus = W.FlatButton(f, "+", 24, 20, function()
                    set("scale", math.min(SCALE_MAX, math.floor((get("scale") + SCALE_STEP) * 100 + 0.5) / 100))
                end)
                plus:SetPoint("LEFT", value, "RIGHT", 4, 0)
                local ctl = { Refresh = function()
                    value:SetText(math.floor((get("scale") or 1) * 100 + 0.5) .. "%")
                end }
                panel.controls[#panel.controls + 1] = ctl
                col.y = col.y - 30
            end
        end
    end

    local reset = W.Button(f, "Reset to defaults", 150, 22, function()
        ns.Dialogs:Confirm("reset-settings", "Reset settings?", "Put every Chess Craft setting back to its default?",
            "Reset", function()
                ns.Database.ResetSettings()
                ns.db.global.minimap.hide = false
                ns:Fire("MINIMAP_SETTING_CHANGED")
            end, ns.UI and ns.UI.frame)
    end)
    reset:SetPoint("TOPLEFT", columns[2].x, math.min(columns[1].y, columns[2].y) - 16)

    local about = W.Label(f, "", "GameFontDisableSmall")
    about:SetPoint("TOPLEFT", columns[1].x, math.min(columns[1].y, columns[2].y) - 20)
    about:SetWidth(colW)
    about:SetText(string.format("Chess Craft %s · protocol %d · /chess help for commands", ns.version, ns.PROTOCOL))

    function panel:Refresh()
        for _, c in ipairs(self.controls) do
            if c.Refresh then c:Refresh() end
            if c.enabledFn then
                local on = c.enabledFn()
                c:SetAlpha(on and 1 or 0.4)
                for _, b in ipairs(c.buttons or {}) do b:SetEnabled(on) end
                if c.label then c.label:SetAlpha(on and 1 or 0.5) end
            end
        end
    end
    panel:Refresh()
    ns:On("SETTINGS_CHANGED", function() panel:Refresh() end)
    ns:On("MINIMAP_SETTING_CHANGED", function() panel:Refresh() end)
    f:SetScript("OnShow", function() panel:Refresh() end)
    return panel
end

-- Options > AddOns > Chess Craft
function SettingsUI.RegisterBlizzardPanel()
    if SettingsUI.category or not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return
    end
    local canvas = CreateFrame("Frame")
    local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ns.TITLE)
    local open = W.Button(canvas, "Open Chess Craft", 150, 22, function()
        ns.UI:Show()
        ns.UI:ShowTab("play")
    end)
    open:SetPoint("TOPRIGHT", -24, -16)
    local panel = SettingsUI.Build(canvas, 600)
    panel.frame:SetPoint("TOPLEFT", 18, -58)
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, canvas, ns.TITLE)
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
        SettingsUI.category = category
    end
end

return SettingsUI
