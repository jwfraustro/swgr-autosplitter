# ASL design notes (0.5.0 refactor)

Why `SWGR_Autosplitter_Refactor.asl` is shaped the way it is, and what is left to do. The code is
authoritative for *what* exists (readings, snapshot properties, lambdas, profiles, settings);
`MEMORY_OFFSETS.md` for addresses; `DEV_NOTES.md` for game behaviour and the mods' rules.

## What the script is for

A stopwatch with a few well-chosen triggers, not a rules referee. Anything a moderator verifies
from the recording (which event the run started on, which Act, which mode, whether a medal was
earned) is not the script's concern, and every such check is also a way for the timer to
silently refuse to start while the runner is already driving. A wrong start is the runner's reset.

Two families of category, differing in kind:

- **IL** (single Arcade events: Time Trial, Precision Driving, podraces): ranked by IGT, retried
  constantly, hands-free loop wanted. Start on the exact crossing / grid release, auto-reset on
  retry, replay guards on the stamps. v0.4.1 behaviour, kept verbatim.
- **Run-length** (Arcade%, Arcade Scenarios, the campaign categories): several races in one
  run, never auto-reset, Game Time frozen outside a live race so it is the IGT sum. Arcade%
  and the campaign are ranked by RTA: start on the flow edge that leaves the menu, split on
  every finish, stop on the end event. Scenarios are ranked by IGT (rules change
  2026-10-21): start on the first race's grid release, split on every lap and every finish,
  no end condition — the runner lays out as many splits as their route has and LiveSplit ends
  the run on the last one. The script's only jobs there are the first start and keeping Game
  Time paused between races.

Robustness against the *game's* memory (stale values replaying after a teardown, BUGS.md #2/#6)
stays in both families; that is not policing.

## Shape

Five layers, each only talking to the one below: readings (`state{}`) → snapshot (`vars.Now` /
`vars.Prev`, every derived value computed once per tick in `update{}`) → pure predicates and
edges (`vars.*` lambdas) → run state (`vars.Run`, persists across ticks and races) → category
profiles (one record per speedrun.com category: family, start edge, end condition, what splits).
Action blocks read only the snapshot, the run state and the profile, never `current` / `old`.

Decisions behind it:

- The runner picks the category explicitly. No auto-detection: it would need an identity layer
  to save one click, and a mismatch would be another way to not start.
- A broken chain reads 0, not an error, so presence is its own bool (`HudVmPresent`) wherever 0
  is also a legal value.
- `Phase` is only Idle / Running / Done. Where the game is comes from `Flow`, not a mirrored
  phase.
- Readings are the only layer that changes on a game patch. Versioned `state("…", "<build>")`
  blocks slot in there when needed.

## Catalogue (the S/E/R numbers the code uses)

**Starts.** Each profile picks one.

| # | Trigger | Categories | Why this way |
|---|---|---|---|
| S1 | first start-line crossing (`playerLap` 0→1) | Time Trial, Precision | rolling start; the crossing is the IGT zero. Not gated on the HUD VM, which can appear a tick later |
| S2 | grid released (`raceStarted` 0→1, counters in sync) | Scenarios (first race); Arcade podraces once revived | grid start; the IGT zero. Podrace profile still commented out, see below |
| S3 | left the menu (`InMenu` true→false, to Race or to None during the load) | Arcade%, all campaign except Act III | any launch from the main menu or paddock starts the timer, like every "new game" autosplitter. Fires within one poll of the press and the runner sees it start. `PaddockNarrative` counts as menu so a cutscene can't fire it |
| S4 | left Paddock `CampaignSetup 2` for `PreWorld 3` / `InWorld 4` | NG+ Act III | same machine, no load, so S3 never sees it |

S1/S2 are guarded by `NewRaceInstance` (dead-stamp check); S3/S4 fire in a menu and need none.
S3/S4 profiles never also start on the first race's grid release.

