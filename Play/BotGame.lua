--[[
    Chess Craft - Play/BotGame.lua
    Games against the bots. They can be paused and resumed at any time,
    are saved after every move (so they survive /reload, logout and
    crashes), and several can be kept in progress at once.
]]

local _, ns = ...
local Game, Bots, Compat, Names = ns.Game, ns.Bots, ns.Compat, ns.Names

local BotGame = ns:NewModule("BotGame")

local SLICE_MS = { smooth = 3, balanced = 6, fast = 12 }
local COMBAT_SLICE_MS = 2

local function persona(game)
    local bot = game.players[3 - game.localColor]
    return Bots.Get(game.extra.botId or (bot and bot.botId) or 1)
end

function BotGame:IsActive() return self.game ~= nil and not self.game.result end
function BotGame:IsPaused() return self.paused or self.combatPaused end

local function pickColor(choice)
    if choice == "white" or choice == 1 then return 1 end
    if choice == "black" or choice == 2 then return 2 end
    return math.random(1, 2)
end

-- Start a new game against a bot (level 1-8 or persona id).
function BotGame:StartNew(levelOrId, colorChoice, startFEN)
    if ns.Live and ns.Live:IsActive() then
        ns.Print("Finish or leave your live game before starting a bot game.")
        return nil
    end
    self:Detach(true)
    local p = Bots.Get(levelOrId) or Bots.Get(3)
    local color = pickColor(colorChoice)
    local me = { name = Names.Me(), kind = "human" }
    local bot = { name = p.name, kind = "bot", botId = p.id }
    local ok, game = pcall(Game.new, {
        mode = "bot",
        white = (color == 1) and me or bot,
        black = (color == 2) and me or bot,
        localColor = color,
        startFEN = startFEN,
        extra = { botId = p.id },
    })
    if not ok then ns.Print("Could not start the game: %s", tostring(game)); return nil end
    ns.db.char.lastBot = p.level
    ns.db.char.lastColor = (colorChoice == 1 and "white") or (colorChoice == 2 and "black") or colorChoice or "random"
    self:Attach(game)
    self:Save()
    Compat.PlaySound("start")
    ns:Fire("GAME_STARTED", game)
    self:Say("greet")
    return game
end

-- Resume a saved game by id (or the most recent one).
function BotGame:Resume(id)
    if ns.Live and ns.Live:IsActive() then
        ns.Print("Finish or leave your live game first.")
        return nil
    end
    local t = id and ns.db.char.botGames[id]
    if not t then return nil end
    if self.game and self.game.id == id then
        self:SetPaused(false)
        ns:Fire("GAME_STARTED", self.game)
        return self.game
    end
    self:Detach(true)
    local ok, game = pcall(Game.Deserialize, t)
    if not ok or not game then
        ns.Print("That saved game could not be loaded and was removed.")
        ns.Database.DeleteBotGame(id)
        return nil
    end
    if game.corrupt then ns.Print("Part of that saved game was damaged; resuming from the last valid move.") end
    self:Attach(game)
    ns:Fire("GAME_STARTED", game)
    if not game.result then self:Say("greet") end
    return game
end

function BotGame:ResumeLatest()
    local id = ns.db.char.lastBotGame
    if not (id and ns.db.char.botGames[id]) then
        local list = ns.Database.ListBotGames()
        id = list[1] and list[1].id
    end
    if not id then
        ns.Print("You have no saved bot games. Start one with /chess bot <1-8>.")
        return nil
    end
    return self:Resume(id)
end

function BotGame:Attach(game)
    self.game = game
    self.persona = persona(game)
    self.controller = Bots.NewController(self.persona)
    self.paused = false
    self.combatPaused = false
    ns.activeGame = game
    ns.db.char.lastBotGame = game.id
    ns:SetUpdater("botgame", function() self:OnUpdate() end)
end

-- Stop driving the current game (it stays saved unless finished).
function BotGame:Detach(save)
    if not self.game then return end
    if self.controller then self.controller:Cancel() end
    if save then self:Save() end
    if ns.activeGame == self.game then ns.activeGame = nil end
    self.game, self.controller, self.persona = nil, nil, nil
    ns:SetUpdater("botgame", nil)
    ns:Fire("BOT_THINKING", false)
    -- give memory back if nobody plays for a while
    C_Timer.After(60, function()
        if not BotGame.game then Bots.ReleaseMemory() end
    end)
end

function BotGame:OnUpdate()
    local g = self.game
    if not g or g.result or self.paused then return end
    local inCombat = Compat.InCombat()
    if inCombat and ns.db.settings.pauseBotInCombat then
        if not self.combatPaused then
            self.combatPaused = true
            ns:Fire("GAME_UPDATED", g)
        end
        return
    elseif self.combatPaused then
        self.combatPaused = false
        ns:Fire("GAME_UPDATED", g)
    end
    if g.board.side == g.localColor then return end
    local c = self.controller
    if c.state == "idle" then
        c:Start(g)
        ns:Fire("BOT_THINKING", true)
    end
    local slice = inCombat and COMBAT_SLICE_MS or (SLICE_MS[ns.db.settings.botSpeed] or 6)
    local uci = c:Update(slice)
    if uci then self:ApplyBotMove(uci) end
