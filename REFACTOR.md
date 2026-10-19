# Plans for refactoring the ASL

Planning document. Nothing named here has to exist yet, and no address has to be known —
the point is to decide how the script splits into reusable pieces before the multi-event
categories land. Names are proposals. Status markers used throughout:

- **have** — exists in `SWGR_Autosplitter.asl` v0.4.1 (possibly under another name).
- **verified** — address / behaviour confirmed live but not used by the script yet.
- **lead** — a candidate in the dump; unverified.
- **find** — no candidate yet; needs a memory hunt (see `NOTES.md` → *Memory to find*).

## Shape of the refactored script

Today `start{}` / `split{}` / `reset{}` read raw `current.*` offsets directly, with the two
modes branched inline. That works for two modes and one race; it does not scale to ten
categories, five of which span several races and three of which start from a menu press.

Five layers, each only talking to the one below it:

1. **Readings** — the `state{}` block. One line per memory value, grouped by the object it
   lives on. No logic. This is the only layer that changes when the game patches.
2. **Snapshot** — `update{}` turns `current` into `vars.Now` (an `ExpandoObject`) and keeps
   last tick's as `vars.Prev`. Every derived value (`InRace`, `EventKind`, `EventIgt`, …) is
   computed **once per tick, here**. The action blocks never touch `current`/`old` again, so
   every block sees the same answers on the same tick, and we can edge-detect on *derived*
   values (`Prev.EventId != Now.EventId`), not just raw ones.
3. **Predicates and edges** — `vars.*` lambdas defined in `init{}`. Pure functions of a
   snapshot, or of a `(Prev, Now)` pair for edges. These are the reusable "checks".
4. **Run state** — `vars.Run`: what persists across ticks *and across races*: the active
   category profile, the run phase, events completed, IGT accumulated, the identity of the
   race we were last in, the torn-down race's timestamps.
5. **Category profiles** — one record per speedrun.com category saying which start edge,
   which split edges, which end condition and which reset policy apply. `start{}` becomes
   roughly `return vars.Run.Profile.Start(vars.Prev, vars.Now);`.

ASL facts that shape the design:

- A reading whose pointer chain fails comes back as `0` / default, not an error. "Chain is
  undefined" therefore has to be carried as its own bool (`HudVmPresent`) wherever 0 is also
  a legal value.
- No classes. Snapshots are `ExpandoObject`, lambdas are `Func<...>` stored in `vars`, and
  profiles are `Dictionary<string, dynamic>`.
- `gameTime{}` runs before `split{}` on a tick; `isLoading{}` returning true freezes Game
  Time. We already lean on both for exact finish times.
- `settings` is a tree of checkboxes, not radio buttons. Keep the "pick one" parent. The
  runner picks their category explicitly; the script never tries to work it out from the
  loaded event. Runners rarely hop between categories, and auto-detection would add a whole
  identity layer just to save one click.
- Several `state("SWGR-Win64-Shipping", "<build>")` blocks plus `version` in `init{}` is the
  standard way to survive patches without a sigscan. Not part of this refactor, but the
  readings layer is where it slots in.

## Variables

### Raw readings (`state{}`)

Grouped by owning object. "Chain" refers to the chains in `NOTES.md`.

**A. `ARacingGameState`** (`GWorld, 0x1B0`) — valid only during a race; otherwise the same
offsets point into a menu GameState and read garbage.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `raceStarted` | bIsRaceStarted | byte | have | grid-start "go" |
| `raceFinished` | bIsRaceFinished | byte | lead | player or all racers? |
| `totalLaps` | LapCount | int | have | sanity gate + lap split bound |
| `raceStartTime` | RaceStartTime | double | have | base for lap-split IGT; dead-race guard |
| `countdownEndTime` | CountdownEndTime | double | lead | cross-check for grid starts |
| `activeStage` | EventRecipeState.ActiveStage | int | lead | stage index in a multi-stage recipe (Scenarios?) |
| `stageCount` | EventRecipe.EventStages.Num | int | lead | TArray count at `0x3F8 + 0x8` |
| `raceFlowState` | state machine CurrentStateId | int | find | `UGameFlowStateMachineComponent` owner unknown; would give `Racing` / `Results` / `Leaving` directly |

