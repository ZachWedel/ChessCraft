--[[
    Chess Craft - UI/Widgets.lua
    Small constructors for the addon's widgets, so every screen shares one look.
]]

local _, ns = ...
local Theme = ns.Theme

local W = {}
ns.Widgets = W

local C = Theme.COLORS

function W.Tooltip(owner, title, lines)
    if not GameTooltip then return end
    owner:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(type(title) == "function" and title() or title, 1, 0.82, 0)
        local l = type(lines) == "function" and lines() or lines
        if type(l) == "string" then l = { l } end
        for _, line in ipairs(l or {}) do GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function W.Panel(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetBackdrop(Theme.PanelBackdrop())
    f:SetBackdropColor(unpack(C.panelBg))
    f:SetBackdropBorderColor(unpack(C.panelBorder))
    return f
end

function W.Label(parent, text, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

function W.Header(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    return fs
end

-- Classic red WoW button.
function W.Button(parent, text, width, height, onClick, tipTitle, tipText)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 100, height or 22)
    b:SetText(text or "")
    if onClick then b:SetScript("OnClick", function(self, button) onClick(self, button) end) end
    if tipTitle then W.Tooltip(b, tipTitle, tipText) end
    return b
end

-- Flat toggle button used for segmented choices and lists.
function W.FlatButton(parent, text, width, height, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 80, height or 22)
    b:SetBackdrop(Theme.FlatBackdrop())
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("CENTER")
    b.label:SetText(text or "")
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetTexture(Theme.WHITE8)
    b.hl:SetVertexColor(1, 1, 1, 0.08)
    b.hl:SetPoint("TOPLEFT", 2, -2)
    b.hl:SetPoint("BOTTOMRIGHT", -2, 2)
    function b:SetSelected(sel)
        self.selected = sel
        if sel then
            self:SetBackdropColor(0.42, 0.33, 0.12, 0.95)
            self:SetBackdropBorderColor(1, 0.82, 0, 1)
            self.label:SetTextColor(1, 0.9, 0.5)
        else
            self:SetBackdropColor(0.10, 0.09, 0.08, 0.92)
            self:SetBackdropBorderColor(0.45, 0.38, 0.25, 0.9)
            self.label:SetTextColor(0.9, 0.9, 0.9)
        end
    end
    function b:SetLabel(t) self.label:SetText(t) end
    b:SetSelected(false)
    if onClick then
        b:SetScript("OnClick", function(self, button)
            ns.Compat.PlaySound("click")
            onClick(self, button)
        end)
    end
    return b
end

-- Row of flat buttons where exactly one is selected.
-- options: { { value = x, label = "Text", tip = "optional" }, ... }
function W.Segmented(parent, options, getter, setter, buttonWidth, height)
    local f = CreateFrame("Frame", nil, parent)
    f.buttons = {}
    local w = buttonWidth or 80
    local h = height or 22
    for i, opt in ipairs(options) do
        local b = W.FlatButton(f, opt.label, w, h, function()
            setter(opt.value)
            f:Refresh()
        end)
        b:SetPoint("LEFT", (i - 1) * (w + 4), 0)
        b.value = opt.value
        if opt.tip then W.Tooltip(b, opt.label, opt.tip) end
        f.buttons[i] = b
    end
    f:SetSize(#options * (w + 4) - 4, h)
    function f:Refresh()
        local v = getter()
        for _, b in ipairs(self.buttons) do b:SetSelected(b.value == v) end
    end
    f:Refresh()
    return f
end

function W.Check(parent, label, getter, setter, tip)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    if c.Text then
        c.Text:SetFontObject("GameFontHighlight")
        c.Text:SetText(label)
    end
    c:SetScript("OnClick", function(self)
        ns.Compat.PlaySound("click")
        setter(self:GetChecked() and true or false)
    end)
    if tip then W.Tooltip(c, label, tip) end
    function c:Refresh() self:SetChecked(getter() and true or false) end
    c:Refresh()
    return c
end

function W.EditBox(parent, width, onEnter)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width or 150, 22)
    e:SetAutoFocus(false)
    e:SetMaxLetters(64)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onEnter then onEnter(self:GetText()) end
    end)
    return e
end

-- Square icon with a thin dark border.
function W.Icon(parent, size)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(size, size)
    holder:SetBackdrop(Theme.FlatBackdrop())
    holder:SetBackdropColor(0, 0, 0, 0.6)
    holder:SetBackdropBorderColor(0.55, 0.45, 0.25, 1)
    holder.tex = holder:CreateTexture(nil, "ARTWORK")
    holder.tex:SetPoint("TOPLEFT", 2, -2)
    holder.tex:SetPoint("BOTTOMRIGHT", -2, 2)
    holder.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return holder
end

--[[ Simple pooled scrolling list.
     createRow(parent) -> row frame (height = rowHeight)
     updateRow(row, item, index)
]]
function W.ScrollList(parent, width, height, rowHeight, createRow, updateRow)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width, height)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width, 1)
    scroll:SetScrollChild(content)
    scroll.content = content
    scroll.rows = {}
    scroll.rowHeight = rowHeight
    function scroll:SetItems(items)
        self.items = items
        for i, item in ipairs(items) do
            local row = self.rows[i]
            if not row then
                row = createRow(content)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
                row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
                self.rows[i] = row
            end
            row:Show()
            updateRow(row, item, i)
        end
        for i = #items + 1, #self.rows do self.rows[i]:Hide() end
        content:SetHeight(math.max(1, #items * rowHeight))
    end
    function scroll:ScrollToBottom()
        local range = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(range)
    end
    return scroll
end

-- Read-only text box the user can copy from (Ctrl+A, Ctrl+C).
function W.CopyBox(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width, height)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(width - 8)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self.fixed then self:SetText(self.fixed); self:HighlightText() end
    end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    scroll:SetScrollChild(edit)
    function scroll:SetCopyText(text)
        edit.fixed = text
        edit:SetText(text)
    end
    function scroll:Focus()
        edit:SetFocus()
        edit:HighlightText()
    end
    scroll.edit = edit
    return scroll
end

function W.FormatClock(ms)
    if not ms then return "--:--" end
    if ms < 0 then ms = 0 end
    if ms < 10000 then
        return string.format("0:%04.1f", ms / 1000)
    end
    local total = math.floor(ms / 1000)
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

function W.TimeAgo(t)
    local d = (ns.Clock.server() or 0) - (t or 0)
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end