end

-- moves --------------------------------------------------------------------------
function BotGame:CanHumanMove()
    local g = self.game
    return g ~= nil and not g.result and not self.paused and g.board.side == g.localColor
end

function BotGame:HumanMove(uci)
    if not self:CanHumanMove() then return false, "not your turn" end
    local info, err = self.game:Move(uci)
    if not info then return false, err end
    self:AfterMove(info, true)
    return true
end

function BotGame:ApplyBotMove(uci)
    local g = self.game
    local info = g and g:Move(uci)
    ns:Fire("BOT_THINKING", false)
    if not info then
        ns.Debug("bot produced an illegal move %s", tostring(uci))
        return
    end
    self:AfterMove(info, false)
end

local BIG_PIECE = { [2] = true, [3] = true, [4] = true, [5] = true }

function BotGame:AfterMove(info, byHuman)
    local g = self.game
    if info.check then Compat.PlaySound("check")
    elseif info.capture then Compat.PlaySound("capture")
    else Compat.PlaySound("move") end

    if not g.result then
        local capturedType = info.captured and ns.ChessTables.TYPE[info.captured] or 0
        if byHuman and BIG_PIECE[capturedType] and math.random() < 0.35 then
            self:Say("lostPiece")
        elseif not byHuman and info.check and math.random() < 0.4 then
            self:Say("check")
        elseif not byHuman and BIG_PIECE[capturedType] and math.random() < 0.35 then
            self:Say("capture")
        end
    end

    self:Save()
    ns:Fire("GAME_UPDATED", g, info)
    if g.result then self:OnFinished() end
end

function BotGame:OnFinished()
    local g = self.game
    if not g then return end
    if self.controller then self.controller:Cancel() end
    local outcome = g:Outcome(g.localColor)
    if outcome == "win" then self:Say("lose")
    elseif outcome == "loss" then self:Say("win")
    elseif outcome == "draw" then self:Say("draw") end
    ns.Database.AddHistory({
        id = g.id, date = ns.Clock.server(), mode = "bot",
        opponent = self.persona and self.persona.name, botId = self.persona and self.persona.id,
        myColor = g.localColor, outcome = outcome, termination = g.termination,
        plies = g:Ply(), startFEN = (not g:IsStandardStart()) and g.startFEN or nil,
        moves = table.concat(g.moves, " "), result = g.result,
    })
    ns.Database.DeleteBotGame(g.id)
    Compat.PlaySound("finish")
    ns:Fire("GAME_ENDED", g)
end

-- controls ------------------------------------------------------------------------
function BotGame:SetPaused(paused)
    if not self.game or self.game.result then return end
    self.paused = paused and true or false
    self:Save()
    ns:Fire("GAME_UPDATED", self.game)
end

function BotGame:TogglePause() self:SetPaused(not self.paused) end

-- Take back the player's last move (and the bot's reply to it).
function BotGame:Undo()
    local g = self.game
    if not g or g:Ply() == 0 then return false end
    if self.controller then self.controller:Cancel() end
    ns:Fire("BOT_THINKING", false)
    local n = (g.board.side == g.localColor) and 2 or 1
    if g.result and g.board.side ~= g.localColor then n = 1 end
    if n > g:Ply() then n = g:Ply() end
    local wasOver = g.result ~= nil
    g:Undo(n)
    if wasOver then
        -- the game is open again: forget the recorded result
        ns.Database.RemoveHistory(g.id)
        ns.db.char.lastBotGame = g.id
    end
    self:Save()
    ns:Fire("GAME_UPDATED", g)
    return true
end

function BotGame:Resign()
    local g = self.game
    if not g or g.result then return end
    g:Resign(g.localColor)
    ns:Fire("GAME_UPDATED", g)
    self:OnFinished()
end

-- Keep the game in the saved list and close it.
function BotGame:SaveAndClose()
    if not self.game then return end
    local finished = self.game.result ~= nil
    self:Detach(not finished)
    ns:Fire("GAME_CLOSED")
end

function BotGame:Delete(id)
    if self.game and self.game.id == id then self:Detach(false) end
    ns.Database.DeleteBotGame(id)
    ns:Fire("SAVED_GAMES_CHANGED")
end

function BotGame:Save()
    local g = self.game
    if not g or g.result then return end
    local t = g:Serialize()
    t.extra = t.extra or {}
    t.extra.botId = self.persona and self.persona.id
    t.extra.paused = self.paused
    ns.Database.SaveBotGame(t)
end

function BotGame:Say(event)
    if not (ns.db.settings.showQuips and self.persona) then return end
    local line = Bots.Quip(self.persona, event)
    if line then ns:Fire("BOT_QUIP", self.persona, line, event) end
end

function BotGame:OnEnable()
    ns:On("LOGOUT", function() BotGame:Save() end)
end

return BotGame
