# Star Wars: Galactic Racer Autosplitter

LiveSplit autosplitter for speedrunning Star Wars: Galactic Racer.

## Status

**v0.5.0** supports:
- Arcade Time Trials
- Precision Driving
- Arcade Scenarios


## Installation (automatic)

This autosplitter is automatically available through Livesplit, and can be activated when setting up your game / splits.

- Click "Edit Splits"
- Enter "Star Wars: Galactic Racer" in the "Game Name:", or select it from the dropdown menu.
- When the autosplitter button populates, hit "Activate".
- You can then pick your category and split options by pressing "Settings".

## Installation (manual)

Download `SWGR_Autosplitter.asl` anywhere on your computer.

In LiveSplit: Edit Layout → `+` → Control → Scriptable Auto Splitter, then point it at
`SWGR_Autosplitter.asl`. You can then pick your individual settings.

# Options
- **Category** (One) - The speedrun category you're playing. This changes how the first split happens, and how the time is tracked.
  - **Arcade - Time Trial** - A simple circuit run, times are based on IGT.
  - **Arcade - Precision Driving** - Drive through checkpoints to reduce your time. Switch IGT to see the time deductions live!
  - **Arcade Scenarios** - A series of 5 challenge runs as a particular character. The submission grading is the sum of all the IGT per run.
    - The autosplitter will automatically keep track of the total, switch your splits/timer to Game Time to see it.
- **Splits** - Options for when the autosplitter should start a new timed section. You can pick more than one, just make sure to have enough splits in your layout to capture them all.
  - **Per lap** - a new split is triggered for every lap of every race, best for IL runs.
  - **Per race/event** - split once at the end of each race, great for scenarios or Arcade%
  - **Run's final finish** - for categories like the campaign runs, where you want to define your own splits, and only auto-split on the very last race of the category.
- **Auto Reset** - whether to restart the timer automatically when you quit or retry. *This is only for Time Trial and Precision Driving! Even if you have it enabled during a campaign run, it won't fire! We don't want to accidentally kill a full run!*

