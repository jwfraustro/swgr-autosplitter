# Star Wars: Galactic Racer Autosplitter

LiveSplit autosplitter for speedrunning Star Wars: Galactic Racer.

## Status

`SWGR_Autosplitter.asl` — v0.4.1, single races (IL). Offsets are hard-coded for the
current build (`GWorld` = exe+0xADFF928) and will break when the game patches.

`SWGR_Autosplitter_Refactor.asl` — 0.5.0-dev, the category-based rewrite (see `REFACTOR.md`).
IL categories (Time Trial, Precision) are meant to match v0.4.1. Run-length categories start
the timer when you leave the menu, split once per finished event and never auto-reset;
Arcade% and Scenarios have their end conditions, the campaign categories still need the final
events' names. **Nothing in it is tested in LiveSplit yet.** Keep using v0.4.1 until it is.

## Installation (manual)

In LiveSplit: Edit Layout → `+` → Control → Scriptable Auto Splitter, then point it at
`SWGR_Autosplitter.asl`. Settings appear in the component's settings page.

## Installation (automatic)

Once this autosplitter is incorporated into Livesplit, it will be available from the "Edit Splits" menu.

# Options
- **Start** (pick one): when the countdown ends and the race goes, *or* when the player first
  crosses the start/finish line.
- **Split** on each completed lap except the last, then on the finish (`LapCount` splits total).
- **Reset** when the race is restarted or the player quits out (not after a finished run).
- **Debug** option prints value changes to the debug log (view with DbgView).
- **Game Time** is set from the game's own timestamps at each lap crossing and at the finish
  (`EventFinishTime`), so splits match the in-game times; Real Time is off by up to one poll tick. No load removal yet.

See `NOTES.md` for the memory values and their status.
