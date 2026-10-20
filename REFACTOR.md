# Plans for refactoring the ASL

Planning document. Nothing named here has to exist yet, and no address has to be known —
the point is to decide how the script splits into reusable pieces before the run-length
categories land. Names are proposals. Status markers used throughout:

- **have** — exists in `SWGR_Autosplitter.asl` v0.4.1 (possibly under another name).
- **verified** — address / behaviour confirmed live but not used by the script yet.
- **lead** — a candidate in the dump; unverified.
- **find** — no candidate yet; needs a memory hunt (see `NOTES.md` → *Memory to find*).

## Shape of the refactored script

Today `start{}` / `split{}` / `reset{}` read raw `current.*` offsets directly, with the two
modes branched inline. That works for two modes and one race; it does not scale to ten
categories, eight of which span several races and start from a menu press.

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

### What the script is for

The script is a stopwatch with a few well-chosen triggers, not a rules referee. Anything a
moderator verifies from the recording — which event the run started on, which Act, which mode,
whether a medal was earned — is not the script's concern, and every such check is also a way
for the timer to silently refuse to start while the runner is already driving. A wrong start
is the runner's reset.

That gives two families of category, and they differ in kind:

- **IL** (Arcade Time Trial, Precision Driving, Tales of Podracing): ranked by IGT, retried
  constantly, hands-free loop wanted. Start on the exact crossing / grid release, auto-reset on
  retry, replay guards on the stamps — v0.4.1 behaviour, unchanged.
- **Run-length** (Arcade%, Arcade Scenarios, the campaign categories): ranked by RTA. Start on
  the flow edge that leaves the menu, split once per finished event, stop on the end event,
  **never** auto-reset. Game Time is the IGT sum, for the submission column.

Robustness against the *game's* memory (stale values replaying after a teardown, BUGS.md #2)
stays in both families; that is not policing.

## Variables

### Raw readings (`state{}`)

Grouped by owning object. "Chain" refers to the chains in `DEV_NOTES.md`.

**A0. Flow state machine** (`GWorld, 0x1B0, 0x298, 0x0` = GameState → `BlueprintCreatedComponents[0]`
= `UGameFlowStateMachineComponent`). **Every** GameState carries this component — in a race it runs
`USimpleRaceStateMachine`, in the menus `UFrontEndStateMachine`, in the campaign hub `UPaddockStateMachine`.
It is the game's own phase machine, and the one reading that is meaningful in every mode. The
`CurrentStateId` int is ambiguous on its own (Paddock `Leaving` = 5 = race `Racing`), so it is always
read together with the enum's entry count, which identifies the machine.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `flowState` | `ActiveStateMachines[0].CurrentStateId` (`…0xC0, 0x10`) | int | verified | the state id in the machine's own enum |
| `flowEnumCount` | `ActiveStateMachines[0].StateMachineStateIdEnum->Names.Num` (`…0xC0, 0x8, 0x50`) | int | verified | **37** `ESimpleRaceGameModeState`, **16** `EFrontEndFlowState`, **9** `EPaddockFlowState`, **4** `EPaddockNarrativeFlowState`, ≥14 `EPvpFlowState`; 0 = chain broken (loading) |
| `flowRecordCount` | `ActiveStateMachines.Num` (`…0xC8`) | int | verified field | expect 1; if the paddock ever shows 2, record 0 may not be the one we want |
| `primaryFlow` | `UGfnGameInstance.PrimaryFlow` (`GWorld, 0x228, 0x398`) | byte | lead | `EGfnPrimaryFlow`: Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4. Debug only — no profile gates on it |

State ids that matter (full enums in `Griffin_enums.hpp`):

- `ESimpleRaceGameModeState` (37): LoadingPhase 1, WaitForLevelToLoad 10, WaitForClientsToBeReady 11,
  PreRacePhase 12, IntroSequence 13, PrepareForEventStart 3, IgnitionSequence 17, RollingStart 18,
  Countdown 4, **Racing 5**, IntermissionPhase 23, PostRacePhase 6, Outro 14, **Results 15**,
  PrepareToLeave 30, **Leaving 8**, Invalid 255.