**B. `URaceEventVM`** (HUD view model, `GWorld, 0x1B0, 0x3D8`) — pointer is 0 outside a race.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `hudVM` | (the pointer) | long | have | presence = HUD exists |
| `hudLap` | CurrentLapNumber | int | have | starts at 1 |
| `hudNumLaps` | NumLaps | int | lead | second opinion on `totalLaps` |
| `hudLapTime` | CurrentLapTime | double | verified | raw lap IGT, resets per lap |
| `hudEventTime` | CurrentEventTime | double | verified | running event IGT, gate deductions applied in Precision Driving arcade races |
| `hudModeType` | ModeType | byte | lead | `ERaceEventModeType`; Precision = 8 |
| `trackNamePtr` / `trackNameLen` | track → InternalName (FString) | ptr/int | lead | chain not resolving yet |
| `hudSuccess` | bIsSuccess | byte | lead | finish outcome |

**C. `UPlayerRaceEventComponent`** (local player, chain `…0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368`).

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `playerLap` | CurrentLapNumber | int | have | 0 until first crossing; LapCount+1 after finish; 0 after leaving |
| `finished` | bHasFinishedEvent | byte | have | end trigger for every category |
| `finishTime` | EventFinishTime | float | have | −1 until finish; results-screen time (adjusted for Precision) |
| `bonusTime` | BonusTime | float | verified | Precision gate deductions, 1.5 per gate |
| `lapStartServerTime` | LapStartServerTime | double | have | stamp at each crossing; dead-race guard |
| `eventPosition` | EventPosition | int | lead | finish position (campaign "must win"?) |
| `failReasons` | FailReasons | byte | lead | bitflags; `bHasTimedOut` / `bHasVehicleWrecked` / `bHasBeenEliminated` nearby |
| `bestLapTime`, `prevLapTime` | | float | lead | display only |

**D. Event identity** (`EventRecipe.EventStages[ActiveStage]`, `FRaceEventInstance`).

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `stageNamePtr` / `stageNameLen` | FRaceEventInstance.InternalName (FString) | ptr/int | lead | stable event ID; best bet for M6 / M7 |
| `arcadeCategory` | AuthoredEvent → `UArcadeEventDef.Category` | byte | lead | `EArcadeEventCategories`; only meaningful if the def *is* an arcade def |
| `authoredEvent` | FRaceEventInstance.AuthoredEvent | ptr | lead | class check (arcade vs campaign def) |
| `skipCountdown` | URaceEventDef.bShouldSkipCountdown | byte | lead | rolling vs grid start, straight from the def |
| `stageLapCount` | FRaceEventInstance.LapCount | byte | lead | cross-check `totalLaps` |

**E. Campaign** (`UCampaignSubsystem`, chain TBD — `UGfnGameInstance::GetCampaignManager()`).

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `playingPrologue` | bIsPlayingPrologue | byte | verified | 0→1 on New Campaign *and* on reset Accept (M1, M2) |
| `activeRun` | ActiveRun | ptr | verified | null→ptr on Act III loadout Continue (M3); check other flips |
| `campaignAct` | MetaProgression → MainCampaignCurrentTourIx | int | lead | Act III index value TBC |
| `campaignDifficulty` | MetaProgression → LastPickedDifficulty | ptr/enum | lead | Champion% warning only (M10) |
| `continueRunState` | `EContinueRunState` | byte | lead | Paddock / StartEvent / PostEvent / LeavePlanet; between-race phases |

