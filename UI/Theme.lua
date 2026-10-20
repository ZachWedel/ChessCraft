--[[
    Chess Craft - UI/Theme.lua
    Visual themes: "classic" (Staunton pieces, wood/green/slate boards) and
    "faction" (Alliance-blue white pieces vs Horde-crimson black pieces on
    a stone board, with the faction emblems from the game's own art).

    Style rule: every window and feature keeps the classic WoW look set here
    and in UI/Widgets.lua (gold-bordered dialog frames, red panel buttons,
    Blizzard fonts, stock icons and sounds). Build new screens from these
    constructors rather than introducing a new visual style.
]]

local _, ns = ...
local T = ns.ChessTables

local Theme = {}
ns.Theme = Theme

local MEDIA = "Interface\\AddOns\\ChessCraft\\Media\\"
Theme.MEDIA = MEDIA
Theme.WHITE8 = "Interface\\Buttons\\WHITE8X8"
Theme.ICON = MEDIA .. "Icon.tga"
Theme.DOT = MEDIA .. "UI\\Dot.tga"
Theme.RING = MEDIA .. "UI\\Ring.tga"
Theme.GLOW = MEDIA .. "UI\\Glow.tga"

local LETTER = { "P", "N", "B", "R", "Q", "K" }

Theme.BOARDS = {
    wood = { name = "Wood", light = { tex = MEDIA .. "Board\\WoodLight.tga" }, dark = { tex = MEDIA .. "Board\\WoodDark.tga" },
             frame = { 0.30, 0.20, 0.12 }, coord = { 0.95, 0.86, 0.70 } },
    green = { name = "Tournament", light = { color = { 0.93, 0.93, 0.82 } }, dark = { color = { 0.46, 0.59, 0.34 } },
              frame = { 0.17, 0.21, 0.14 }, coord = { 0.88, 0.92, 0.80 } },
    slate = { name = "Slate", light = { color = { 0.87, 0.89, 0.90 } }, dark = { color = { 0.55, 0.64, 0.68 } },
              frame = { 0.17, 0.20, 0.24 }, coord = { 0.85, 0.90, 0.95 } },
    stone = { name = "Stone", light = { tex = MEDIA .. "Board\\StoneLight.tga" }, dark = { tex = MEDIA .. "Board\\StoneDark.tga" },
              frame = { 0.12, 0.12, 0.14 }, coord = { 0.85, 0.85, 0.85 } },
}

Theme.COLORS = {
    gold = { 1.0, 0.82, 0.0 },
    text = { 0.95, 0.95, 0.95 },
    dim = { 0.62, 0.60, 0.56 },
    good = { 0.35, 0.90, 0.35 },
    bad = { 1.0, 0.32, 0.28 },
    warn = { 1.0, 0.65, 0.15 },
    lastMove = { 0.96, 0.84, 0.22, 0.42 },
    selected = { 0.36, 0.86, 0.36, 0.50 },
    hover = { 1.0, 1.0, 1.0, 0.18 },
    legal = { 0.08, 0.08, 0.08, 0.38 },
    capture = { 0.08, 0.08, 0.08, 0.38 },
    check = { 1.0, 0.12, 0.08, 0.95 },
    panelBg = { 0.07, 0.06, 0.05, 0.92 },
    panelBorder = { 0.62, 0.50, 0.28, 0.95 },
    clockBg = { 0.12, 0.11, 0.10, 1.0 },
    clockActive = { 0.85, 0.82, 0.70, 1.0 },
    clockLow = { 0.75, 0.15, 0.12, 1.0 },
}

-- side accents: classic uses neutral tones; faction uses Alliance blue / Horde red
local SIDE = {
    classic = {
        { name = "White", color = { 0.95, 0.95, 0.92 } },
        { name = "Black", color = { 0.70, 0.70, 0.70 } },
    },
    faction = {
        { name = "Alliance", color = { 0.32, 0.56, 1.0 }, emblem = "AllianceEmblem" },
        { name = "Horde", color = { 0.95, 0.25, 0.18 }, emblem = "HordeEmblem" },
    },
}

function Theme.Current()
    local s = ns.db and ns.db.settings
    return (s and s.theme == "faction") and "faction" or "classic"
end

function Theme.BoardStyle()
    if Theme.Current() == "faction" then return Theme.BOARDS.stone end
    local key = ns.db and ns.db.settings.boardStyle or "wood"
    return Theme.BOARDS[key] or Theme.BOARDS.wood
end

function Theme.Side(side) return SIDE[Theme.Current()][side] end

-- texture path for a piece code (1..12)
function Theme.PieceTexture(piece)
    local white = piece <= 6
    local letter = LETTER[T.TYPE[piece]]
    if Theme.Current() == "faction" then
        return MEDIA .. "Pieces\\" .. (white and "Alliance\\w" or "Horde\\b") .. letter .. ".tga"
    end
    return MEDIA .. "Pieces\\Classic\\" .. (white and "w" or "b") .. letter .. ".tga"
end

function Theme.PieceTextureFor(side, pieceType)
    return Theme.PieceTexture(T.PIECE[side][pieceType])
end

-- In a bot game the bot's pieces come from its own set (light set when it
-- plays White, dark set when it plays Black), unless turned off in Settings.
function Theme.PieceTextureInGame(game, piece)
    if game and game.mode == "bot" and ns.db.settings.botPieces ~= false then
        local botSide = 3 - (game.localColor or 1)
        if T.COLOR[piece] == botSide then
            local bot = game.players[botSide]
            local id = (bot and bot.botId) or (game.extra and game.extra.botId)
            local persona = id and ns.Bots and ns.Bots.Get(id)
            if persona then
                return MEDIA .. "Pieces\\Bots\\" .. persona.id .. "\\" .. ((botSide == 1) and "w" or "b")
                    .. LETTER[T.TYPE[piece]] .. ".tga"
            end
        end
    end
    return Theme.PieceTexture(piece)
end

-- Is this emblem's art in the client? (All of them are in 1.60.1; this keeps a
-- future client without one of the atlases from showing an empty square.)
function Theme.EmblemAvailable(em)
    if em and em.atlas and C_Texture and C_Texture.GetAtlasInfo then
        return C_Texture.GetAtlasInfo(em.atlas) ~= nil
    end
    return em ~= nil
end

-- Show a player-card emblem (chess piece, faction crest, class or race icon).
function Theme.SetEmblem(tex, em)
    if em and em.atlas and Theme.EmblemAvailable(em) then
        tex:SetAtlas(em.atlas)
    else
        tex:SetTexture(Theme.PieceTextureFor(1, (em and em.piece) or 2))
    end
    tex:SetTexCoord(0, 1, 0, 1)
end

function Theme.Backdrop()
    return {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    }
end

function Theme.PanelBackdrop()
    return {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    }
end

function Theme.FlatBackdrop()
    return {
        bgFile = Theme.WHITE8,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    }
end

function Theme.ColorText(text, c)
    return string.format("|cff%02x%02x%02x%s|r", math.floor(c[1] * 255), math.floor(c[2] * 255),
        math.floor(c[3] * 255), text)
end