- `EFrontEndFlowState` (16): Root 0, **PrimaryModeSelect 1**, LaunchingCampaign 2, QuickRaceSetup 3,
  LaunchingQuickRace 4, Boot 11, PreLoadBoot 12.
- `EPaddockFlowState` (9): Root 0, Intro 1, **CampaignSetup 2**, PreWorld 3, **InWorld 4**, Leaving 5,
  WipeToBlackBeforeLeaving 6.

**A. `ARacingGameState`** (`GWorld, 0x1B0`) — valid only while `FlowMachine == Race`; otherwise the
same offsets point into a menu GameState and read garbage.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `raceStarted` | bIsRaceStarted | byte | have | grid-start "go" |
| `raceFinished` | bIsRaceFinished | byte | verified | player-based (local player's finish) |
| `totalLaps` | LapCount | int | have | sanity gate + lap split bound. **100 in Elimination** campaign events (run until top 3 remain) |
| `raceStartTime` | RaceStartTime | double | have | base for lap-split IGT; dead-race guard |
| `countdownEndTime` | CountdownEndTime | double | verified | server-time stamp on the `raceStartTime` clock (e.g. 1670.018), not a seconds-left counter; cross-check for grid starts |
| `activeStage` | EventRecipeState.ActiveStage | int | verified | 0-indexed stage in the recipe (Scenarios?) |
| `stageCount` | EventRecipe.EventStages.Num | int | verified | TArray count at `0x3F8 + 0x8` |

(`raceFlowState` moved to A0 as `flowState` — it is not specific to the race GameState.)

**B. `URaceEventVM`** (HUD view model, `GWorld, 0x1B0, 0x3D8`) — pointer is 0 outside a race.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `hudVM` | (the pointer) | long | have | presence = HUD exists |
| `hudLap` | CurrentLapNumber | int | have | starts at 1 |
| `hudNumLaps` | NumLaps | int | verified | matches `totalLaps`; 100 in Elimination (hidden on the HUD) |
| `hudLapTime` | CurrentLapTime | double | verified | raw lap IGT, resets per lap |
| `hudEventTime` | CurrentEventTime | double | verified | running event IGT, gate deductions applied in Precision Driving arcade races |
| `hudModeType` | ModeType | byte | verified | `ERaceEventModeType`; TimeTrial 2 seen live, Precision = 8 |
| `trackNamePtr` / `trackNameLen` | track → InternalName (FString) | ptr/int | partial | resolves for Time Trial / Podracing, bad pointer in Precision; campaign gives only the map (`DAL_SHORT_06`). Use `stageName` instead |
| `hudSuccess` | bIsSuccess | byte | verified | finish outcome |

**C. `UPlayerRaceEventComponent`** (local player, chain `…0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368`).

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `playerLap` | CurrentLapNumber | int | have | 0 until first crossing; LapCount+1 after finish; 0 after leaving |
| `finished` | bHasFinishedEvent | byte | have | end trigger for every category |
| `finishTime` | EventFinishTime | float | have | −1 until finish; results-screen time (adjusted for Precision) |
| `bonusTime` | BonusTime | float | verified | Precision gate deductions, 1.5 per gate |
| `lapStartServerTime` | LapStartServerTime | double | have | stamp at each crossing; dead-race guard |
| `eventPosition` | EventPosition | int | verified | finish position (campaign "must win"?) |
| `failReasons` | FailReasons | byte | verified | bitflags |
| `wrecked` | bHasVehicleWrecked | byte | verified | 1 = wrecked out of the race for good |
| `timedOut`, `eliminated` | bHasTimedOut, bHasBeenEliminated | byte | lead | |
| `bestLapTime`, `prevLapTime` | | float | verified | display only |

**D. Event identity** (`EventRecipe.EventStages[ActiveStage]`, `FRaceEventInstance`). Chain is
`GWorld, 0x1B0, 0x3F8, <field>` — the elements are inline (0x308 bytes each), so **no** `0x0` deref
after the data pointer (the earlier `…0x3F8, 0x0, …` chains were wrong). Stage N = data ptr + N × 0x308.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `stageNamePtr` / `stageName` | FRaceEventInstance.InternalName (FString, UTF-16) | ptr/string | verified | stable event ID for M6 / M7 in every mode seen: arcade `EVT_ARC_PRE_BIKE_MAS_A_FWD`, `EVT_ARC_TMR_PLANE_BGL_PLANE_FWD`; campaign `DAL_SHORT_06_TeamRace_Dry`. (`stageNameLen` still lead) |
| `arcadeCategory` | AuthoredEvent → `UArcadeEventDef.Category` | byte | verified (arcade) | `EArcadeEventCategories`; Plane 2 seen live. Undefined in campaign (not an arcade def) |
| `authoredEvent` | FRaceEventInstance.AuthoredEvent | ptr | lead | class check (arcade vs campaign def) |
| `skipCountdown` | URaceEventDef.bShouldSkipCountdown | byte | verified (arcade) | rolling vs grid start, straight from the def. Undefined in campaign |
| `stageLapCount` | FRaceEventInstance.LapCount | byte | verified | matches `totalLaps` (100 in Elimination) |

**E. Campaign** (`UCampaignSubsystem`, chain TBD — `UGfnGameInstance::GetCampaignManager()`).
No profile needs any of these any more: the campaign categories start on leaving the menu (S3 /
S4) and end on the final event's `stageName` (E4 / E5). Kept as Debug leads.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `playingPrologue` | bIsPlayingPrologue | byte | verified | 0→1 on New Campaign *and* on reset Accept (M1, M2) |
| `activeRun` | ActiveRun | ptr | verified | null→ptr on Act III loadout Continue (M3); check other flips |
| `campaignAct` | MetaProgression → MainCampaignCurrentTourIx | int | lead | Act III index value TBC |
| `campaignDifficulty` | MetaProgression → LastPickedDifficulty | ptr/enum | lead | Champion% warning only (M10) |
| `continueRunState` | `EContinueRunState` | byte | lead | Paddock / StartEvent / PostEvent / LeavePlanet; between-race phases |

**F. Front end / menus.** Superseded by A0: every menu press that starts a run is a departure
from the `FrontEnd` / `Paddock` machine. M4 / M5 are closed as memory hunts.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `medalResult` | results / goal state | ? | deferred | M8. Not an MVP check (the moderator sees the medal); only if runners ask for it, as one more `&&` on E3 |

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
| `FlowMachine` | string | `Race` / `FrontEnd` / `Paddock` / `PaddockNarrative` / `Pvp` from `flowEnumCount`; `None` when 0 (chain broken: level load); `Unknown` otherwise | verified |
| `FlowState` | int | `flowState`, only meaningful with `FlowMachine` | verified |
| `Flow` | string | `FlowMachine + "." + FlowState`, e.g. `Race.5`, `Paddock.4`, `None` — the key edges are detected on | verified |
| `HudVmPresent` | bool | HUD view model pointer resolved | have (`hudVM != 0`) |
| `LapsSane` | bool | `totalLaps` in (0, 100] and `playerLap` in range (100 = Elimination) | have (v0.4.1 bound is `< 100`, BUGS.md #3) |
| `InRace` | bool | local player is in a live race | have |
| `LapsInSync` | bool | `hudLap == playerLap + 1` | have |
| `RaceGo` | bool | `raceStarted` is set (grid released) | have (raw) |
| `Finished` | bool | player crossed the final line | have (raw) |
| `Failed` | bool | timed out / wrecked / eliminated / fail flags | lead |
| `Paused` | bool | game is paused | lead |
| `Loading` | bool | `FlowMachine == None`, or `Race ∈ {LoadingPhase 1, WaitForLevelToLoad 10, WaitForClientsToBeReady 11}` | verified readings |
| `InMenu` | bool | `FlowMachine ∈ {FrontEnd, Paddock, PaddockNarrative}` | verified readings |
| `EventKind` | enum | TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown — debug / mismatch warning only, never drives behaviour | lead |
| `EventId` | string | stable event name (Landspeeder Ace, The Experiment, Sebulba final, …) | lead |
| `MapId` | string | track internal name | lead |
| `StageIndex`, `StageCount`, `IsLastStage` | int / bool | multi-stage recipe position | lead |
| `LapIgt` | double | raw running lap time | verified |
| `EventIgt` | double | running event time, Precision Driving checkpoint-adjusted | verified |
| `FinishIgt` | double | final event time (≥ 0 only after finish) | have |
| `GateBonus`, `GatesHit` | double / int | Precision driving deductions and count | verified |
| `CampaignAct`, `CampaignRunActive`, `PrologueFlag` | int / bool / bool | campaign Act, `activeRun != 0`, `playingPrologue` — Debug only, no profile reads them | lead / verified |
| `RaceStamp` | double | `raceStartTime` (identity of this race instance) | have |
| `LapStamp` | double | `lapStartServerTime` | have |

### Run state (`vars.Run`, persists across ticks and races)

| Field | Meaning | Set by |
|---|---|---|
| `Profile` | the active category profile (see **Category profiles**) | the Category setting, re-read on settings change |
| `Phase` | `Idle` → `Running` → `Done`. Nothing finer: where the game is comes straight from `Flow` (Debug prints every transition) rather than being mirrored into a phase | start / end |
| `EventsDone` | races or events completed in this run | end-of-race edge |
| `IgtTotal` | sum of `FinishIgt` over completed races | end-of-race edge |
| `LastEventId`, `LastMapId` | identity of the race last entered | race-entry edge |
| `LastFinishedEventId` | which event finished last — a second finish of the same event does not split (see **End States**) | end-of-race edge |
| `DeadRaceStamp`, `DeadLapStamp` | timestamps of the torn-down race (BUGS.md #2) | teardown edges |

### Settings

- **Category** (pick one): Arcade Time Trial, Precision Driving, Tales of Podracing,
  Arcade Scenarios, Arcade%, Sebulba%, Any%, NG+ Sebulba%, NG+ Any%, NG+ Champion%,
  NG+ Act III. One entry each; the profile table maps them. No auto-detect: if more than
  one is ticked, use the first and print a warning in Debug.
- **Splits**: lap splits (IL), per-event splits (run-length), finish split.
- **Reset**: on leaving the race. IL only — run-length profiles never auto-reset (going back
  to the menu between events is normal play, and a wrong start is the runner's reset).
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
| `IsRaceGameState(s)` | does GameState look like an `ARacingGameState`? | `FlowMachine == Race` (v0.4.1 used `LapsSane` as a proxy; keep it as a belt-and-braces `&&`) | verified | everything that reads group A/B/D |
| `InRace(s)` | is the local player in a live race? | `HudVmPresent && LapsSane` — unchanged; `Flow ∈ Race.{4,5,18}` is the cross-check, not a replacement, because the crossing-based ILs must not change behaviour | have | split, reset, Race start |
| `InRaceStrict(s)` | …and lap counters agree? | `InRace && LapsInSync` | have | grid starts |
| `IsPaused(s)` | is the game paused? | `pauserPlayerState != 0` | lead | isLoading (optional), debug |
| `IsLoading(s)` | between levels / race not live? | `FlowMachine == None`, or `Race ∈ {1, 10, 11}` | verified readings | Debug; load removal if ever ruled in |
| `InMenu(s)` | front end, paddock or paddock cutscene — not a race, not a load? | `FlowMachine ∈ {FrontEnd, Paddock, PaddockNarrative}` | verified readings | `MenuLeaveEdge` (S3) |
| `IsTearingDown(p, n)` | did the race we were in just go away? | `p.FlowMachine == Race && (n.FlowMachine != Race || n.FlowState ∈ {PrepareToLeave 30, Leaving 8})`; v0.4.1's `p.playerLap ≥ 1 && n.playerLap == 0` stays as the fallback | have (reset) | reset, dead-stamp capture |

### Edges ("what just happened?")

| Function | Fires when | Status | Used by |
|---|---|---|---|
| `RaceGoEdge(p, n)` | `raceStarted` 0→1 with `InRaceStrict(n)` and fresh `RaceStamp` | have | Podracing, Scenario races, campaign races |
| `FirstCrossingEdge(p, n)` | `playerLap` 0→1, `!Finished`, `LapsSane`, fresh `LapStamp` | have | Time Trial, Precision (rolling starts) |
| `LapEdge(p, n)` | `playerLap` n→n+1, 1 ≤ n < `totalLaps`, `!Finished` | have | lap splits, lap IGT re-sync |
| `FinishEdge(p, n)` | `finished` 0→1 | have | every end state, race splits |
| `FailEdge(p, n)` | `Failed` false→true | lead | Debug only — no reset policy uses it (an IL retry goes through R1) |
| `RaceEnteredEdge(p, n)` | `!p.InRace && n.InRace` with a new `RaceStamp` | have (refactor) | run bookkeeping (`LastEventId`) |
| `NewRaceInstance(p, n)` | `RaceStamp`/`LapStamp` differ from `Run.Dead*` | have (inline) | guards every race-value start edge |
| `FlowEdge(p, n)` | `p.Flow != n.Flow` — any flow transition | verified readings | debug log, everything below |
| `FlowEnter(p, n, machine, state)` | `n.Flow == machine.state && p.Flow != n.Flow` | have (refactor) | S4, Debug cross-checks |
| `FlowLeave(p, n, machine, state)` | `p.Flow == machine.state && n.Flow != p.Flow` | have (refactor) | S4 |
| `MenuLeaveEdge(p, n)` | `InMenu(p) && !InMenu(n)` — the menu machine gave way to `Race` or to `None` (level load). Any "Start Event" / "Start" / "New Campaign" / reset-Accept press, within one poll | verified readings | S3 |
| `ActIIIStartRunEdge(p, n)` | `FlowLeave(Paddock, CampaignSetup 2)` landing in `Paddock.{PreWorld 3, InWorld 4}` — "Start Run" after the loadout check. No Act or `activeRun` check | verified flow; 2→3→4 vs 2→4 TBC | S4 |
| `PrologueEdge(p, n)` | `playingPrologue` 0→1 | verified | Debug cross-check for the campaign S3 only |
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

Note on `RunGameTime`: this single formula covers ILs (`IgtTotal` = 0) and run-length runs,
and it is naturally paused during loads and menus because `EventIgt` isn't advancing. It
makes `isLoading{}` simply `!InRace || Finished`. Whether to also use it *live* inside a race
(instead of real time + re-sync at crossings) depends on `hudEventTime` being smooth at 60 Hz;
BUGS.md #1 originally read garbage at that offset, `NOTES.md` now says verified — test it.

### Identity ("which race / event is this?")

| Function | Returns | Definition | Status | Used by |
|---|---|---|---|---|
| `MapId(s)` | track internal name | FString at HUD VM → track → InternalName | partial (bad in Precision; map only in campaign) | display, Scenario / campaign race recognition |
| `EventId(s)` | stable event name | `stageName` (`FRaceEventInstance.InternalName`) | verified chain | Arcade% (Landspeeder Ace, The Experiment), Sebulba / Kestar finals |
| `EventKind(s)` | TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown | `arcadeCategory` if `authoredEvent` is an arcade def (Plane→Podracing, Precision→Precision, else TimeTrial); campaign if `CampaignRunActive`; Scenario if recipe has >1 stage and not campaign | lead | **optional**: Debug warning when the loaded event doesn't match the chosen category. Never selects behaviour |
| `IsLastStage(s)` | last race of a multi-stage recipe? | `StageIndex == StageCount − 1` (0-indexed) | verified readings | Scenarios end (M9) |
| `IsEvent(s, name)` | is this the named event? | `EventId(s) == name` | chain verified; names TBC | E3, E4, E5 |
| `IsRepeatFinish(s)` | is this a second finish of the event finished last? | `EventId(s) == Run.LastFinishedEventId` | — | per-event split dedupe |

### Run bookkeeping (called from `update{}`)

| Function | Does | Status |
|---|---|---|
| `CaptureDeadStamps(p, n)` | on `IsTearingDown`, store `RaceStamp` / `LapStamp` into `Run.Dead*` | have |
| `OnRaceEntered(p, n)` | set `Run.LastEventId` / `LastMapId` / `LastRaceStamp` | have (refactor) |
| `OnRaceFinished(p, n)` | `IgtTotal += FinishIgt` always; if `!IsRepeatFinish(n)`: `EventsDone++`, split-worthy; then `LastFinishedEventId = EventId` | have (refactor), dedupe pending |
| `ResetRun()` | clear all of the above | — |

## Start States

Each category profile picks exactly one. Two families (see *What the script is for*):

- **Crossing / grid starts** (S1, S2): the IL categories are ranked by IGT and the start must be
  the exact line crossing or grid release. The flow machine is not precise enough for these
  (60 Hz poll vs a server-time stamp) and they stay exactly as in v0.4.1, guarded by
  `NewRaceInstance` and `Run.Phase == Idle`.
- **Menu-leave starts** (S3, S4): the run-length categories start from a button press in a
  menu, and the press is a flow transition. The timer starts on the tick the edge is seen —
  that is the RTA start, and the runner sees it start. Where the game goes next is not
  checked: the chain reading `None` through the level load *is* "not in a menu any more".

| # | Trigger | Edge | Extra gate | Categories | Status |
|---|---|---|---|---|---|
| S1 | First start-line crossing (rolling start) | `FirstCrossingEdge` | — | Arcade Time Trial, Precision Driving | have |
| S2 | Grid released (countdown over) | `RaceGoEdge` | `InRaceStrict` | Tales of Podracing | have |
| S3 | Left the menu ("Start Event", scenario "Start", "New Campaign", reset-Accept) | `MenuLeaveEdge` | — | Arcade%, Arcade Scenarios, Sebulba%, Any%, NG+ Sebulba%, NG+ Any%, NG+ Champion% | verified readings |
| S4 | Act III "Start Run" → loadout → Continue | `ActIIIStartRunEdge` (`Paddock.2 → 4`, or `→ 3`) | — | NG+ Act III | verified flow; 2→3→4 vs 2→4 TBC |

Notes:
- S3 is deliberately broad. Launching anything from the main menu or the paddock starts the
  timer when it is not running; that is how every autosplitter's "new game" start behaves, and
  casual play with LiveSplit open is not a case to design for. The expected first event
  (Landspeeder Ace, the first scenario race, the prologue) is the moderator's check, not ours.
- S3 for the NG+ campaign categories depends on where the reset-Accept press happens. From the
  main menu it is `FrontEnd → None`; from the paddock it is `Paddock → None`. Both are
  `MenuLeaveEdge`, so the profile does not care, but record the sequence once to confirm
  neither passes through a non-menu machine first.
- `PaddockNarrative` counts as a menu machine so a paddock cutscene cannot fire S3.
- S1 keeps its deliberate *non*-gating on the HUD VM (NOTES v0.1.0). If the snapshot layer
  makes that fragile, add a `PendingStart` latch: set on the raw edge, fire on the first tick
  where `InRace`.
- S3 and S4 fire in a menu, so the first race's `RaceGoEdge` is never a start for those
  profiles.

Latch-and-confirm (arming on the press, confirming the arrival by `EventId`, backdating via
`timer.Run.Offset`, the "trust but verify" variant and its reset) was designed and then
dropped: it only existed to police which event the press led to, which is the moderator's job,
and it made the timer visibly do nothing on the press.

## End States

All built on `FinishEdge` plus one identity comparison. `OnRaceFinished` runs first so the
finish split's Game Time is `IgtTotal` including this race.

| # | Trigger | Condition | Categories | Status |
|---|---|---|---|---|
| E1 | Final-lap finish of the only race | `FinishEdge` | Arcade Time Trial, Precision Driving, Tales of Podracing | have |
| E2 | Finish of the scenario's last race | `FinishEdge && IsLastStage` | Arcade Scenarios | verified readings (M9 = `activeStage` / `stageCount`) |
| E3 | Finish of *The Experiment* | `FinishEdge && IsEvent(TheExperiment)` | Arcade% | event name TBC |
| E4 | Finish of the Sebulba final (last race of Act I) | `FinishEdge && IsEvent(SebulbaFinal)` | Sebulba%, NG+ Sebulba% | event name TBC |
| E5 | Finish of the Kestar's Podracer final (last race of Act III) | `FinishEdge && IsEvent(KestarFinal)` | Any%, NG+ Any%, NG+ Champion%, NG+ Act III | event name TBC |

No medal check on E3 and no Act check on E4 / E5: the moderator sees both. If runners ask for
a medal check later it is one more `&&` on E3 against `medalResult` (M8), which is why that
lead stays in the readings list.

A `FinishEdge` that is not the end condition is a per-event split (if enabled) **once per
`EventId`**: a second finish of the event finished last (redoing an event for a better result)
adds its IGT to `IgtTotal` but does not split, so the split list stays in step with the route.
Whether the redo's IGT should count is a rules question (see **Open items**); counting it is the
default because the IGT column is meant to be driving time with loads and menus removed.

The finish stays on `FinishEdge` (a line crossing) for the same precision reason as S1/S2.
`FlowEnter(Race, Results 15)` is a Debug cross-check that the finish was seen, not a trigger.

## Reset / ignore states

The current single-race reset (`ResetOnLeave`) is wrong for every run-length category:
between events the HUD VM goes away, `playerLap` drops to 0 and `raceStarted` drops to 0 —
all three of today's reset conditions fire. The two families therefore differ completely.

| # | Condition | IL profiles | Run-length profiles |
|---|---|---|---|
| R1 | `IsTearingDown` before `Finished` (race machine left, or entered `PrepareToLeave 30` / `Leaving 8`; v0.4.1's raw conditions as the fallback) | reset (if `ResetOnLeave`) | no-op |
| R2 | `IsTearingDown` after `Finished` | no-op (run is over) | no-op (expected between events) |
| R3 | Back to the main menu, a fresh S3 / S4 edge while running, a wrong first event, a failed race | — | **no-op**. Run-length profiles never reset the timer; the runner does |
| R4 | `CategoryChanged` | `ResetRun()` (run state, not the timer) | same |

Dead-stamp capture (`CaptureDeadStamps`) runs on every teardown regardless of policy, since
the false-start / false-finish replay in BUGS.md #2 happens on every transition, including the
ones between Scenario races. That guard protects against the game's memory, not the runner,
and is the one piece of checking that stays in both families.

## Category profiles

| Category | Family | Ranked by | Game Time column | Start | Splits | End |
|---|---|---|---|---|---|---|
| Arcade Time Trial | IL | IGT | `FinishIgt` | S1 | laps | E1 |
| Precision Driving | IL | IGT (adjusted) | `FinishIgt` (already adjusted) | S1 | laps | E1 |
| Tales of Podracing | IL | IGT | `FinishIgt` | S2 | laps | E1 |
| Arcade Scenarios | run-length | RTA | `IgtTotal` | S3 | event (+ laps optional) | E2 |
| Arcade% | run-length | RTA | `IgtTotal` | S3 | event, once per `EventId` | E3 |
| Sebulba% / Any% | run-length | RTA | `IgtTotal` | S3 | event (optional) | E4 / E5 |
| NG+ Sebulba% / Any% / Champion% | run-length | RTA | `IgtTotal` | S3 | event (optional) | E4 / E5 |
| NG+ Act III | run-length | RTA | `IgtTotal` | S4 | event (optional) | E5 |

Profile record fields: `Family` (IL / run-length), `Start(p, n)`, `StartStamp` ("Lap" / "Race" /
"None" — which dead stamp the BUGS.md #2 guard checks for this start), `IsEnd(p, n)`,
`SplitOnLap`, `SplitOnRace`, and optionally `ExpectedEventKind` (Debug-only warning when the
loaded event doesn't match the chosen category — it never changes what the script does). Reset
policy and Game Time (`RunGameTime`) follow from `Family`.

Campaign splits: the campaign has non-race events, so per-event splits may not match how
runners think of the route; "leaving a planet" is a flow edge too (paddock `Leaving 5` /
`WipeToBlackBeforeLeaving 6`, or `continueRunState` = LeavePlanet). Which to offer is a route
question — leave it until someone asks. The only must-split is the end condition.

## Migration order

Each step keeps the script shippable; ILs must not regress.

0. ✅ Skeleton: function stubs, variables, placeholders where they do not exist.
1. ✅ Introduce the snapshot layer and move the existing lambdas (`InRace`, `LapsSane`,
   `LapsInSync`) and dead-stamp capture onto it. Add the A0 readings and `FlowMachine` /
   `Flow` to the snapshot with a Debug line on every `FlowEdge` — read-only, so behaviour stays
   identical to v0.4.1 while the state sequences for each category get recorded.
2. ✅ Extract the edges (`RaceGoEdge`, `FirstCrossingEdge`, `LapEdge`, `FinishEdge`) and the
   timing functions; rewrite `start{}` / `split{}` / `gameTime{}` against them.
   `IsRaceGameState` / `IsTearingDown` have their flow definitions, but the IL `reset{}` still
   uses the verbatim v0.4.1 raw conditions — the flow versions take over in step 5.
3. ✅ Add `vars.Run` and `RunGameTime`; `IgtTotal` is 0 for ILs so nothing changes yet.
   `OnRaceFinished` owns the `IgtTotal` add; `gameTime{}` returns the total on the finish tick.
4. ✅ Add profiles for the three IL categories (Time Trial, Precision, Podracing). Needs no new
   memory: Precision already works through the adjusted `finishTime`. Profiles carry a
   `StartStamp` ("Lap" / "Race" / "None") so the BUGS.md #2 guard checks the same stamp v0.4.1
   did for each start kind.

   Steps 1–4 landed 2026-10-19 in `SWGR_Autosplitter_Refactor.asl` (0.5.0-dev), **untested in
   LiveSplit**. Intended differences from v0.4.1, and nothing else: `LapsSane` accepts 100 laps
   (BUGS.md #3); with ResetOnLeave off and a running timer reused across races, Game Time is the
   IGT *sum* rather than the last race's time. The script still carries the latch-and-confirm
   scaffolding from the earlier plan (`ArmedAt` / `ArmedFrom`, `MenuStartTrust`, the `Armed` /
   `InRace` / `Between` phases, the `ArrivalConfirmEdge` / `ArrivalWrongEdge` stubs); step 5
   removes it.
5. Run-length family, Arcade% first — it can be tested by finishing Landspeeder Ace and
   skipping to The Experiment: `MenuLeaveEdge`, `PaddockNarrative` in `InMenu`, the dedupe in
   `OnRaceFinished`, `SplitOnRace`, `Family`-driven reset (none) and `isLoading`, `Phase`
   collapsed to Idle / Running / Done, E3 by `stageName`. Needs the internal name of The
   Experiment. Scenarios (E2) come with it once `IsLastStage` is wired. Mostly deletion.
6. Campaign categories: S3 is already there; E4 / E5 need the Sebulba and Kestar final
   `stageName`s. NG+ Act III: S4 once the `Paddock.2 → 4` sequence is recorded.
7. Separately: `IsPaused`, live `EventIgt` as the in-race Game Time, versioned `state` blocks.
   Only if asked: medal check on E3 (M8), per-planet campaign splits.

## Open items this plan depends on

- Event names (`stageName`): The Experiment, the Sebulba final, the Kestar final. Confirm ASL
  `string` reads auto-detect UTF-16.
- Flow machine, still to record live: the sequence after Arcade "Start Event" (`FrontEnd.1 →
  4 → None` or straight to `None` — either fires S3; this is for the Debug log), the
  campaign-reset Accept (from the main menu or the paddock, see the S3 notes), Act III "Start
  Run" (`Paddock.2 → 3 → 4` or `2 → 4`); whether `PaddockNarrative` shows up in normal paddock
  play; `flowRecordCount` in the paddock; `BlueprintCreatedComponents[0]` is the GFSM component
  in all three GameState Blueprints (verified in the race GameState and whichever menu state the
  count was read in; check the third).
- Elimination events: `totalLaps` = 100. `LapsSane` must allow 100 (v0.4.1 uses `< 100`, see
  BUGS.md #3), and lap splits / the end condition need checking there (the event ends on
  elimination, not on lap 100).
- Scenarios: confirm `activeStage` / `stageCount` behave across the five races (M9).
- Game Time for a repeated event (Arcade% redo): the plan adds every finished attempt's IGT to
  `IgtTotal`. If the mods want only the counting attempt, it is a one-line change in
  `OnRaceFinished`; ask when the IGT column is agreed.
- Rules questions for the mods: Scenario start point; plain RTA vs load-removed; NG+ Champion%
  from a fresh save.
- Deferred leads, no profile needs them: `primaryFlow`; the `UCampaignSubsystem` chain
  (`playingPrologue`, `activeRun`, `campaignAct`); `medalResult` (M8); pause flag
  (`PauserPlayerState`); the `EventKind` warning; whether `hudEventTime` is smooth enough at
  60 Hz to be the live Game Time.