**F. Front end / menus.**

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `arcadeStartPressed` | `UArcadeEntryVM` or flow state | ? | find | M4 Arcade "Start Event"; M5 Scenario start |
| `arcadeSelectedEvent` | `UArcadeEntryVM` event def / name | ? | find | must be *Landspeeder Ace* for Arcade% |
| `frontEndFlowState` | `EFrontEndFlowState` | byte | lead | menu location, for "we are in a menu, not loading" |
| `medalResult` | results / goal state | ? | find | M8 Bronze beaten; fallback = compare `finishTime` to the def's Bronze time |

**G. Engine / misc.**

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `pauserPlayerState` | `AWorldSettings.PauserPlayerState` (UWorld → PersistentLevel → WorldSettings) | ptr | lead | UE's own pause flag; non-null while paused |
| `worldTime` | ReplicatedWorldTimeSecondsDouble | double | verified-bad | lags crossings; **not** a live clock |

### Derived, per tick (`vars.Now` / `vars.Prev`)

Computed in `update{}` from the readings above. Everything below is a plain property on the
snapshot; the lambda that computes it is listed under **Functions**.

| Property | Type | Meaning | Status |
|---|---|---|---|
| `HudVmPresent` | bool | HUD view model pointer resolved | have (`hudVM != 0`) |
| `LapsSane` | bool | `totalLaps` and `playerLap` in range | have |
| `InRace` | bool | local player is in a live race | have |
| `LapsInSync` | bool | `hudLap == playerLap + 1` | have |
| `RaceGo` | bool | `raceStarted` is set (grid released) | have (raw) |
| `Finished` | bool | player crossed the final line | have (raw) |
| `Failed` | bool | timed out / wrecked / eliminated / fail flags | lead |
| `Paused` | bool | game is paused | lead |
| `Loading` | bool | between levels / race not yet live | lead |
| `EventKind` | enum | TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown — debug / mismatch warning only, never drives behaviour | lead |
| `EventId` | string | stable event name (Landspeeder Ace, The Experiment, Sebulba final, …) | lead |
| `MapId` | string | track internal name | lead |
| `StageIndex`, `StageCount`, `IsLastStage` | int / bool | multi-stage recipe position | lead |
| `LapIgt` | double | raw running lap time | verified |
| `EventIgt` | double | running event time, Precision Driving checkpoint-adjusted | verified |
| `FinishIgt` | double | final event time (≥ 0 only after finish) | have |
| `GateBonus`, `GatesHit` | double / int | Precision driving deductions and count | verified |
| `CampaignAct` | int | current Act index | lead |
| `CampaignRunActive` | bool | `activeRun != 0` | verified |
| `PrologueFlag` | bool | `playingPrologue` | verified |
| `RaceStamp` | double | `raceStartTime` (identity of this race instance) | have |
| `LapStamp` | double | `lapStartServerTime` | have |

### Run state (`vars.Run`, persists across ticks and races)

