# Changelog

## 0.3.1

- Watch games: players in a match show a Watch button on the Play tab (or use
  /chess watch <name>). You follow the game live on your board with both
  clocks, through either player, and can stop watching any time. Watching
  never touches your history or rating.
- Spectator chat: a chat window docked beside the board for everyone watching
  the game (from both players' sides), with the list of who is watching.
  Messages go through the word filter. The players see how many people are
  watching and who, but never the chat.
- New setting: who can watch my games (everyone, friends and guild, or nobody).
- Players in a match can't be challenged any more, whether from the list, the
  name box or /chess challenge; you're offered Watch instead. Lobbies learn
  the moment someone starts or finishes a match.
- Chess Craft players nearby only lists players whose addon has answered.
- More emblems for your card: all 13 class icons and the race portraits of the
  original eight races (male and female), in a new Choose an emblem window
  that opens beside your card.
- Every bot has its own piece set in the classic style: candle wax (Kobold),
  sea scales (Murloc), timber (Peon), brass (Tinker), granite (Mountaineer),
  bone and plague green (Apothecary), voodoo marble (Shadow Hunter) and arcane
  marble (Archmage). It can be turned off in Settings.
- Long bot names are no longer cut short beside the board.
- Plays with 0.2.x and 0.3.0. Games can be watched through players on 0.3.1.

## 0.3.0

- Player cards: a new Profile tab with your card (rating, best rating, record,
  best bot beaten) and a title, motto, emblem, frame and background you choose.
- Rating for games against players (everyone starts at 1200; bot games and
  aborted games don't count), shown on cards, in the Play tab, in challenge
  pop-ups, on the board during a game, and after each game.
- See anyone's card with the Card button on the Play tab, or by clicking their
  name on the board.
- Word filter on card titles and mottos: profanity, slurs and abusive phrases
  are refused when typed and hidden if they arrive on someone else's card.
- Friends with Chess Craft are found reliably: names from the friends list are
  turned into the form the game needs for whispers, Battle.net friends playing
  WoW: Forever are included, friends who log in are picked up automatically,
  and every time you open the window Chess Craft re-checks who is online with
  the addon (players who have logged off drop off the list).
- "Friends only" challenge setting now counts Battle.net friends.
- Plays with 0.2.x: card messages are new and ignored by older versions.

## 0.2.0

- Fixed: accepting a challenge could tell the challenger's client the accept
  was "stale" when the server wrote the player's name differently from how it
  was typed (e.g. with a realm suffix). The challenger then cancelled, the
  other player saw "withdrew the challenge" and nothing started. Challenges are
  now matched by their id, and the name the server reports becomes the
  opponent's name for the rest of the game.
- Sending a challenge takes you to the board: "Waiting for <name>", then
  "<name> has your challenge", then "<name> accepted! The match starts in 3...".
  The player who accepts sees "Get ready!" until the game begins.
- The handshake is reliable: challenges are re-sent until answered, the
  receiver confirms receipt, and acceptances are re-sent until the game starts,
  so a lost whisper no longer leaves either side hanging.
- Clicking Send twice re-sends the same challenge instead of cancelling it.
- Declines, cancels, timeouts and offline players are explained on the board.
- New classic-style addon icon (gilded knight).
- Protocol 2: both players need Chess Craft 0.2.0 or later; older versions get
  a clear "please update" message.

## 0.1.0 (first release, for WoW: Forever 1.60.1 / interface 16001)

- Full rules of chess: castling, en passant, promotion with a piece picker,
  check, mate, stalemate, threefold repetition, fifty-move rule, insufficient
  material. The move generator is verified against the standard perft suite.
- Eight bots, Kobold Candle-Snatcher (level 1) to Archmage of Dalaran (level 8),
  each with a portrait, a playing style and things to say. Bots think a little
  each frame, so the game never stutters, and can be paused, closed, resumed
  and taken back at any time. Games are saved after every move.
- Live games between players over addon whispers:
  - time controls from 1+0 bullet to 30+0 classical, or untimed;
  - timed games keep the clock running; after 60 seconds without a word from
    the opponent you may claim the win or keep waiting;
  - untimed games survive logouts and continue when both players are online;
    leaving aborts the game before both sides have moved and counts as a loss
    afterwards;
  - draw offers, resign, abort, rematch;
  - moves are acknowledged and re-sent until they arrive, and a game in
    progress resynchronises itself after a /reload or disconnect;
  - works within Midnight-era addon restrictions (secret chat values, chat
    lockdown in instances and encounters, trial accounts).
- Peggle-style window: Play (bots, saved games, challenges, players nearby),
  Game, History (record, review, PGN export) and Settings.
- Classic pieces on wood, tournament green or slate boards, or Alliance vs Horde
  pieces on stone.
- Minimap button, addon compartment entry, Options panel, slash commands.
