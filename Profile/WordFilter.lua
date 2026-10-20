--[[
    Chess Craft - Profile/WordFilter.lua
    Keeps profanity, slurs and abusive phrases out of anything players type
    that other players will see (card titles and mottos).

    Text is normalized first: lower case, look-alike characters mapped back
    to letters (sh1t, a$$), punctuation inside words removed (f.u.c.k),
    spaced-out letters joined (f u c k), and repeated letters squeezed
    (fuuuck). Then whole words, pieces of words and two-word phrases are
    compared against hashes of the blocked list (Profile/WordFilterData.lua),
    so the addon never carries the words themselves.

    Some words are only blocked as whole words, so ordinary words that
    happen to contain them (class, grape, raccoon) stay allowed. Words that
    name groups of people are never blocked on their own; slurs are.
]]

local _, ns = ...

local Filter = {}
ns.WordFilter = Filter

local MOD = 2147483629
local LOOKALIKE = {
    ["0"] = "o", ["1"] = "i", ["3"] = "e", ["4"] = "a", ["5"] = "s", ["7"] = "t", ["8"] = "b",
    ["9"] = "g", ["@"] = "a", ["$"] = "s", ["!"] = "i", ["+"] = "t", ["("] = "c", ["<"] = "c",
}

local function hash(s, i, j)
    local h = 7
    for k = i or 1, j or #s do h = (h * 131 + s:byte(k)) % MOD end
    return h
end
Filter._hash = hash

-- "fuuuck" -> "fuck" (Lua patterns can't repeat a back-reference, so by hand)
local function squeeze(s)
    local out, last = {}, nil
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch ~= last then out[#out + 1] = ch end
        last = ch
    end
    return table.concat(out)
end

-- words of the text, normalized; spaced-out single letters joined together
function Filter.Words(text)
    text = tostring(text or ""):lower():gsub(".", function(ch) return LOOKALIKE[ch] end)
    local raw = {}
    for chunk in text:gmatch("%S+") do
        local letters = chunk:gsub("[^%a]", "")
        if letters ~= "" then raw[#raw + 1] = letters end
    end
    local words, run = {}, {}
    local function flush()
        if #run >= 3 then
            words[#words + 1] = table.concat(run)
        else
            for _, w in ipairs(run) do words[#words + 1] = w end
        end
        run = {}
    end
    for _, w in ipairs(raw) do
        if #w == 1 then run[#run + 1] = w else flush(); words[#words + 1] = w end
    end
    flush()
    return words
end

local function hasPiece(word, data)
    local n = #word
    for i = 1, n do
        local last = math.min(n, i + data.maxSub - 1)
        for j = i + data.minSub - 1, last do
            if data.sub[hash(word, i, j)] then return true end
        end
    end
    return false
end

local function wordBlocked(w, data)
    if data.word[hash(w)] then return true end
    -- plurals and simple endings: "tits", "rapes"
    if #w > 3 and w:sub(-1) == "s" and data.word[hash(w, 1, #w - 1)] then return true end
    if #w > 4 and w:sub(-2) == "es" and data.word[hash(w, 1, #w - 2)] then return true end
    return hasPiece(w, data)
end

-- true if the text contains anything on the blocked list
function Filter.IsBlocked(text)
    local data = ns.WordFilterData
    if not data or not text or text == "" then return false end
    local words = Filter.Words(text)
    for i, w in ipairs(words) do
        if wordBlocked(w, data) then return true end
        local sq = squeeze(w)
        if sq ~= w and wordBlocked(sq, data) then return true end
        local nextWord = words[i + 1]
        if nextWord then
            if data.phrase[hash(w .. " " .. nextWord)] then return true end
            if data.phrase[hash(sq .. " " .. squeeze(nextWord))] then return true end
        end
    end
    return false
end

return Filter
