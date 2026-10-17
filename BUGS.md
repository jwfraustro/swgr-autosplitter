# Known bugs

Open issues with the autosplitter. Dev-facing; background on the values involved is in
`NOTES.md`.

## 1. Final time ~0.03 s off the results screen

- **Seen:** v0.1.0, Arcade. LiveSplit's final time differs from the in-game results screen by
  ~0.03 s.
- **Likely cause:** ~0.03 s is about 2 ticks at 60 Hz, so polling latency on the start edge and
  the finish edge could account for it.
- **Fix idea:** take timing from the game instead of polled edges and drive LiveSplit Game Time
  from it, so the result matches the results screen exactly. Internal timers to cross-check:
  - `ARacingGameState.RaceStartTime` (0x378)
  - `UPlayerRaceEventComponent`: `LapStartServerTime` (0xE8), `EventFinishTime` (0xF0),
    `PreviousLapTime` (0xFC)
  - `URaceEventVM`: `CurrentEventTime` (0x188), `CurrentLapTime` (0x178)
  - `AGameStateBase.ReplicatedWorldTimeSecondsDouble` (0x2E0)
- **Why it matters more later:** Precision Driving subtracts 1.5 s per gate, so it will likely
  need game-driven time anyway (`EventFinishTime` / `BonusTime`).
- **Status:** open.

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
