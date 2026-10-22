# Known bugs

Open issues with the autosplitter. Dev-facing; addresses are in `MEMORY_OFFSETS.md`, behaviour in
`DEV_NOTES.md`.

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
- **Precision Driving:** lap splits need `BonusTime` taken off — see #7.
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

## 3. Elimination events fail the `LapsSane` gate (100 laps)

- **Seen:** found while verifying readings (2026-10-19), not yet seen in a run. Elimination
  campaign events report `LapCount` = 100 (GameState 0x370, also `URaceEventVM.NumLaps` and
  `FRaceEventInstance.LapCount`). The race actually runs until only the top 3 racers remain, and
  the HUD hides the lap total.
- **Cause:** v0.4.1 `vars.LapsSane` requires `totalLaps < 100`, so `InRace` is false for the
  whole event. Lap splits, the Race start and leave-race resets won't fire there.
- **Matters for:** campaign categories (Sebulba%, Any%, NG+), not the arcade ILs.
- **Fix (refactor, 2026-10-19):** bound is `0 < totalLaps <= 100` in `SWGR_Autosplitter_Refactor.asl`
  (`Snapshot` → `LapsSane`). v0.4.1 keeps the old bound. Still to check in-game: whether
  `bHasFinishedEvent` flips when the player is in the top 3 at the end, how `playerLap` behaves,
  and whether lap splits make sense there.
- **Status:** fixed in the refactor script, untested; open in v0.4.1.

# 4. Arcade%

- **Seen:** start when loading Super Surge, which might have the same track id as Landspeeder Ace. Not huge since it should have already started by the time the person reaches it

## 5. Live Game Time starts too early in grid races (refactor, run-length categories)

- **Seen:** found in review (2026-10-20), not yet seen in a run. Lost in the migration when
  Tales of Podracing was disabled and the run-length family was added: v0.4.1 only ever started
  a grid race's timer on the grid release, and nothing in the refactor took that job over for
  races inside a run.
- **Cause:** run-length profiles freeze Game Time with `isLoading{}` only while `!InRace`.
  `InRace` (HUD VM present and laps sane) is already true during the countdown, before
  `raceStarted` flips at the grid release, so Game Time runs through the countdown (and possibly
  the intro, if the HUD VM exists by then). Affects every grid-start event in Arcade%, Scenarios
  and the campaign.
- **Impact:** the live Game Time reads high by the countdown length until the race finishes.
  The finish corrects it: `OnRaceFinished` adds `EventFinishTime` to `IgtTotal` and `gameTime{}`
  snaps to the total, so splits and the final IGT are right. Lap splits inside a grid race are
  not re-synced either: the lap correction is skipped when the running Game Time is more than
  0.5 s off, which it will be, so those lap splits keep the early-start error. Only someone
  watching the live IGT closely, or using lap splits in a run-length category, would notice.
