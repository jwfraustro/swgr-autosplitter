# Known bugs

Open issues with the autosplitter. Dev-facing; background on the values involved is in
`NOTES.md`.

## 1. Final time ~0.01–0.03 s off the results screen

- **Seen:** v0.1.0–v0.2.0, Arcade. LiveSplit's Real Time differs from the in-game results screen
  by a few hundredths, sign varies run to run (+0.015, +0.008, −0.013 s on 1-lap time trials).
- **Cause (confirmed 2026-10-17, `SWGR_FinishDebug.asl`):** polling jitter, not a late trigger.
  - `bHasFinishedEvent` 0→1 and `EventFinishTime` −1→final land on the **same tick**; switching
    the split trigger changes nothing.
  - `EventFinishTime` = difference of the game's `LapStartServerTime` stamps at the start and
    finish crossings (3837.7807 − 3823.4697 = 14.3110 = results screen). In Arcade,
    `RaceStartTime` equals the first-crossing stamp.
  - Our start and finish edges are each seen up to one poll (~17 ms at 60 Hz) after the game's
    crossing, so Real Time is off by up to about ±1 tick.
  - `ReplicatedWorldTimeSecondsDouble` (GameState 0x2E0) lags the crossing stamps (read
    3837.7454 vs 3837.7807 on the finish tick) — not usable as a live game clock.
    `URaceEventVM.CurrentEventTime` at 0x188 read garbage (wrong offset or type).
- **Fix (v0.3.0):** Game Time runs with real time, then `gameTime{}` sets it to `EventFinishTime`
  on the finish tick and `isLoading{}` freezes it, so the finish split's Game Time is the
  results-screen time. Real Time is unchanged (still has the jitter). Compare against
  **Game Time** in LiveSplit.
- **Verified (2026-10-17):** multi-lap Arcade run: lap splits fire correctly and the final Game
  Time matches the results screen to the millisecond, including a run with a mid-race crash
  (slow-mo crash sequence: Real Time ran ~2 s ahead, Game Time still ended on the race result).
- **Verified (2026-10-17), Race Mode:** start fires at the countdown end, splits fire correctly,
  final Game Time matches the in-game timer.
- **Known, accepted:** before the finish, Game Time just follows real time, so the live display
  (and lap splits) still has the polling jitter — frame-by-frame vs the in-game timer it reads
  high or low by up to a few tens of ms. Only the finish value is exact. A live game-driven clock
  would need a non-stale game time source (see `ReplicatedWorldTimeSecondsDouble` above).
- **Possible follow-up:** exact lap splits, by setting Game Time on each lap edge to
  `LapStartServerTime` (new stamp) − the start stamp.
- **Rules question for the mods:** a crash before the line plays a slow-mo cinematic and the run
  still counts. In one run `EventFinishTime` was 14.33 but Real Time was 17.285, so Game Time and
  Real Time can differ by seconds.
- **Precision Driving** will need this anyway (`BonusTime` 0xF4, gate bonuses).
- **Status:** fixed in v0.3.0 for the final time (Arcade and Race verified). Live display / lap-split jitter remains.

## 2. Exiting a race: reset → false start → reset

- **Seen:** v0.2.0, Arcade. After clicking **Exit to Main Menu**:
  1. the timer resets immediately (expected);
  2. it briefly **starts again** during the black loading screen;
  3. it resets again once the main menu loads.
  Net effect in Arcade is nothing (the timer ends up reset), but it means the start logic fires
  on garbage during level transitions.
- **Why it matters:** Scenarios chain 5 races with loading screens / transitions between them.
  A spurious start or reset there would wreck a run, and if loads end up being timed we can't
  just ignore the transition.
- **Suspected cause (unconfirmed):** the Arcade start is deliberately *not* gated on the HUD VM
  (that was the v0.2.0 fix for the flaky start — see `NOTES.md`), only on `LapsSane` + `playerLap` 0→1 +
  `finished == 0`. During world teardown / load, the `GWorld → GameState → …` chains likely read
  stale or reused memory (or the old/new world's GameState), and `playerLap` going 0→1 with a
  plausible `totalLaps` is enough to fire. Second reset is then `hudVM`/`playerLap` dropping again.
- **To investigate:** run with the **Debug** setting on and capture the DbgView log across an
  exit; record which values flip and in what order. Then consider gating on something that is
  definitely "in a live race" without needing the HUD VM — e.g. the race state machine
  (`Racing` / `RollingStart`), the GameState class, or `RaceStartTime` / world identity being
  unchanged since the previous tick.
- **Status:** open.
