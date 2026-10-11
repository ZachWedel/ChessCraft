--[[
    Chess Craft - AI/Bots.lua
    The bot roster (Azeroth personas, like Peggle's masters) and the
    controller that turns a persona into moves without blocking the game:
    book move or time-sliced search, plus a short "thinking" delay so even
    instant answers feel natural.
]]

local _, ns = ...
local Board = ns.Board
local Book = ns.Book

local Bots = {}
ns.Bots = Bots

local ICON = "Interface\\Icons\\"

--[[ Difficulty knobs (see AI/Search.lua):
     maxDepth   plies searched
     quiesce    resolve captures at the horizon (false = misses simple tactics)
     multiRoot  score every root move exactly, then pick with noise/blunders
     noise      +/- centipawns of randomness added to each root move
     blunder    chance of choosing among "playable" moves at random
     blunderMargin  how much worse (cp) such a random move may be
     cpuMs      CPU time budget per move
     book       how many plies of opening book it knows
     delay      { min, max } seconds before replying (feel, not strength)
]]
Bots.list = {
    {
        id = "kobold", level = 1, rating = 250,
        name = "Kobold Candle-Snatcher",
        icon = { ICON .. "INV_Misc_Head_Kobold_01", ICON .. "Racial_Dwarf_FindTreasure" },
        blurb = "Grabs anything shiny. Sometimes that's even a piece.",
        params = { maxDepth = 1, quiesce = false, multiRoot = true, noise = 320, blunder = 0.35,
                   blunderMargin = 100000, cpuMs = 300, book = 0, delay = { 0.5, 1.0 } },
        quips = {
            greet = { "Me play too! Me take shiny horse first.", "Candle say... you go first. Maybe." },
            capture = { "Mine now!", "Shiny! Kobold keep it." },
            lostPiece = { "Hey! That Kobold's!", "No take piece!" },
            check = { "Check! Kobold know that word!" },
            win = { "Kobold is king of tunnel now!" },
            lose = { "Candle go out... Kobold go home." },
            draw = { "Nobody win? Kobold confused." },
        },
    },
    {
        id = "murloc", level = 2, rating = 450,
        name = "Murloc Tidehunter",
        icon = { ICON .. "INV_Misc_Head_Murloc_01", ICON .. "INV_Misc_Fish_02", ICON .. "Spell_Frost_SummonWaterElemental" },
        blurb = "Splashes pieces around with great enthusiasm and little plan.",
        params = { maxDepth = 1, quiesce = true, multiRoot = true, noise = 200, blunder = 0.25,
                   blunderMargin = 600, cpuMs = 400, book = 2, delay = { 0.5, 1.1 } },
        quips = {
            greet = { "Mrgle mrgle! (Let's play!)", "Mrrglglgl!" },
            capture = { "Mrglgl!", "Rwlrwlrwl!" },
            lostPiece = { "Mmmrrglll...", "Mrgl?!" },
            check = { "MRGLGL! (Check!)" },
            win = { "Mrrgglglglgl! (Victory dance)" },
            lose = { "Mrgl... (sad bubbles)" },
            draw = { "Mrgl mrgl. (Fair enough.)" },
        },
    },
    {
        id = "peon", level = 3, rating = 650,
        name = "Peon Foreman",
        icon = { ICON .. "Achievement_Character_Orc_Male", ICON .. "INV_Misc_Head_Orc_01", ICON .. "INV_Axe_02" },
        blurb = "Knows a few openings and works hard. Tires out in the middlegame.",
        params = { maxDepth = 2, quiesce = true, multiRoot = true, noise = 130, blunder = 0.14,
                   blunderMargin = 400, cpuMs = 600, book = 4, delay = { 0.6, 1.3 } },
        quips = {
            greet = { "Me ready to work. On chess, okay.", "Boss say play chess. Me play chess." },
            capture = { "That piece go in the lumber pile.", "More work done!" },
            lostPiece = { "Ow. That one hurt.", "Me not like that." },
            check = { "Your king need to move. Me say so." },
            win = { "Job done! Me go nap now." },
            lose = { "Me go back to the mines..." },
            draw = { "Half a job. Boss not happy." },
        },
    },
    {
        id = "tinker", level = 4, rating = 850,
        name = "Gnomish Tinker",
        icon = { ICON .. "Achievement_Character_Gnome_Male", ICON .. "INV_Gnometoy", ICON .. "INV_Misc_Gear_01" },
        blurb = "Calculates two moves ahead, then gets distracted by a new gadget.",
        params = { maxDepth = 2, quiesce = true, multiRoot = true, noise = 75, blunder = 0.08,
                   blunderMargin = 250, cpuMs = 800, book = 6, delay = { 0.7, 1.4 } },
        quips = {
            greet = { "Fascinating! A strategic mechanism with sixty-four cogs!", "Let's see what this contraption can do!" },
            capture = { "Disassembled!", "I'll recycle that one." },
            lostPiece = { "Hmm, a design flaw.", "That wasn't in the schematics!" },
            check = { "Your king's gears are grinding!" },
            win = { "Eureka! Another successful experiment!" },
            lose = { "Back to the drawing board. Literally." },
            draw = { "Perfectly balanced, like a good gyroscope." },
        },
    },
    {
        id = "mountaineer", level = 5, rating = 1050,
        name = "Dwarven Mountaineer",
        icon = { ICON .. "Achievement_Character_Dwarf_Male", ICON .. "INV_Weapon_Rifle_05" },
        blurb = "Solid and stubborn. Rarely hangs pieces, but misses deep ideas.",
        params = { maxDepth = 3, quiesce = true, multiRoot = true, noise = 40, blunder = 0.04,
                   blunderMargin = 150, cpuMs = 1200, book = 8, delay = { 0.8, 1.5 } },
        quips = {
            greet = { "Set 'em up! First round's on the loser.", "Ach, a fine board. Let's have at it." },
            capture = { "Down she goes!", "Ha! Right between the eyes." },
            lostPiece = { "By my beard...", "Lucky shot, that." },
            check = { "Your king's in me sights!" },
            win = { "Ha! Drinks are on ye!" },
            lose = { "Well played, friend. Next one's mine." },
            draw = { "A stalemate as stubborn as a dwarf. I'll allow it." },
        },
    },
    {
        id = "apothecary", level = 6, rating = 1300,
        name = "Forsaken Apothecary",
        icon = { ICON .. "Achievement_Character_Undead_Female", ICON .. "Spell_Shadow_RaiseDead" },
        blurb = "Methodical and patient. Brews slow poison, positionally.",
        params = { maxDepth = 4, cpuMs = 700, book = 10, delay = { 0.8, 1.6 } },
        quips = {
            greet = { "Shall we begin the experiment?", "Death is patient. So am I." },
            capture = { "Another specimen for the collection.", "Fascinating decay." },
            lostPiece = { "Merely a setback.", "I have more where that came from." },
            check = { "Your king looks... unwell." },
            win = { "The results are conclusive." },
            lose = { "Impressive. You'd make a fine test subject." },
            draw = { "Inconclusive. We will repeat the trial." },
        },
    },
    {
        id = "shadowhunter", level = 7, rating = 1550,
        name = "Darkspear Shadow Hunter",
        icon = { ICON .. "Achievement_Character_Troll_Male", ICON .. "Racial_Troll_Berserk" },
        blurb = "Sees tactics coming from far away. Punishes loose pieces.",
        params = { maxDepth = 6, cpuMs = 1300, book = 14, delay = { 0.8, 1.6 } },
        quips = {
            greet = { "The spirits be watchin' this one, mon.", "Stay away from da voodoo... and my bishops." },
            capture = { "Da loa took it.", "Ya never saw it comin'." },
            lostPiece = { "Ya got lucky, mon.", "Hmm. Da spirits be quiet." },
            check = { "Ya king be feelin' da hex now!" },
            win = { "Da spirits smile on Darkspear!" },
            lose = { "Respect, mon. Ya play strong." },
            draw = { "Even da spirits can't decide." },
        },
    },
    {
        id = "archmage", level = 8, rating = 1800,
        name = "Archmage of Dalaran",
        icon = { ICON .. "Spell_Arcane_PortalDalaran", ICON .. "Ability_Mage_IncantersAbsorbtion", ICON .. "Spell_Holy_MagicalSentry" },
        blurb = "Thinks deeply on every move. The strongest opponent Chess Craft offers.",
        params = { maxDepth = 40, cpuMs = 2600, book = 20, delay = { 0.6, 1.2 } },
        quips = {
            greet = { "The Kirin Tor teach patience. Let us see yours.", "An excellent game for a quiet evening in Dalaran." },
            capture = { "Calculated.", "As foreseen." },
            lostPiece = { "A worthy sacrifice. Or was it?", "Interesting. Most interesting." },
            check = { "Check. Choose your next step carefully." },
            win = { "A fine game. Study it well." },
            lose = { "Remarkable. You have my respect, champion." },
            draw = { "A draw. The balance holds." },
        },
    },
}

Bots.byId, Bots.byLevel = {}, {}
for _, p in ipairs(Bots.list) do
    Bots.byId[p.id] = p
    Bots.byLevel[p.level] = p
end

function Bots.Get(idOrLevel)
    if type(idOrLevel) == "number" then
        local lvl = math.max(1, math.min(#Bots.list, math.floor(idOrLevel)))
        return Bots.byLevel[lvl]
    end
    return Bots.byId[idOrLevel]
end

function Bots.Quip(persona, event)
    local q = persona and persona.quips and persona.quips[event]
    if not q or #q == 0 then return nil end
    return q[math.random(1, #q)]
end

-- shared search engine (one bot thinks at a time) ---------------------------------
function Bots.GetSearch()
    if not Bots.search then Bots.search = ns.Search.new() end
    return Bots.search
end

function Bots.ReleaseMemory()
    if Bots.search then Bots.search:freeMemory() end
end

-- controller --------------------------------------------------------------------
local Controller = {}
Controller.__index = Controller

function Bots.NewController(persona)
    return setmetatable({ persona = persona, state = "idle" }, Controller)
end

local function rand(a, b) return a + (b - a) * math.random() end

-- Begin choosing a move for game.board (it must be the bot's turn).
function Controller:Start(game)
    self.game = game
    self.state = "thinking"
    self.started = ns.Clock.now()
    local p = self.persona.params
    local d = p.delay or { 0.6, 1.2 }
    self.minDelay = rand(d[1], d[2])
    self.pending = nil

    if (p.book or 0) > 0 and game:IsStandardStart() then
        local mv = Book.Next(game.moves, p.book)
        if mv and game.board:uciToMove(mv) then
            self.pending = mv
            self.state = "ready"
            return
        end
    end
    local params = {}
    for k, v in pairs(p) do params[k] = v end
    params.rng = math.random
    self.search = Bots.GetSearch()
    self.search:begin(game.board, params)
end

-- Spend up to sliceMs thinking. Returns a UCI move when it is time to play it.
function Controller:Update(sliceMs)
    if self.state == "thinking" then
        local done, move, err = self.search:step(sliceMs)
        if done then
            if err then ns.Debug("bot search error: %s", err) end
            if not move then
                local legal = self.game.board:legalMoves()
                move = legal[math.random(1, #legal)]
            end
            self.pending = move and Board.MoveToUCI(move)
            self.state = self.pending and "ready" or "idle"
        end
    end
    if self.state == "ready" and ns.Clock.now() - self.started >= self.minDelay then
        self.state = "idle"
        local mv = self.pending
        self.pending = nil
        return mv
    end
    return nil
end

function Controller:IsThinking() return self.state ~= "idle" end

function Controller:Cancel()
    if self.search and self.state == "thinking" then self.search:abort() end
    self.state = "idle"
    self.pending = nil
end

return Bots
