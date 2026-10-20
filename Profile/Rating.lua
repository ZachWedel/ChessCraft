--[[
    Chess Craft - Profile/Rating.lua
    Elo rating for live games between players.

    Every player starts at 1200. A game moves your rating by
        K * (score - expected),  expected = 1 / (1 + 10^((opponent - you) / 400))
    with K = 40 for your first 20 rated games (so new players find their level
    quickly) and K = 20 after that. A rating is shown as provisional ("?") for
    the first 10 games. Each client works out its own player's rating from the
    opponent's rating at the start of the game, so both sides agree.
]]

local _, ns = ...

local Rating = {}
ns.Rating = Rating

Rating.START = 1200
Rating.FLOOR = 100
Rating.FAST_K_GAMES = 20
Rating.PROVISIONAL_GAMES = 10

function Rating.Expected(rating, opponent)
    return 1 / (1 + 10 ^ ((opponent - rating) / 400))
end

function Rating.K(games)
    return (games < Rating.FAST_K_GAMES) and 40 or 20
end

-- score: 1 win, 0.5 draw, 0 loss. Returns the new rating and the change.
function Rating.Update(rating, games, opponent, score)
    local new = rating + Rating.K(games) * (score - Rating.Expected(rating, opponent))
    new = math.floor(new + 0.5)
    if new < Rating.FLOOR then new = Rating.FLOOR end
    return new, new - rating
end

function Rating.IsProvisional(games)
    return (games or 0) < Rating.PROVISIONAL_GAMES
end

function Rating.Format(rating, games)
    if not rating then return "?" end
    return tostring(rating) .. (Rating.IsProvisional(games) and "?" or "")
end

return Rating
