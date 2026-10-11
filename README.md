# Chess Craft

Chess for **World of Warcraft: Forever**. Challenge other players to a game, live, with a chess clock or untimed, or take on eight bots from Azeroth, from a candle-grabbing Kobold to an Archmage of Dalaran.

Inspired by the way PopCap's Peggle addon worked: one window, a menu of opponents, quick duels with anyone who has the addon, and a game you can pick up whenever you have a minute.

## Installing

1. Close the game.
2. Extract the `ChessCraft` folder from the zip into your WoW: Forever AddOns folder:
   `World of Warcraft\<WoW Forever client folder>\Interface\AddOns\`
   The client folder is the one the Battle.net app created for WoW Forever (the beta used `_forever_beta_`). After extracting you should have `...\Interface\AddOns\ChessCraft\ChessCraft.toc`.
3. Start the game and check **Chess Craft** is ticked in the AddOns list on the character screen.

Chess Craft is built for the WoW: Forever client (interface 16001, patch 1.60.1). If Blizzard raises the interface number in a later patch before an update is out, tick **Load out of date AddOns** on the AddOns screen.

## Playing

Open the window with `/chess`, the minimap button, or the AddOns menu on the minimap.

**Against a bot (Play tab, left).** Pick an opponent, choose White, Black or Random, and press **Play** (or double-click the bot). Bot games:

- can be **paused** and resumed at any time (Pause button);
- are **saved after every move**, so you can press **Close**, log out, `/reload` or even crash and carry on later from **Saved games** (up to 20 at once);
- allow **Take back** (your move and the bot's reply);
- pause on their own while you are in combat (can be turned off).

| Level | Opponent | Plays like |
|---|---|---|
| 1 | Kobold Candle-Snatcher | ~250 |
| 2 | Murloc Tidehunter | ~450 |
| 3 | Peon Foreman | ~650 |
| 4 | Gnomish Tinker | ~850 |
| 5 | Dwarven Mountaineer | ~1050 |
| 6 | Forsaken Apothecary | ~1300 |
| 7 | Darkspear Shadow Hunter | ~1550 |
| 8 | Archmage of Dalaran | ~1800 |

The ratings are rough guides, not measured Elo.

**Against a player (Play tab, right).** Your opponent needs Chess Craft too. Type a name (or press **Use target**), choose a time control and your color, and press **Send challenge**. Guildmates, group members and online friends who have the addon are listed under *Chess Craft players nearby* with their own **Challenge** button. Incoming challenges pop up with **Accept / Decline / Later**.

- **Timed games** (1+0 up to 30+0) are played on the clock: the clock does not stop. Your first move and your opponent's first move are free; the clock starts after that. If your opponent goes silent, their clock keeps running, and after 60 seconds you can **Claim** the win or keep waiting.
- **Untimed games** have no clock. The game is saved and continues whenever you are both online, even days later. To end one early you have to finish it or **Leave**: leaving before both sides have moved simply cancels the game; leaving later counts as a loss.
- You can offer and accept draws, resign, and abort a game before it really starts.

**Moving pieces.** Click a piece and then a square, or drag it. Legal moves are marked with dots (rings for captures). The mouse wheel over the board, or the `<<  <  >  >>` buttons, steps through the game.

**History tab.** Your last 100 finished games and your record. **Review** replays a game on the board; **PGN** gives you the game in standard notation to paste into any chess website or program.

**Settings.** Classic pieces on wood, tournament green or slate, or the **Alliance vs Horde** set on stone; coordinates, move highlights, animation, auto-queen, sounds, bot chatter, who may challenge you, window size and more. The same settings are also under *Options > AddOns > Chess Craft*.

## Commands

| Command | What it does |
|---|---|
| `/chess` | open or close the window |
| `/chess bot [1-8]` | start a game against a bot |
| `/chess resume` | resume your most recent bot game |
| `/chess challenge <name> [5+3 \| infinite]` | challenge a player |
| `/chess options` | settings |
| `/chess version` | version information |

`/chesscraft` works too.

## Good to know

- **Dungeons, raids and encounters.** WoW: Forever uses the same addon rules as Midnight: inside restricted content, addon messages can be held back. Chess Craft queues your moves and sends them as soon as it's allowed; the game panel tells you when this happens. Bot games are not affected.
- **Trial accounts** can't send addon messages, so they can play the bots but not other players.
- Both players should run the same major version. If someone has a newer version, Chess Craft tells you, and incompatible versions decline each other's challenges with a message instead of failing silently.
- Names on WoW: Forever are first name plus surname; type them with a space ("Bob Ironforge") or a hyphen.

## Credits and license

Code: MIT license (see `LICENSE.txt`). Chess piece art by Colin M.L. Burnett, used under the BSD license (see `CREDITS.md`).
