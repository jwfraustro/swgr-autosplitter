# Star Wars: Galactic Racer Autosplitter

LiveSplit autosplitter for speedrunning Star Wars: Galactic Racer.

## Status

`SWGR_Autosplitter.asl` — v0.4.1, single races (IL). Offsets are hard-coded for the
current build (`GWorld` = exe+0xADFF928) and will break when the game patches.

`SWGR_Autosplitter_Refactor.asl` — 0.5.0-dev, the category-based rewrite (see `REFACTOR.md`).
IL categories (Time Trial, Precision) are meant to match v0.4.1. Arcade% and the campaign
categories start the timer when you leave the menu, split on every finish and never
auto-reset; Arcade% has its end condition, the campaign categories still need the final events'
names. Scenarios start on the first race's go, keep Game Time paused outside a live race, split
on every lap and finish and have no end condition (your last split ends the run).
**Nothing in it is tested in LiveSplit yet.** Keep using v0.4.1 until it is.

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
