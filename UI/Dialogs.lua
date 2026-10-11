--[[
    Chess Craft - UI/Dialogs.lua
    The addon's own pop-up dialogs and toasts (challenges, draw offers,
    confirmations, "your move" notices).

    Blizzard's StaticPopup frames are shared with protected game dialogs, so
    an addon using them can taint those dialogs. Chess Craft draws its own
    instead: stacked under the top of the screen, closable with Escape,
    with an optional countdown bar.

    Dialogs:Show(key, opts)
      opts.title, opts.text
      opts.icon (path or list of paths), opts.atlas, opts.iconCoords
      opts.buttons = { { label = "Accept", onClick = fn }, ... }   (up to 3)
      opts.timeout (seconds), opts.onTimeout(), opts.onDismiss(reason)
      opts.onClick()    clicking the dialog body (toasts)
      opts.anchor       frame to center on instead of the top-of-screen stack
      opts.sound        Compat sound key
]]

local _, ns = ...
local Theme, W, Compat = ns.Theme, ns.Widgets, ns.Compat

local Dialogs = {}
ns.Dialogs = Dialogs

local WIDTH = 360
local ICON = 40
local TEXT_WIDTH = WIDTH - 20 - ICON - 10 - 26
local STACK_TOP = -120

local stack = {}   -- frames shown in the top-of-screen stack, in order
local byKey = {}
local pool = {}
local created = 0

local function layout()
    local y = STACK_TOP
    for _, f in ipairs(stack) do
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, y)
        y = y - f:GetHeight() - 6
    end
end

local function removeFromStack(f)
    for i, x in ipairs(stack) do
        if x == f then
            table.remove(stack, i)
            return
        end
    end
end

local function create()
    created = created + 1
    local name = "ChessCraftDialog" .. created
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetWidth(WIDTH)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetBackdrop(Theme.Backdrop())
    f:Hide()

    f.icon = W.Icon(f, ICON)
    f.icon:SetPoint("TOPLEFT", 20, -20)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -1)
    f.title:SetWidth(TEXT_WIDTH)
    f.title:SetJustifyH("LEFT")

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.text:SetWidth(TEXT_WIDTH)
    f.text:SetJustifyH("LEFT")
    f.text:SetJustifyV("TOP")

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -5, -5)
    f.close:SetScript("OnClick", function() Dialogs:Dismiss(f, "close") end)

    f.buttons = {}
    for i = 1, 3 do
        local b = W.Button(f, "", 110, 22, function() Dialogs:Press(f, i) end)
        b:Hide()
        f.buttons[i] = b
    end

    f.barBg = f:CreateTexture(nil, "BORDER")
    f.barBg:SetPoint("BOTTOMLEFT", 14, 13)
    f.barBg:SetSize(WIDTH - 28, 3)
    f.barBg:SetColorTexture(0, 0, 0, 0.5)
    f.bar = f:CreateTexture(nil, "ARTWORK")
    f.bar:SetPoint("BOTTOMLEFT", 14, 13)
    f.bar:SetSize(WIDTH - 28, 3)
    f.bar:SetColorTexture(1, 0.82, 0, 0.85)

    f:SetScript("OnUpdate", function(self, elapsed) Dialogs:Tick(self, elapsed) end)
    f:SetScript("OnHide", function(self) Dialogs:OnFrameHidden(self) end)
    f:SetScript("OnMouseUp", function(self, button)
        local opts = self.opts
        if opts and opts.onClick and button == "LeftButton" then
            self.done = true
            self:Hide()
            ns.safecall(opts.onClick)
        end
    end)

    -- Escape closes dialogs like any other window
    if UISpecialFrames then table.insert(UISpecialFrames, name) end
    return f
end