- **Fix idea:** treat the race as live only once it has really started. For run-length profiles
  freeze while `!(InRace && (RaceGo || playerLap >= 1))`: grid races unfreeze on
  `raceStarted` 0→1 (`RaceStartTime` is the countdown end), rolling starts on the first crossing
  (`RaceStartTime` is that crossing's stamp). The same condition would let a re-enabled Tales of
  Podracing IL keep its S2 start unchanged.
- **Status:** open in the refactor script. Not present in v0.4.1 (it has no run-length categories).

## 6. Scenario run ended on the first race, then "ended" again on the next load

- **Seen (2026-10-20, refactor 0.5.0-dev, Debug log):** Arcade Scenarios. START fired once,
  correctly (`FrontEnd.2 -> None`). The first race's finish produced `END`. On the way into the
  second race the log then showed `flow None -> Race.15`, `raceStarted 0 -> 1` with the **same**
  `RaceStamp` as the finished race, `playerLap 0 -> 2`, `finished 0 -> 1` with the same
  `finishTime`, and a second `race finished` / `END`: IgtTotal doubled (6.885 → 13.770) and the
  splits advanced again. The runner saw "timer split again when I hit start".
- **Two causes:**
  1. **Wrong end condition.** E2 was `FinishEdge && IsLastStage`. Each scenario race is its own
     **1-stage recipe** (`stage 0/1` for every race), so `IsLastStage` is true on race one. The
     recipe stage count says nothing about the scenario; the scenario sequence lives in the
     paddock / campaign-run machinery (the scenario goes `FrontEnd.1 -> FrontEnd.2 -> None ->
     Paddock.1 -> 3 -> 4 -> None -> Race…`, i.e. through the paddock like a campaign).
  2. **Replayed finish.** BUGS.md #2 for finishes: during the next level's load the chain
     flickers back to the dead race GameState and replays `finished = 1` with the dead
     `RaceStartTime`. `FinishEdge` fired, bookkeeping added the IGT again, `gameTime{}` snapped
     to the doubled total, and the end condition fired again (the redo dedupe only guarded the
     per-race split, and ran after the end check).
- **Fix (refactor, 2026-10-20):**
  - `ValidFinishEdge` = `FinishEdge && finishTime >= 0 && RaceStamp != DeadRaceStamp` (dead
    stamp 0 = nothing torn down yet). Drives `OnRaceFinished`, the `gameTime{}` snap, the race
    split and every run-length end condition. A rejected finish logs `finish ignored: …`.
    E1 (IL) stays on the raw v0.4.1 edge.
  - E2 is now `ValidFinishEdge && !FinishIsRepeat && EventsDone >= 5` — the fifth distinct
    race's finish. `SCENARIO_RACE_COUNT = 5` is a rules constant.
  - Run-length profiles stop splitting once the end has fired (`Phase == Done`).
  - `RaceEnteredEdge` requires `RaceStamp > 0` (`RaceStartTime` reads −1 before the start;
    it was booking a "race entered" with stamp −1).
- **Seen again (2026-10-21, Nik Skandaro scenario, Debug log):** the dead-stamp check caught
  the first replay (`finish ignored: … == dead race`). During the same load the chain flickered
  a second time with `RaceStartTime` read as **0**, HUD VM gone, `EventId` empty, and replayed
  `finished 0 -> 1` with the old `finishTime`. Stamp 0 ≠ dead stamp, so `ValidFinishEdge` passed:
  `OnRaceFinished` doubled `IgtTotal` (10.32 → 20.64) and `gameTime{}` snapped to it before race
  two had started. No split, only because `split{}` is gated on `InRace`; the bookkeeping and
  the snap were not.
- **Fix (2026-10-21):** `ValidFinishEdge` also requires `InRace` and `RaceStamp > 0`
  (`RaceStartTime` is −1 before a start and 0 through a broken chain; a real finish always has
  the HUD VM and a positive stamp). The `finish ignored` log line now says which guard rejected it.
- **Status:** fixed in the refactor script, untested. E2 and the redo dedupe were both removed
  2026-10-21 (Scenarios have no end condition and split every lap and finish; the dedupe
  compared `EventId`s, which the Nik Skandaro scenario's races share, so race two never split).
  Needs a real scenario with 5 finishes and the IGT checked against the game's own time.

## 7. Precision Driving lap splits ignore gate deductions

- **Seen (2026-10-21, refactor, 2-lap Precision event, 38 gates):** final Game Time 1:10.316
  matched the game. Lap 1 split read 1:04.954 and lap 2 read 0:05.362. The game's time at the
  lap-1 crossing was far lower (the raw lap was 64.95 s with roughly half the deductions
  already earned).
- **Cause:** the lap-edge re-sync set Game Time to `LapStartServerTime − RaceStartTime`, which
  is **raw** elapsed time; the finish snap to `EventFinishTime` is **adjusted**. All 57 s of
  deductions therefore landed in the last lap. v0.4.1 does the same (never checked on a
  multi-lap Precision event; the final time was always right).
- **Fix (2026-10-22, refactor only):** a `Cat_Precision`-only branch in `gameTime{}` returns the
  HUD's `CurrentEventTime` (`hudEventTime`) every tick. It already drops by 1.5 s as each gate is
  passed, so lap splits, the live display and pauses are all right with no bookkeeping. (An
  intermediate fix that subtracted `bonusTime` at each lap edge was tried first and dropped.)
  The shared lap-edge block is v0.4.1 verbatim, so every other category is untouched.
- **Status:** fixed and tested 2026-10-22 (2-lap Precision event, laps and final match the game).
  Opens the door to doing the same for the other categories (#1 live jitter).