| Field | Meaning | Set by |
|---|---|---|
| `Profile` | the active category profile (see **Category profiles**) | the Category setting, re-read on settings change |
| `Phase` | `Idle` → `Armed` (menu start seen, no race yet) → `InRace` → `Between` (race done, next not loaded) → `Done` | start / finish / transition edges |
| `EventsDone` | races or events completed in this run | end-of-race edge |
| `IgtTotal` | sum of `FinishIgt` over completed races | end-of-race edge |
| `LastEventId`, `LastMapId` | identity of the race last entered | race-entry edge |
| `LastFinishedEventId` | which event just finished (for retry detection) | end-of-race edge |
| `DeadRaceStamp`, `DeadLapStamp` | timestamps of the torn-down race (BUGS.md #2) | teardown edges |
| `PendingStart` | latched start edge waiting for a confirming tick (Arcade HUD-VM race, NOTES v0.1.0) | update |

### Settings

- **Category** (pick one): Arcade Time Trial, Precision Driving, Tales of Podracing,
  Arcade Scenarios, Arcade%, Sebulba%, Any%, NG+ Sebulba%, NG+ Any%, NG+ Champion%,
  NG+ Act III. One entry each; the profile table maps them. No auto-detect: if more than
  one is ticked, use the first and print a warning in Debug.
- **Splits**: lap splits, per-race splits (multi-event), finish split.
- **Reset**: on leaving the race (IL only — multi-event profiles ignore it between races).
- **Timing**: "Game Time = IGT" on/off (always on for IL; for RTA categories it just fills
  the Game Time column with the IGT sum the mods want in submissions).
- **Pause stops timer** (once `Paused` exists).
- **Debug**: print every derived edge, not just raw ones.

## Functions

All are `vars.*` lambdas. `s` = a snapshot; `(p, n)` = previous and current snapshots.
"Used by" names the profiles / blocks that need it.

### Gates ("where are we?")

| Function | Question | Definition | Status | Used by |
|---|---|---|---|---|
| `IsRaceGameState(s)` | does GameState look like an `ARacingGameState`? | `LapsSane` (later: class or `raceFlowState` check) | have (as part of InRace) | everything |
| `InRace(s)` | is the local player in a live race? | `HudVmPresent && LapsSane` | have | split, reset, Race start |
| `InRaceStrict(s)` | …and lap counters agree? | `InRace && LapsInSync` | have | grid starts |
| `IsPaused(s)` | is the game paused? | `pauserPlayerState != 0` | lead | isLoading (optional), debug |
| `IsLoading(s)` | between levels / race not live? | `raceFlowState ∈ {LoadingPhase, WaitForLevelToLoad}`; fallback `!HudVmPresent && Run.Phase == Between` | lead | multi-event transitions, load removal if ever ruled in |
| `InMenu(s)` | front end, not a race, not a load? | `frontEndFlowState` set and `!InRace` | lead | menu-press starts |
| `IsTearingDown(p, n)` | did the race we were in just go away? | `p.InRace && !n.InRace`, or `p.playerLap ≥ 1 && n.playerLap == 0` | have (reset) | reset, dead-stamp capture |

### Edges ("what just happened?")

| Function | Fires when | Status | Used by |
|---|---|---|---|
| `RaceGoEdge(p, n)` | `raceStarted` 0→1 with `InRaceStrict(n)` and fresh `RaceStamp` | have | Podracing, Scenario races, campaign races |
| `FirstCrossingEdge(p, n)` | `playerLap` 0→1, `!Finished`, `LapsSane`, fresh `LapStamp` | have | Time Trial, Precision (rolling starts) |
| `LapEdge(p, n)` | `playerLap` n→n+1, 1 ≤ n < `totalLaps`, `!Finished` | have | lap splits, lap IGT re-sync |
| `FinishEdge(p, n)` | `finished` 0→1 | have | every end state, race splits |
| `FailEdge(p, n)` | `Failed` false→true | lead | retry handling (Arcade%, NG+ Sebulba%) |
| `RaceEnteredEdge(p, n)` | `!p.InRace && n.InRace` with a new `RaceStamp` | — | run bookkeeping (`LastEventId`), Scenario race counting |
| `NewRaceInstance(p, n)` | `RaceStamp`/`LapStamp` differ from `Run.Dead*` | have (inline) | guards every start edge |
| `PrologueEdge(p, n)` | `playingPrologue` 0→1 | verified | Sebulba%, Any%, NG+ ×3 |
| `ActIIIContinueEdge(p, n)` | `activeRun` null→ptr and `CampaignAct == ActIII` | verified / lead | NG+ Act III |
| `ArcadeStartEdge(p, n)` | "Start Event" pressed with `arcadeSelectedEvent == LandspeederAce` | find | Arcade% |
| `ScenarioStartEdge(p, n)` | scenario start confirmed | find | Scenarios |
| `CategoryChanged()` | settings differ from `Run.Profile` | — | update (re-arm) |

### Timing ("what time is it?")

| Function | Returns | Definition | Status | Used by |
|---|---|---|---|---|
| `EventIgt(s)` | running event time | `hudEventTime` | verified | live Game Time (would remove the between-crossings jitter in BUGS.md #1) |
| `LapIgt(s)` | running lap time | `hudLapTime` | verified | display / debug |
| `LapSplitIgt(s)` | exact elapsed at the last crossing | `LapStamp − RaceStamp` | have | gameTime on `LapEdge` |
| `FinishIgt(s)` | final adjusted time | `finishTime` | have | gameTime on `FinishEdge`, `IgtTotal` |
| `RawFinishIgt(s)` | unadjusted | `finishTime + bonusTime` | verified | Precision debug / display |
| `GatesHit(s)` | gates driven through | `round(bonusTime / 1.5)` | verified | Precision display |
| `RunGameTime(s)` | Game Time for the whole run | `Run.IgtTotal + (InRace ? EventIgt(s) : 0)`; snaps to `IgtTotal + FinishIgt` on `FinishEdge` | — | gameTime for every profile |

Note on `RunGameTime`: this single formula covers ILs (`IgtTotal` = 0) and multi-event runs,
and it is naturally paused during loads and menus because `EventIgt` isn't advancing. It
makes `isLoading{}` simply `!InRace || Finished`. Whether to also use it *live* inside a race
(instead of real time + re-sync at crossings) depends on `hudEventTime` being smooth at 60 Hz;
BUGS.md #1 originally read garbage at that offset, `NOTES.md` now says verified — test it.

### Identity ("which race / event is this?")

| Function | Returns | Definition | Status | Used by |
|---|---|---|---|---|
| `MapId(s)` | track internal name | FString at HUD VM → track → InternalName | lead (chain broken) | display, Scenario / campaign race recognition |
| `EventId(s)` | stable event name | `FRaceEventInstance.InternalName` (or AuthoredEvent object name) | lead | Arcade% (Landspeeder Ace, The Experiment), Sebulba / Kestar finals |
| `EventKind(s)` | TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown | `arcadeCategory` if `authoredEvent` is an arcade def (Plane→Podracing, Precision→Precision, else TimeTrial); campaign if `CampaignRunActive`; Scenario if recipe has >1 stage and not campaign | lead | **optional**: Debug warning when the loaded event doesn't match the chosen category. Never selects behaviour |
| `IsLastStage(s)` | last race of a multi-stage recipe? | `StageIndex == StageCount − 1` | lead | Scenarios end (M9) |
| `IsEvent(s, name)` | is this the named event? | `EventId(s) == name` | lead | all end-identity checks |
| `MedalBeaten(s, tier)` | did the finish beat the tier? | results data, or `FinishIgt ≤ def.BronzeTime` | find | Arcade% end (M8) |
| `CampaignAct(s)` | Act index | `campaignAct` | lead | NG+ Act III start, sanity on campaign ends |

### Run bookkeeping (called from `update{}`)

| Function | Does | Status |
|---|---|---|
| `CaptureDeadStamps(p, n)` | on `IsTearingDown`, store `RaceStamp` / `LapStamp` into `Run.Dead*` | have |
| `OnRaceEntered(p, n)` | set `Run.LastEventId` / `LastMapId`, `Phase = InRace` | — |
| `OnRaceFinished(p, n)` | `IgtTotal += FinishIgt`, `EventsDone++`, `LastFinishedEventId = EventId`, `Phase = Between` | — |
| `OnRaceFailed(p, n)` | mark the attempt failed; a following `RaceEnteredEdge` with the same `EventId` is a retry, not progress | lead |
| `ResetRun()` | clear all of the above | — |

## Start States

Each category profile picks exactly one. All are guarded by `NewRaceInstance` where a race
value is involved, and by `Run.Phase == Idle`.

| # | Trigger | Edge | Extra gate | Categories | Status |
|---|---|---|---|---|---|
| S1 | First start-line crossing (rolling start) | `FirstCrossingEdge` | — | Arcade Time Trial, Precision Driving | have |
| S2 | Grid released (countdown over) | `RaceGoEdge` | `InRaceStrict` | Tales of Podracing | have |
| S3 | New campaign / campaign reset confirmed | `PrologueEdge` | — | Sebulba%, Any%, NG+ Sebulba%, NG+ Any%, NG+ Champion% | verified, chain TBD |
| S4 | Act III loadout Continue | `ActIIIContinueEdge` | `CampaignAct == ActIII`; confirm `activeRun` doesn't flip on Act I/II or save resume | NG+ Act III | verified, index TBC |
| S5 | Arcade "Start Event" on Landspeeder Ace | `ArcadeStartEdge` | `arcadeSelectedEvent == LandspeederAce` | Arcade% | find (M4) |
| S6 | Scenario start confirmed | `ScenarioStartEdge` | — | Arcade Scenarios | find (M5), rule TBD with mods |
| S7 | *(fallback)* first race's go | `RaceGoEdge` with `Run.Phase == Idle` | only if S5/S6 can't be found; timer would start late vs the video-timed rule | Arcade%, Scenarios | — |

Notes:
- S1 keeps its deliberate *non*-gating on the HUD VM (NOTES v0.1.0). If the snapshot layer
  makes that fragile, latch it: `Run.PendingStart = true` on the raw edge, fire on the first
  tick where `InRace`.
- S3 cannot distinguish new campaign from reset; the profile decides. S3 and S4 fire in a
  menu, so the first race's `RaceGoEdge` is a *split-or-nothing* event for those profiles,
  never a start.
- Menu-press starts put the run in `Phase = Armed`; the first `RaceEnteredEdge` moves it to
  `InRace`.

## End States

All built on `FinishEdge` plus an identity check. On the end, `OnRaceFinished` runs first so
the finish split's Game Time is `IgtTotal` including this race.

| # | Trigger | Condition | Categories | Status |
|---|---|---|---|---|
| E1 | Final-lap finish of the only race | `FinishEdge` | Arcade Time Trial, Precision Driving, Tales of Podracing | have |
| E2 | Finish of the scenario's last race | `FinishEdge && IsLastStage` (or `EventsDone == 5` fallback) | Arcade Scenarios | lead (M9) |
| E3 | Finish of *The Experiment* with Bronze beaten | `FinishEdge && IsEvent(TheExperiment) && MedalBeaten(Bronze)` | Arcade% | find (M7, M8) |
| E4 | Final-lap finish vs Sebulba (last race of Act 1) | `FinishEdge && IsEvent(SebulbaFinal)`; sanity `CampaignAct == ActI` | Sebulba%, NG+ Sebulba% | lead (M6) |
| E5 | Final-lap finish vs Kestar's Podracer (last race of Act 3) | `FinishEdge && IsEvent(KestarFinal)`; sanity `CampaignAct == ActIII` | Any%, NG+ Any%, NG+ Champion%, NG+ Act III | lead (M6) |

A `FinishEdge` that is **not** the end condition is a per-race split (if enabled) and moves
`Phase` to `Between`. A `FinishEdge` on an event with `Failed` set, or a retry of
`LastFinishedEventId`, is neither.

## Reset / ignore states

The current single-race reset (`ResetOnLeave`) is wrong for every multi-event category:
between races the HUD VM goes away, `playerLap` drops to 0 and `raceStarted` drops to 0 —
all three of today's reset conditions fire. Profiles therefore own the reset policy.

| # | Condition | IL profiles | Multi-event profiles |
|---|---|---|---|
| R1 | `IsTearingDown` before `Finished` | reset (if enabled) | no-op; a restart of the same event is a retry |
| R2 | `IsTearingDown` after `Finished` | no-op (run is over) | no-op; expected between races |
| R3 | `FailEdge` | reset (if enabled) | no-op; retries are allowed (Arcade%, NG+ Sebulba%) |
| R4 | Back at the main menu with `Run.Phase ∈ {Armed, InRace, Between}` and no race for a long time | n/a | *maybe* reset; or never auto-reset and leave it to the runner |
| R5 | A fresh S3/S4/S5/S6 edge while a run is in progress | n/a | reset then start (runner restarted the category) |
| R6 | `CategoryChanged` | reset run state (`ResetRun`), not the timer | same |

Dead-stamp capture (`CaptureDeadStamps`) runs on every teardown regardless of policy, since
the false-start replay in BUGS.md #2 happens on every transition, including the ones
between Scenario races.

## Category profiles

What each profile record holds, and the matrix. "Race split" = split on every `FinishEdge`
that isn't the end.

| Category | Ranked by | Game Time column | Start | Splits | End | Reset policy |
|---|---|---|---|---|---|---|
| Arcade Time Trial | IGT | `FinishIgt` | S1 | laps | E1 | IL |
| Precision Driving | IGT (adjusted) | `FinishIgt` (already adjusted) | S1 | laps | E1 | IL |
| Tales of Podracing | IGT | `FinishIgt` | S2 | laps | E1 | IL |
| Arcade Scenarios | RTA | `IgtTotal` | S6 (S7 fallback) | race (+ laps optional) | E2 | multi |
| Arcade% | RTA | `IgtTotal` | S5 (S7 fallback) | event, skipping failed/retried | E3 | multi |
| Sebulba% / Any% | RTA | `IgtTotal` | S3 | race | E4 / E5 | multi |
| NG+ Sebulba% / Any% / Champion% | RTA | `IgtTotal` | S3 | race | E4 / E5 | multi |
| NG+ Act III | RTA | `IgtTotal` | S4 | race | E5 | multi |

Profile record fields: `Start(p, n)`, `IsEnd(p, n)`, `SplitOnLap`, `SplitOnRace`,
`ResetPolicy` (IL / multi), `Igt` (always `RunGameTime`), and optionally `ExpectedEventKind`
(Debug-only warning when the loaded event doesn't match the chosen category, e.g. a
Precision event under Time Trial — it never changes what the script does).

## Migration order

Each step keeps the script shippable; ILs must not regress.

0. Skeleton: function stubs, variables, placeholders where they do not exist.
1. Introduce the snapshot layer and move the existing lambdas (`InRace`, `LapsSane`,
   `LapsInSync`) and dead-stamp capture onto it. Behaviour identical to v0.4.1.
2. Extract the edges (`RaceGoEdge`, `FirstCrossingEdge`, `LapEdge`, `FinishEdge`) and the
   timing functions; rewrite `start{}` / `split{}` / `gameTime{}` against them.
3. Add `vars.Run` and `RunGameTime`; `IgtTotal` is 0 for ILs so nothing changes yet.
4. Add profiles for the three IL categories (Time Trial, Precision, Podracing). Needs no new
   memory: Precision already works through the adjusted `finishTime`.
5. Add the multi-event reset policy and `Phase` handling; test on a Scenario even without
   S6, using S7, to shake out the between-race transitions (BUGS.md #2 territory).
6. Add S3/S4 and E4/E5 (campaign) once the `UCampaignSubsystem` chain and `EventId` exist.
7. Add S5/S6, E2/E3 as M4, M5, M8, M9 are found.
8. Separately: `IsPaused`, live `EventIgt` as the in-race Game Time, versioned `state` blocks.

## Open items this plan depends on

- `EventId` / `MapId`: a working FString chain (track InternalName chain is broken; try
  `FRaceEventInstance.InternalName` via `EventStages[ActiveStage]`).
- `EventKind` (optional, Debug warning only): verify the `arcadeCategory` chain and the class
  check for non-arcade defs.
- Stable chain to `UCampaignSubsystem`; Act III index value; whether `activeRun` flips elsewhere.
- M4 / M5 menu-press readings; M8 medal result; M9 stage count for Scenarios.
- `raceFlowState` owner — would replace several heuristics (`IsLoading`, `IsRaceGameState`,
  teardown detection) with one enum read.
- Pause flag (`PauserPlayerState` lead).
- Whether `hudEventTime` is smooth enough at 60 Hz to be the live Game Time.
- Mods: Scenario start point; plain RTA vs load-removed; NG+ Champion% from a fresh save.
