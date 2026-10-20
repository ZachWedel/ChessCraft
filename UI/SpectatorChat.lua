--[[
    Chess Craft - UI/SpectatorChat.lua
    The spectator chat window: the conversation on the left, who is
    watching on the right, a line to type in at the bottom. Same gold
    dialog frame as the rest of Chess Craft. Messages pass the word filter
    before they are sent and again when they arrive.
]]

local _, ns = ...
local Theme, W, Names = ns.Theme, ns.Widgets, ns.Names
local C = Theme.COLORS

local SpectatorChat = {}
ns.SpectatorChat = SpectatorChat

-- a side panel the height of the main window, docked to its right edge
local WIDTH, HEIGHT = 300, 548
local LOG_W, LOG_H = 238, 284

local function ts(t)
    return date and date("%H:%M", ns.Clock.server() - (ns.Clock.now() - (t or ns.Clock.now()))) or ""
end

function SpectatorChat:Build()
    if self.frame then return self.frame end
    local f = CreateFrame("Frame", "ChessCraftSpectatorChat", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetBackdrop(Theme.Backdrop())
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SpectatorChat.undocked = true          -- stays where the player put it
    end)
    f:Hide()
    self.frame = f
    if UISpecialFrames then table.insert(UISpecialFrames, "ChessCraftSpectatorChat") end

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("TOPLEFT", 16, -14)
    icon:SetTexture(Theme.ICON)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 7, 0)
    title:SetText("Spectator chat")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() f:Hide() end)
    self.subtitle = W.Label(f, "", "GameFontHighlightSmall")
    self.subtitle:SetPoint("TOPLEFT", 18, -42)
    self.subtitle:SetWidth(WIDTH - 36)
    self.subtitle:SetTextColor(C.dim[1], C.dim[2], C.dim[3])

    -- who is watching
    local who = W.Panel(f)
    who:SetPoint("TOPLEFT", 14, -74)
    who:SetPoint("TOPRIGHT", -14, -74)
    who:SetHeight(84)
    self.whoTitle = W.Label(who, "Watching", "GameFontNormalSmall")
    self.whoTitle:SetPoint("TOPLEFT", 8, -8)
    self.whoList = W.Label(who, "", "GameFontHighlightSmall")
    self.whoList:SetPoint("TOPLEFT", self.whoTitle, "BOTTOMLEFT", 0, -5)
    self.whoList:SetWidth(WIDTH - 28 - 16)
    self.whoList:SetJustifyV("TOP")

    -- conversation
    local logBg = W.Panel(f)
    logBg:SetPoint("TOPLEFT", who, "BOTTOMLEFT", 0, -6)
    logBg:SetSize(WIDTH - 28, LOG_H + 10)
    local scroll = CreateFrame("ScrollFrame", nil, logBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -5)
    scroll:SetSize(LOG_W, LOG_H)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LOG_W, 10)
    scroll:SetScrollChild(content)
    local log = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    log:SetPoint("TOPLEFT", 0, 0)
    log:SetWidth(LOG_W - 4)
    log:SetJustifyH("LEFT")
    log:SetJustifyV("TOP")
    self.scroll, self.content, self.log = scroll, content, log

    -- typing
    local box = W.EditBox(f, WIDTH - 28 - 78 - 12, function() SpectatorChat:Send() end)
    box:SetMaxLetters(180)
    box:SetPoint("BOTTOMLEFT", 22, 18)
    self.box = box
    local say = W.Button(f, "Say", 70, 22, function() SpectatorChat:Send() end)
    say:SetPoint("BOTTOMRIGHT", -16, 17)
    self.note = W.Label(f, "", "GameFontHighlightSmall")
    self.note:SetPoint("BOTTOMLEFT", box, "TOPLEFT", -4, 5)
    self.note:SetWidth(WIDTH - 36)
    self.note:SetTextColor(C.bad[1], C.bad[2], C.bad[3])

    f:SetScript("OnShow", function() SpectatorChat:Refresh() end)
    f:SetScript("OnHide", function() SpectatorChat:Undock() end)
    ns:On("SPECTATE_CHAT", function() SpectatorChat:Refresh() end)
    ns:On("SPECTATE_CHANGED", function()
        if not ns.Spectate:IsWatching() then f:Hide() else SpectatorChat:Refresh() end
    end)
    return f