function Dialogs:Show(key, opts)
    opts = opts or {}
    local f = byKey[key]
    if not f then
        f = table.remove(pool) or create()
        f.key = key
        byKey[key] = f
    end
    f.opts = opts
    f.done = false
    f.hideReason = nil

    if opts.atlas then
        f.icon.tex:SetAtlas(opts.atlas)
        f.icon.tex:SetTexCoord(0, 1, 0, 1)
    else
        Compat.SetTextureFromList(f.icon.tex, opts.icon or Theme.ICON)
        local c = opts.iconCoords
        if c then f.icon.tex:SetTexCoord(c[1], c[2], c[3], c[4])
        elseif opts.icon then f.icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else f.icon.tex:SetTexCoord(0, 1, 0, 1) end
    end

    f.title:SetText(opts.title or ns.TITLE)
    f.text:SetText(opts.text or "")

    local buttons = opts.buttons or {}
    local n = math.min(#buttons, 3)
    local bw = (n == 3) and 100 or 120
    local total = n * bw + math.max(0, n - 1) * 8
    for i = 1, 3 do
        local b = f.buttons[i]
        local spec = buttons[i]
        if spec and i <= n then
            b:SetText(spec.label or "")
            b:SetWidth(bw)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", f, "BOTTOM", -total / 2 + (i - 1) * (bw + 8), 22)
            b:Show()
        else
            b:Hide()
        end
    end

    f.timeout = opts.timeout
    f.remaining = opts.timeout
    f.bar:SetShown(opts.timeout ~= nil)
    f.barBg:SetShown(opts.timeout ~= nil)
    if opts.timeout then f.bar:SetWidth(WIDTH - 28) end

    local textH = f.text:GetStringHeight() or 14
    local content = math.max(ICON, 18 + textH)
    f:SetHeight(20 + content + ((n > 0) and 40 or 0) + 22)

    removeFromStack(f)
    f:ClearAllPoints()
    if opts.anchor then
        f:SetPoint("CENTER", opts.anchor, "CENTER", 0, 30)
    else
        stack[#stack + 1] = f
    end
    f:Show()
    f:Raise()
    layout()
    if opts.sound then Compat.PlaySound(opts.sound) end
    return f
end

function Dialogs:IsShown(key)
    local f = byKey[key]
    return f ~= nil and f:IsShown()
end

function Dialogs:Get(key) return byKey[key] end

-- Hide without running any callback.
function Dialogs:Hide(key)
    local f = byKey[key]
    if not f then return end
    f.done = true
    f:Hide()
end

function Dialogs:Press(f, index)
    local opts = f.opts
    local spec = opts and opts.buttons and opts.buttons[index]
    if not spec then return end
    if not spec.keepOpen then
        f.done = true
        f:Hide()
    end
    if spec.onClick then ns.safecall(spec.onClick) end
end

function Dialogs:Dismiss(f, reason)
    f.hideReason = reason
    f:Hide()
end

function Dialogs:Tick(f, elapsed)
    if not f.remaining then return end
    f.remaining = f.remaining - elapsed
    if f.remaining <= 0 then
        f.remaining = nil
        local opts = f.opts
        f.done = true
        f:Hide()
        if opts then
            if opts.onTimeout then ns.safecall(opts.onTimeout)
            elseif opts.onDismiss then ns.safecall(opts.onDismiss, "timeout") end
        end
        return
    end
    f.bar:SetWidth(math.max(1, (WIDTH - 28) * f.remaining / f.timeout))
end

function Dialogs:OnFrameHidden(f)
    local opts, done, reason = f.opts, f.done, f.hideReason or "escape"
    if byKey[f.key] == f then byKey[f.key] = nil end
    removeFromStack(f)
    f.opts, f.key, f.remaining = nil, nil, nil
    pool[#pool + 1] = f
    layout()
    if not done and opts and opts.onDismiss then ns.safecall(opts.onDismiss, reason) end
end

-- Small notice that disappears on its own; clicking it runs onClick.
function Dialogs:Toast(key, title, text, opts)
    opts = opts or {}
    return self:Show(key, {
        title = title, text = text, icon = opts.icon, atlas = opts.atlas, iconCoords = opts.iconCoords,
        timeout = opts.timeout or 8, onClick = opts.onClick, sound = opts.sound,
    })
end

-- Yes/no question. onAccept runs on the first button.
function Dialogs:Confirm(key, title, text, acceptLabel, onAccept, anchor)
    return self:Show(key, {
        title = title, text = text, anchor = anchor,
        buttons = {
            { label = acceptLabel or OKAY or "Okay", onClick = onAccept },
            { label = CANCEL or "Cancel" },
        },
    })
end

function Dialogs:HideAll()
    for key in pairs(byKey) do self:Hide(key) end
end

return Dialogs
