--[[
    Chess Craft - Profile/Profile.lua
    Your player card: rating, record and the bits you choose yourself
    (title, motto, emblem, card frame, card background). Cards are shared
    with other Chess Craft players on request.

      PQ                    "send me your card"
      PF~v~rating~games~w~l~d~peak~emblem~frame~backdrop~bestBot~title~motto

    Both are new message types, so older clients simply ignore them and can
    still play 0.3.0 players.

    Rating: live games against players only (bots never change it). At the
    start of a live game both sides ask for each other's card; the result is
    applied once per game when it ends (aborted games don't count).
]]

local _, ns = ...
local Comm, Names, Rating = ns.Comm, ns.Names, ns.Rating

local Profile = ns:NewModule("Profile")
Profile.cache = {}          -- sender name -> card (plus .at)

local CARD_VERSION = 1
local TITLE_MAX, MOTTO_MAX = 24, 60
local REPLY_GAP = 5
local CACHE_TTL = 10 * 60
local RATED_MEMORY = 200
local START_QUERY_TRIES, START_QUERY_GAP = 4, 5

local function now() return ns.Clock.now() end

-- customization choices (all drawn in the addon's classic style) -----------------------
Profile.EMBLEMS = {
    { id = "king", label = "King", piece = 6, group = "Chess pieces" },
    { id = "queen", label = "Queen", piece = 5, group = "Chess pieces" },
    { id = "rook", label = "Rook", piece = 4, group = "Chess pieces" },
    { id = "bishop", label = "Bishop", piece = 3, group = "Chess pieces" },
    { id = "knight", label = "Knight", piece = 2, group = "Chess pieces" },
    { id = "pawn", label = "Pawn", piece = 1, group = "Chess pieces" },
    { id = "alliance", label = "Alliance", atlas = "AllianceEmblem", group = "Factions" },
    { id = "horde", label = "Horde", atlas = "HordeEmblem", group = "Factions" },
}
Profile.EMBLEM_GROUPS = { "Chess pieces", "Factions", "Classes", "Races" }
do
    local classes = {
        { "warrior", "Warrior" }, { "paladin", "Paladin" }, { "hunter", "Hunter" }, { "rogue", "Rogue" },
        { "priest", "Priest" }, { "shaman", "Shaman" }, { "mage", "Mage" }, { "warlock", "Warlock" },
        { "druid", "Druid" }, { "deathknight", "Death Knight" }, { "monk", "Monk" },
        { "demonhunter", "Demon Hunter" }, { "evoker", "Evoker" },
    }
    for _, c in ipairs(classes) do
        Profile.EMBLEMS[#Profile.EMBLEMS + 1] = { id = "class-" .. c[1], label = c[2], atlas = "classicon-" .. c[1], group = "Classes" }
    end
    local races = {
        { "human", "Human" }, { "dwarf", "Dwarf" }, { "nightelf", "Night Elf" }, { "gnome", "Gnome" },
        { "orc", "Orc" }, { "undead", "Forsaken" }, { "tauren", "Tauren" }, { "troll", "Troll" },
    }
    for _, r in ipairs(races) do
        for _, sex in ipairs({ { "male", "male" }, { "female", "female" } }) do
            Profile.EMBLEMS[#Profile.EMBLEMS + 1] = {
                id = "race-" .. r[1] .. "-" .. sex[1], label = r[2] .. " (" .. sex[2] .. ")",
                atlas = "raceicon128-" .. r[1] .. "-" .. sex[1], group = "Races",
            }
        end
    end
end
Profile.FRAMES = {
    { id = "gold", label = "Gold", color = { 1.0, 0.82, 0.0 } },
    { id = "silver", label = "Silver", color = { 0.80, 0.82, 0.88 } },
    { id = "bronze", label = "Bronze", color = { 0.85, 0.52, 0.25 } },
    { id = "alliance", label = "Alliance", color = { 0.35, 0.58, 1.0 } },
    { id = "horde", label = "Horde", color = { 0.95, 0.25, 0.18 } },
}
Profile.BACKDROPS = {
    { id = "wood", label = "Wood" },
    { id = "green", label = "Tournament" },
    { id = "slate", label = "Slate" },
    { id = "stone", label = "Stone" },
}

local function byId(list, id)
    for _, e in ipairs(list) do if e.id == id then return e end end
    return list[1]
end
function Profile.Emblem(id) return byId(Profile.EMBLEMS, id) end
function Profile.Frame(id) return byId(Profile.FRAMES, id) end
function Profile.Backdrop(id) return byId(Profile.BACKDROPS, id) end

-- Text other players typed: no escape sequences (links, textures, colors),
-- no control characters, bounded length.
function Profile.Sanitize(text, maxLen)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|", ""):gsub("[%c]", " "):gsub("~", "-")
    text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    if #text > maxLen then text = text:sub(1, maxLen) end
    -- don't leave half of a multi-byte character at the end
    text = text:gsub("[\192-\255][\128-\191]*$", function(tail)
        local lead = tail:byte(1)
        local need = (lead >= 240) and 4 or (lead >= 224) and 3 or 2
        return (#tail == need) and tail or ""
    end)
    return text
end

-- my card ---------------------------------------------------------------------------------
function Profile:Data() return ns.db.char.profile end

-- highest bot level beaten (0 = none)
function Profile:BestBot()
    local best = 0
    for id, s in pairs(ns.db.char.stats.bots) do
        local p = ns.Bots.Get(id)
        if p and (s.w or 0) > 0 and p.level > best then best = p.level end
    end
    return best
end

function Profile:Mine()
    local d = self:Data()
    return {
        name = Names.Me(), mine = true,
        rating = d.rating, games = d.games, w = d.w, l = d.l, d = d.d, peak = d.peak,
        emblem = d.emblem, frame = d.frame, backdrop = d.backdrop,
        title = d.title, motto = d.motto, bestBot = self:BestBot(),
    }
end

-- Returns true when saved, or false plus a reason (e.g. blocked words).
function Profile:Customize(key, value)
    local d = self:Data()
    if key == "title" or key == "motto" then
        value = Profile.Sanitize(value, (key == "title") and TITLE_MAX or MOTTO_MAX)
        if ns.WordFilter.IsBlocked(value) then
            return false, "That " .. key .. " contains words that aren't allowed on Chess Craft cards."
        end
    elseif key == "emblem" then value = Profile.Emblem(value).id
    elseif key == "frame" then value = Profile.Frame(value).id
    elseif key == "backdrop" then value = Profile.Backdrop(value).id
    else return false end
    if d[key] == value then return true end
    d[key] = value
    ns:Fire("PROFILE_CHANGED", Names.Me())
    return true
end

-- Text received from another player: hidden if it fails the word filter.
local function cleanRemote(text, maxLen)
    text = Profile.Sanitize(text, maxLen)
    if ns.WordFilter.IsBlocked(text) then return "" end
    return text
end

-- other players' cards ----------------------------------------------------------------------
function Profile:Get(name)
    if not name then return nil end
    if Names.IsMe(name) then return self:Mine() end
    for n, card in pairs(self.cache) do
        if Names.Same(n, name) then return card end
    end
    return nil
end

function Profile:Request(name)
    if not name or Names.IsMe(name) then return end
    Comm:Send(name, "PQ", CARD_VERSION)
end

local function encodeCard(c)
    return CARD_VERSION, c.rating, c.games, c.w, c.l, c.d, c.peak, c.emblem, c.frame, c.backdrop,
        c.bestBot or 0, c.title or "", c.motto or ""
end

local function decodeCard(sender, f)
    local n = function(i, default) return tonumber(f[i]) or default end
    local rating = n(2)
    if not rating then return nil end
    return {
        name = sender, at = now(),
        rating = math.max(Rating.FLOOR, math.min(4000, math.floor(rating))),
        games = math.max(0, n(3, 0)), w = math.max(0, n(4, 0)), l = math.max(0, n(5, 0)), d = math.max(0, n(6, 0)),
        peak = n(7, rating),
        emblem = Profile.Emblem(f[8]).id, frame = Profile.Frame(f[9]).id, backdrop = Profile.Backdrop(f[10]).id,
        bestBot = math.max(0, math.min(8, n(11, 0))),
        title = cleanRemote(f[12], TITLE_MAX), motto = cleanRemote(f[13], MOTTO_MAX),
    }
end

-- rating ---------------------------------------------------------------------------------------
local function liveOpponentRating(g)
    if g.extra and g.extra.oppRating then return g.extra.oppRating end
    local card = ns.Live and Profile:Get(ns.Live.opp)
    return card and card.rating or nil
end

function Profile:OnLiveStarted(g)
    if not g or g.mode ~= "live" or g.result then return end
    g.extra = g.extra or {}
    g.extra.myRating = g.extra.myRating or self:Data().rating
    local opp = ns.Live.opp
    local tries = 0
    local function ask()
        if ns.Live.game ~= g or g.result or g.extra.oppRating then return end
        tries = tries + 1
        self:Request(opp)
        if tries < START_QUERY_TRIES then C_Timer.After(START_QUERY_GAP, ask) end
    end
    ask()
end

function Profile:OnGameEnded(g)
    if not g or g.mode ~= "live" or not g.result then return end
    local d = self:Data()
    if d.rated[g.id] then return end
    local outcome = g:Outcome(g.localColor)
    if outcome == "aborted" or outcome == nil then return end
    local score = (outcome == "win") and 1 or (outcome == "draw") and 0.5 or 0
    local opp = liveOpponentRating(g) or Rating.START
    local new, change = Rating.Update(d.rating, d.games, opp, score)
    d.rating = new
    d.games = d.games + 1
    if outcome == "win" then d.w = d.w + 1 elseif outcome == "loss" then d.l = d.l + 1 else d.d = d.d + 1 end
    if new > d.peak then d.peak = new end
    d.rated[g.id] = ns.Clock.server()
    d.ratedCount = (d.ratedCount or 0) + 1
    if d.ratedCount > RATED_MEMORY then
        -- forget the oldest game ids
        local list = {}
        for id, t in pairs(d.rated) do list[#list + 1] = { id = id, t = t } end
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = RATED_MEMORY + 1, #list do d.rated[list[i].id] = nil end
        d.ratedCount = math.min(#list, RATED_MEMORY)
    end
    g.extra = g.extra or {}
    g.extra.ratingChange = change
    ns.Print("Rating: %d (%s%d).", new, change >= 0 and "+" or "", change)
    ns:Fire("PROFILE_CHANGED", Names.Me())
end

-- network -------------------------------------------------------------------------------------
function Profile:OnEnable()
    local lastReply = {}
    Comm:Register("PQ", function(sender)
        local t = now()
        if lastReply[sender] and t - lastReply[sender] < REPLY_GAP then return end
        lastReply[sender] = t
        Comm:Send(sender, "PF", encodeCard(self:Mine()))
    end)
    Comm:Register("PF", function(sender, f)
        local card = decodeCard(sender, f)
        if not card then return end
        self.cache[sender] = card
        local g = ns.Live and ns.Live.game
        if g and not g.result and Names.Same(ns.Live.opp, sender) then
            g.extra = g.extra or {}
            if not g.extra.oppRating then
                g.extra.oppRating = card.rating
                ns.Live:Save()
            end
        end
        ns:Fire("PROFILE_CHANGED", sender)
    end)

    ns:On("GAME_STARTED", function(g)
        if g and g.mode == "live" then Profile:OnLiveStarted(g) end
    end)
    ns:On("GAME_ENDED", function(g) Profile:OnGameEnded(g) end)

    -- forget stale cards now and then
    C_Timer.NewTicker(60, function()
        local cutoff = now() - CACHE_TTL
        for n, card in pairs(self.cache) do
            if (card.at or 0) < cutoff then self.cache[n] = nil end
        end
    end)

    -- a live game restored at login started before this module was listening
    if ns.Live and ns.Live.game and not ns.Live.game.result then self:OnLiveStarted(ns.Live.game) end
end

return Profile