end

-- Dock beside the main window. If the screen is too narrow for both, slide
-- the main window left for as long as the chat is open.
function SpectatorChat:Dock()
    local f, main = self.frame, ns.UI and ns.UI.frame
    f:SetScale((ns.db and ns.db.settings.scale) or 1)
    if self.undocked then return end
    f:ClearAllPoints()
    if not (main and main:IsShown()) then
        f:SetPoint("RIGHT", UIParent, "RIGHT", -20, 40)
        return
    end
    f:SetPoint("TOPLEFT", main, "TOPRIGHT", -4, 0)
    local mainScale, uiScale = main:GetEffectiveScale() or 1, UIParent:GetEffectiveScale() or 1
    local right, left, top = main:GetRight(), main:GetLeft(), main:GetTop()
    local screenW = (UIParent:GetWidth() or 0) * uiScale
    if not (right and left and top) or screenW <= 0 then return end
    local over = (right * mainScale) + (WIDTH - 4) * (f:GetEffectiveScale() or 1) - screenW
    if over > 0 then
        local newLeft = math.max(0, left - over / mainScale)
        if newLeft < left then
            main:ClearAllPoints()
            main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newLeft, top)
            self.shiftedMain = true
        end
    end
end

-- put the main window back where the player keeps it
function SpectatorChat:Undock()
    if self.shiftedMain and ns.UI and ns.UI.frame then
        self.shiftedMain = nil
        ns.UI:RestorePosition()
    end
end

function SpectatorChat:Show()
    if not ns.Spectate:IsWatching() then return end
    local f = self:Build()
    if not f:IsShown() then self:Dock() end
    f:Show()
    f:Raise()
end

function SpectatorChat:Toggle()
    if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Show() end
end

function SpectatorChat:Send()
    local text = self.box:GetText() or ""
    if text:match("^%s*$") then return end
    local ok, why = ns.Spectate:SendChat(text)
    if ok then
        self.box:SetText("")
        self.note:SetText("")
    elseif why then
        self.note:SetText(why)
    end
end

function SpectatorChat:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    local S = ns.Spectate
    local g = S:Game()
    if g then
        self.subtitle:SetText(string.format("%s vs %s. The players can't see this chat.",
            Names.Display(g.players[1].name), Names.Display(g.players[2].name)))
    end
    local lines = {}
    for _, m in ipairs(S.chat) do
        local stamp = Theme.ColorText(ts(m.at), C.dim)
        if m.system then
            lines[#lines + 1] = stamp .. " " .. Theme.ColorText(m.text, C.warn)
        else
            local mine = Names.IsMe(m.from)
            local who = Theme.ColorText(Names.Display(m.from) .. ":", mine and C.good or C.gold)
            lines[#lines + 1] = stamp .. " " .. who .. " " .. m.text
        end
    end
    self.log:SetText(table.concat(lines, "\n"))
    self.content:SetHeight(math.max(10, (self.log:GetStringHeight() or 0) + 4))
    if self.scroll.UpdateScrollChildRect then self.scroll:UpdateScrollChildRect() end
    local scroll = self.scroll
    scroll:SetVerticalScroll(scroll:GetVerticalScrollRange() or 0)
    C_Timer.After(0, function() scroll:SetVerticalScroll(scroll:GetVerticalScrollRange() or 0) end)

    local names = { Theme.ColorText(Names.Display(Names.Me()) .. " (you)", C.good) }
    for _, n in ipairs(S.spectators or {}) do
        if not Names.IsMe(n) then names[#names + 1] = Names.Display(n) end
    end
    self.whoTitle:SetText(string.format("Watching (%d)", #names))
    self.whoList:SetText(table.concat(names, #names > 4 and ", " or "\n"))
end

return SpectatorChat
