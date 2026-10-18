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
- **Lap splits (v0.4.0):** on each lap edge `gameTime{}` sets Game Time to
  `LapStartServerTime` (new stamp) − `RaceStartTime`, which also re-syncs the live display each
  lap. Skipped (falls back to real time) if the stamp didn't move that tick or the value is more
  than 0.5 s from the running Game Time. Debug output prints the correction per lap and, at the
  finish, `stamp − RaceStartTime` next to `EventFinishTime` to confirm the base.
  - **Verified in Race Mode (2026-10-17, 2 laps):** `RaceStartTime` is the countdown end
    (7113.0631); the first line crossing came 2.35 s later and is not the base. Lap edge:
    stamp − `RaceStartTime` = 15.3607 vs running Game Time 15.3539 → +6.7 ms correction applied.
    Finish: stamp − `RaceStartTime` = 26.31217 = `EventFinishTime` (26.31217), so the game's
    finish time is also measured from the countdown end.
  - **Verified in Arcade (2026-10-17):** lap splits and final time correct.
- **Rules question for the mods:** a crash before the line plays a slow-mo cinematic and the run
  still counts. In one run `EventFinishTime` was 14.33 but Real Time was 17.285, so Game Time and
  Real Time can differ by seconds.
- **Precision Driving** will need this anyway (`BonusTime` 0xF4, gate bonuses).
- **Status:** final time fixed in v0.3.0 (Arcade and Race verified). Lap splits exact in v0.4.0 (Arcade and Race verified); live display still jitters between lap crossings.

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
- **Cause (confirmed 2026-10-17, Debug log of a restart):** during teardown the pointer chains
  flicker between 0 and the **dead race's memory**, which replays its values: `raceStarted` 0→1,
  `playerLap` 0→1 with `totalLaps` 4, `hudVM` defined — enough to pass the Arcade start
  (`LapsSane` + `playerLap` 0→1 + `finished == 0`). The Race start wouldn't have fired because `playerLap`
  was already 1, but nothing stopped it in principle. Tell-tale: the replayed
  `LapStartServerTime` / `RaceStartTime` are **identical** to the torn-down race's
  (7614.48608680475 every time), while a real start always brings a new timestamp.
- **Fix (v0.4.1):** `update{}` remembers the torn-down race's `LapStartServerTime` (on
  `playerLap` ≥1→0) and `RaceStartTime` (on `raceStarted` 1→0). The Arcade start is rejected if
  `LapStartServerTime` equals the dead one; the Race start if `RaceStartTime` does. Debug output
  prints `start rejected: …` when it happens. Verified 2026-10-17: no false starts on
  restart / exit. Relevant for Scenarios later: transitions between races go through the
  same teardown.
- **Status:** fixed in v0.4.1.
