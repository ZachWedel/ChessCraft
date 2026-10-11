# Changelog

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