Dropped: latch-and-confirm (arm on the press, confirm arrival by `EventId`, backdate via
`timer.Run.Offset`). It only existed to police which event the press led to, and it made the
timer visibly do nothing on the press.

**Ends.** All `FinishEdge` plus one identity comparison; run-length ends use `ValidFinishEdge`
because the torn-down race replays `finished = 1` during the next load (BUGS.md #6): a valid
finish is in a live race (HUD VM present), has a positive `RaceStartTime`, and that stamp is not
the dead race's. The replay has been seen both with the dead stamp and with the stamp read as 0.

| # | Condition | Categories |
|---|---|---|
| E0 | never | Scenarios. The 5th race's finish is just another race split; the runner's split count ends the run. (The earlier `EventsDone >= 5` end was dropped 2026-10-21: it fought the runner's own layout, and `IsLastStage` is useless anyway — each scenario race is a 1-stage recipe) |
| E1 | finish of the only race | all ILs |
| E3 | finish of *The Experiment* | Arcade% |
| E4 | finish of the Sebulba final | Sebulba%, NG+ Sebulba% (name still empty, so never fires) |
| E5 | finish of the Kestar final | Any%, NG+ Any%, NG+ Champion%, NG+ Act III (name still empty) |

No medal check on E3 and no Act check on E4/E5: the moderator sees both. A medal check, if ever
asked for, is one more `&&` on E3 against a medal reading (DEV_NOTES "Open", M8).

**Resets.**

| # | Condition | IL | Run-length |
|---|---|---|---|
| R1 | teardown before finish (HUD VM gone, `raceStarted` 1→0, `playerLap` ≥1→0) | reset if `ResetOnLeave` | no-op |
| R2 | teardown after finish | no-op | no-op (expected between events) |
| R3 | back to main menu, a fresh S3/S4 while running, wrong first event, failed race | — | no-op. Run-length never takes a running timer away; the runner resets |
| R4 | category setting changed | `ResetRun()` (run state only, timer untouched) | same |

Dead-stamp capture runs on every teardown in both families.

## Invariants (what a future edit must not break)

- `update{}` order: `SelectProfile` → `CaptureDeadStamps` → `OnRaceEntered` → `OnRaceFinished`.
  `update{}` runs before `gameTime{}` and `split{}`, which both rely on the bookkeeping already
  having happened on the finish tick.
- `OnRaceFinished` owns the `IgtTotal` add; `gameTime{}` returns the total on the finish tick
  and must not add again. Every valid finish adds its IGT, redo or not (the IGT column is
  driving time; if the mods want only the counting attempt it is a one-line change there).
- No redo detection (dropped 2026-10-21). It compared `EventId` against the last finished
  event, and `EventId` is not a race identity: the Nik Skandaro scenario's five races share
  one, so race two never split. Every valid finish splits; a runner who redoes an event skips
  or undoes the split. The margins in a scenario make a redo a restart anyway.
- Once a run-length profile's end has fired (`Phase == Done`) nothing else splits.
- IL `reset{}` keeps the raw v0.4.1 conditions, not the flow-based `IsTearingDown`, so IL
  behaviour stays bit-for-bit. Likewise `InRace` stays `HudVmPresent && LapsSane`; the flow
  machine is a Debug cross-check for ILs, not a replacement (the crossing-based ILs must not
  change behaviour).
- `gameTime{}` between crossings is real time, re-synced to the stamps on lap edges (within a
  0.5 s garbage guard) and snapped to `EventFinishTime` on the finish. An empty end-event
  constant never matches, so an unfilled E4/E5 can't end a run.
- `isLoading{}`: ILs freeze only after the finish (a one-tick freeze at the Arcade start would be
  a behaviour change); run-length also freezes whenever not in a *live* race: HUD present and
  either `raceStarted` (grid events) or `playerLap >= 1` (rolling starts). The grid countdown
  is not live; timing it would have put every scenario race's IGT off by the countdown, and the
  lap-edge re-sync's 0.5 s guard would have refused the correction.
- Campaign splits: the only must-split is the end condition. Per-planet or per-event splits are
  a route question; leave until someone asks.

## Rules change 2026-10-21 (Scenarios done; podrace IL pending)

Mods' wording: Story Campaign and Arcade% need a real-time timer on screen; Arcade% is ranked
RTA with total IGT submitted alongside; Arcade events **and Scenarios** are ranked by IGT, using
the time the game shows on the event selection screen. "Tales of Podracing" is gone; podraces
are ordinary arcade events.

What it changes:

1. **Scenarios are IGT** — done 2026-10-21. `RankedBy = "IGT"`, start S2 (`StartStamp =
   "Race"`) so the timer visibly starts when the timing does, split on every lap and finish,
   end E0 (never): how the runner lays out their splits is theirs (5 × N laps, or 5 race
   splits with `LapSplits` off), and LiveSplit ends the run on the last one. Family stays
   run-length (no auto-reset, `isLoading` outside a live race). The once-per-event redo
   dedupe went with it (see Invariants): scenario races share an `EventId`.
   Deferred: how the game's own scenario time treats a redone race. Today a redone race *adds*
   its time to `IgtTotal`; if the game shows last-attempt-per-race, `OnRaceFinished` would have
   to *replace* that `EventId`'s entry (a per-event dictionary instead of a running sum). Not
   worth settling until a runner reports a mismatch; the submitted time comes from the game's
   screen either way.
2. **Podraces as an arcade IL.** Revive the commented-out `Cat_Podracing` profile as
   "Arcade — Podrace (grid start)": IL family, S2, `StartStamp = "Race"`, E1. Alternatively fold
   all single arcade events into one profile whose start is "S1 or S2, whichever fires first";
   that depends on rolling starts never raising `raceStarted` before the crossing (DEV_NOTES
   says Arcade may never set it at all, so it is probably safe, but record one of each first).
3. **Arcade% is unchanged** (RTA, S3, E3, IGT sum alongside). Podraces inside it are already
   handled: splits are on finishes, not starts. The redo rule for its IGT column is a separate
   question for the mods (DEV_NOTES "Open").
4. Setting labels and tooltips: Scenarios reworded (done); "Tales of Podracing" label goes
   with the podrace revival.

## Status and remaining work

Steps 1–5 landed 2026-10-19/20 (snapshot, edges, run state, IL profiles, run-length family),
**untested in LiveSplit**. Intended differences from v0.4.1 and nothing else: `LapsSane` accepts
100 laps (BUGS.md #3); with ResetOnLeave off and the timer reused across races, Game Time is the
IGT sum rather than the last race's time.

- [ ] Test in LiveSplit, ILs first (must match v0.4.1), then Arcade%: Landspeeder Ace, then skip
      to The Experiment. Confirm ASL `string128` reads the UTF-16 `stageName` correctly.
- [ ] Test a Scenario: timer starts on race 1's go (not the countdown), Game Time holds through
      each load and the next countdown, lap and finish splits every race, nothing after the
      runner's last split.
- [ ] Step 6: fill `EVENT_SEBULBA_FINAL` / `EVENT_KESTAR_FINAL` once the names are found.
- [ ] S4: record whether Act III "Start Run" goes 2→3→4 or 2→4 (both are handled).
- [ ] Step 7, only if wanted: `IsPaused` (`AWorldSettings.PauserPlayerState` via
      UWorld → PersistentLevel → WorldSettings), live `EventIgt` as in-race Game Time (needs
      `hudEventTime` smooth at 60 Hz; BUGS.md #1), versioned `state` blocks for patches,
      `EventKind` mismatch warning, medal check on E3.
- Mock testing harness: `testing/` (`swgr_mock.py`, `test_time_trial.py`, `run.py`).
