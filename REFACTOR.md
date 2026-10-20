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
| `primaryFlow` | `UGfnGameInstance.PrimaryFlow` (`GWorld, 0x228, 0x398`) | byte | lead | `EGfnPrimaryFlow`: Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4. Cheap sanity gate per profile |

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

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
| `playingPrologue` | bIsPlayingPrologue | byte | verified | 0→1 on New Campaign *and* on reset Accept (M1, M2) |
| `activeRun` | ActiveRun | ptr | verified | null→ptr on Act III loadout Continue (M3); check other flips |
| `campaignAct` | MetaProgression → MainCampaignCurrentTourIx | int | lead | Act III index value TBC |
| `campaignDifficulty` | MetaProgression → LastPickedDifficulty | ptr/enum | lead | Champion% warning only (M10) |
| `continueRunState` | `EContinueRunState` | byte | lead | Paddock / StartEvent / PostEvent / LeavePlanet; between-race phases |

**F. Front end / menus.** Mostly superseded by A0: "Start Event" / scenario start are departures
from `FrontEnd.PrimaryModeSelect`, and "which event was selected" is answered by `stageName` once
the race loads (see **Start States**, latch-and-confirm). M4 / M5 are closed as memory hunts.

| Reading | Field | Type | Status | Notes |
|---|---|---|---|---|
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
| `InMenu` | bool | `FlowMachine ∈ {FrontEnd, Paddock}` | verified readings |
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
| `Phase` | `Idle` → `Armed` (menu start seen, no race yet) → `InRace` → `Between` (race done, next not loaded) → `Done`. Apart from `Armed` and `Done` this is a **projection of `Flow`**, not something inferred from race values: `FrontEnd.*` ⇒ Idle, `Race.{4,5,18}` ⇒ InRace, `Race.{6,14,15,30,8}` / `Paddock.*` / `None` ⇒ Between | start / finish / flow edges |
| `ArmedAt`, `ArmedFrom` | wall-clock stamp and `Flow` key of the menu departure that armed the run (latch-and-confirm) | menu-press start edges |
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
- **Menu start policy** (RTA categories that start from a menu press): *start on arrival,
  backdated* (default: timer appears once the race machine confirms the event, with
  `timer.Run.Offset` set so it reads from the press) vs *start on press, trust but verify* (timer
  starts the instant the menu is left; reset if the game lands somewhere other than the expected
  event). Same stamp either way; the switch only decides when the timer becomes visible. Expect
  to revisit the default after runner feedback — a timer that doesn't visibly start on the
  press reads as "it didn't work".
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
| `IsLoading(s)` | between levels / race not live? | `FlowMachine == None`, or `Race ∈ {1, 10, 11}` | verified readings | multi-event transitions, latch-and-confirm, load removal if ever ruled in |
| `InMenu(s)` | front end or paddock, not a race, not a load? | `FlowMachine ∈ {FrontEnd, Paddock}` | verified readings | menu-press starts, R4 |
| `IsTearingDown(p, n)` | did the race we were in just go away? | `p.FlowMachine == Race && (n.FlowMachine != Race || n.FlowState ∈ {PrepareToLeave 30, Leaving 8})`; v0.4.1's `p.playerLap ≥ 1 && n.playerLap == 0` stays as the fallback | have (reset) | reset, dead-stamp capture |

### Edges ("what just happened?")

| Function | Fires when | Status | Used by |
|---|---|---|---|
| `RaceGoEdge(p, n)` | `raceStarted` 0→1 with `InRaceStrict(n)` and fresh `RaceStamp` | have | Podracing, Scenario races, campaign races |
| `FirstCrossingEdge(p, n)` | `playerLap` 0→1, `!Finished`, `LapsSane`, fresh `LapStamp` | have | Time Trial, Precision (rolling starts) |
| `LapEdge(p, n)` | `playerLap` n→n+1, 1 ≤ n < `totalLaps`, `!Finished` | have | lap splits, lap IGT re-sync |
| `FinishEdge(p, n)` | `finished` 0→1 | have | every end state, race splits |
| `FailEdge(p, n)` | `Failed` false→true | lead | retry handling (Arcade%, NG+ Sebulba%) |
| `RaceEnteredEdge(p, n)` | `!p.InRace && n.InRace` with a new `RaceStamp` | — | run bookkeeping (`LastEventId`), Scenario race counting |
| `NewRaceInstance(p, n)` | `RaceStamp`/`LapStamp` differ from `Run.Dead*` | have (inline) | guards every race-value start edge |
| `FlowEdge(p, n)` | `p.Flow != n.Flow` — any flow transition | verified readings | debug log, everything below |
| `FlowEnter(p, n, machine, state)` | `n.Flow == machine.state && p.Flow != n.Flow` | verified readings | S4, R4, phase projection |
| `FlowLeave(p, n, machine, state)` | `p.Flow == machine.state && n.Flow != p.Flow` | verified readings | S3, S5, S6 |
| `PrologueEdge(p, n)` | `playingPrologue` 0→1 | verified | Sebulba%, Any%, NG+ ×3 (which of new / reset is the profile's business) |
| `ActIIIStartRunEdge(p, n)` | `FlowEnter(Paddock, InWorld 4)` from `Paddock.{2, 3}` with `CampaignAct == ActIII`; `activeRun` null→ptr confirms it is a run start rather than a resume | verified flow / lead gates | NG+ Act III |
| `MenuDepartureEdge(p, n)` | `FlowLeave(FrontEnd, PrimaryModeSelect 1)` — the "Start Event" / scenario start press, within one poll | verified readings; exact sequence after the press TBC | Arcade%, Scenarios (arms the run) |
| `ArrivalConfirmEdge(p, n, eventId)` | `Run.Phase == Armed && FlowEnter(Race, *) && EventId == eventId` — the race machine appeared and it is the expected event | verified readings | Arcade%, Scenarios (confirms / cancels the arm) |
| `ArrivalWrongEdge(p, n)` | `Run.Phase == Armed && (FlowEnter(FrontEnd, *) || (FlowMachine == Race && EventId known && != expected))` | verified readings | drops the arm, or resets under "trust" |
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
| `MapId(s)` | track internal name | FString at HUD VM → track → InternalName | partial (bad in Precision; map only in campaign) | display, Scenario / campaign race recognition |
| `EventId(s)` | stable event name | `stageName` (`FRaceEventInstance.InternalName`) | verified chain | Arcade% (Landspeeder Ace, The Experiment), Sebulba / Kestar finals |
| `EventKind(s)` | TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown | `arcadeCategory` if `authoredEvent` is an arcade def (Plane→Podracing, Precision→Precision, else TimeTrial); campaign if `CampaignRunActive`; Scenario if recipe has >1 stage and not campaign | lead | **optional**: Debug warning when the loaded event doesn't match the chosen category. Never selects behaviour |
| `IsLastStage(s)` | last race of a multi-stage recipe? | `StageIndex == StageCount − 1` (0-indexed) | verified readings | Scenarios end (M9) |
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

Each category profile picks exactly one. Two families:

- **Crossing / grid starts** (S1, S2): the IL categories are ranked by IGT and the start must be
  the exact line crossing or grid release. The flow machine is not precise enough for these
  (60 Hz poll vs a server-time stamp) and they stay exactly as in v0.4.1, guarded by
  `NewRaceInstance` and `Run.Phase == Idle`.
- **Flow-edge starts** (S3–S6): the RTA categories start from a button press in a menu, and the
  press is a flow transition. Two sub-cases: an edge *within one machine* (S4, paddock) is a
  clean single-tick event; an edge that *crosses a level load* (S5, S6 and the campaign launch)
  is observed as `FrontEnd.1 → None → Race.1 → … → Race.13` and needs latch-and-confirm.

| # | Trigger | Edge | Extra gate | Categories | Status |
|---|---|---|---|---|---|
| S1 | First start-line crossing (rolling start) | `FirstCrossingEdge` | — | Arcade Time Trial, Precision Driving | have |
| S2 | Grid released (countdown over) | `RaceGoEdge` | `InRaceStrict` | Tales of Podracing | have |
| S3 | New campaign / campaign reset confirmed | `PrologueEdge`; cross-check `FlowLeave(FrontEnd, 1)` → `FrontEnd.2 LaunchingCampaign` for a new campaign (reset-Accept sequence not yet recorded) | — | Sebulba%, Any%, NG+ Sebulba%, NG+ Any%, NG+ Champion% | verified field, chain TBD |
| S4 | Act III "Start Run" → loadout → Continue | `ActIIIStartRunEdge` (`Paddock.2 → Paddock.4`) | `CampaignAct == ActIII`; `activeRun` flip as confirmation | NG+ Act III | verified flow; Act index TBC |
| S5 | Arcade "Start Event" on Landspeeder Ace | `MenuDepartureEdge` arms; `ArrivalConfirmEdge(LandspeederAce)` confirms | `primaryFlow == Arcade` (lead) | Arcade% | verified readings; press sequence + event name TBC |
| S6 | Scenario start | `MenuDepartureEdge` arms; `ArrivalConfirmEdge(first scenario event)` confirms | `stageCount > 1` on arrival | Arcade Scenarios | verified readings; rule TBD with mods |

S7 (first race's go as a fallback) is gone: the flow edges make it unnecessary.

**Latch-and-confirm** (S5, S6, and S3 if the campaign launch turns out to need it):

1. `MenuDepartureEdge`: stamp `Run.ArmedAt = DateTime.Now`, `Run.ArmedFrom = p.Flow`,
   `Phase = Armed`. Under the *trust* policy the timer starts on this tick.
2. While `Armed`: the chain reads `None` through the load, then `Race.1/10/11/12/13…`. Nothing
   fires until `EventId` is readable (`stageName` is populated with the GameState, so by
   `Race.1` at the latest).
3. `ArrivalConfirmEdge(expected)`: under the *backdated* policy, start now with
   `timer.Run.Offset = -(DateTime.Now − ArmedAt)` so the displayed time reads from the press.
   Under *trust*, nothing to do. Either way `Phase` follows the race machine from here.
4. `ArrivalWrongEdge`: landed back in `FrontEnd.*`, or in a race whose `EventId` isn't the
   expected one. *Backdated*: drop the arm, `Phase = Idle`. *Trust*: reset the timer (R7).

The two policies share every edge and stamp; the setting only decides whether the timer is
visible during the load. Start with *backdated* (never shows a time that is later taken back),
and switch the default if runners report "I pressed start and nothing happened".

Notes:
- S1 keeps its deliberate *non*-gating on the HUD VM (NOTES v0.1.0). If the snapshot layer
  makes that fragile, latch it: `Run.PendingStart = true` on the raw edge, fire on the first
  tick where `InRace`.
- S3 cannot distinguish new campaign from reset; the profile decides. S3 and S4 fire in a
  menu, so the first race's `RaceGoEdge` is a *split-or-nothing* event for those profiles,
  never a start.
- `Phase` is otherwise projected from `Flow` every tick (see **Run state**); the only phases
  the flow cannot tell us are `Armed` and `Done`.

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

The finish stays on `FinishEdge` (a line crossing) for the same precision reason as S1/S2.
`FlowEnter(Race, Results 15)` is a useful Debug cross-check that the finish was seen, not a
trigger.

## Reset / ignore states

The current single-race reset (`ResetOnLeave`) is wrong for every multi-event category:
between races the HUD VM goes away, `playerLap` drops to 0 and `raceStarted` drops to 0 —
all three of today's reset conditions fire. Profiles therefore own the reset policy.

| # | Condition | IL profiles | Multi-event profiles |
|---|---|---|---|
| R1 | `IsTearingDown` before `Finished` (race machine left, or entered `PrepareToLeave 30` / `Leaving 8`) | reset (if enabled) | no-op; a restart of the same event is a retry |
| R2 | `IsTearingDown` after `Finished` | no-op (run is over) | no-op; expected between races |
| R3 | `FailEdge` | reset (if enabled) | no-op; retries are allowed (Arcade%, NG+ Sebulba%) |
| R4 | `FlowEnter(FrontEnd, Root 0 / PrimaryModeSelect 1)` with `Run.Phase ∈ {InRace, Between}` — the runner backed out to the main menu | n/a | now a crisp edge instead of "no race for a long time"; still *maybe*: default off, leave it to the runner |
| R5 | A fresh S3/S4/S5/S6 edge while a run is in progress | n/a | reset then start (runner restarted the category) |
| R6 | `CategoryChanged` | reset run state (`ResetRun`), not the timer | same |
| R7 | `ArrivalWrongEdge` while `Armed` under the *trust* menu-start policy | n/a | reset (the timer was started on the press and the press led somewhere else) |

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
| Arcade Scenarios | RTA | `IgtTotal` | S6 | race (+ laps optional) | E2 | multi |
| Arcade% | RTA | `IgtTotal` | S5 | event, skipping failed/retried | E3 | multi |
| Sebulba% / Any% | RTA | `IgtTotal` | S3 | race | E4 / E5 | multi |
| NG+ Sebulba% / Any% / Champion% | RTA | `IgtTotal` | S3 | race | E4 / E5 | multi |
| NG+ Act III | RTA | `IgtTotal` | S4 | race | E5 | multi |

Profile record fields: `Start(p, n)`, `IsEnd(p, n)`, `SplitOnLap`, `SplitOnRace`,
`ResetPolicy` (IL / multi), `Igt` (always `RunGameTime`), and optionally `ExpectedEventKind`
(Debug-only warning when the loaded event doesn't match the chosen category, e.g. a
Precision event under Time Trial — it never changes what the script does).

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
   `Phase` moves on the bookkeeping edges for now; the full projection from `Flow` is step 5.
4. ✅ Add profiles for the three IL categories (Time Trial, Precision, Podracing). Needs no new
   memory: Precision already works through the adjusted `finishTime`. Profiles carry a
   `StartStamp` ("Lap" / "Race" / "None") so the BUGS.md #2 guard checks the same stamp v0.4.1
   did for each start kind.

   Steps 1–4 landed 2026-10-19 in `SWGR_Autosplitter_Refactor.asl` (0.5.0-dev), **untested in
   LiveSplit**. Intended differences from v0.4.1, and nothing else: `LapsSane` accepts 100 laps
   (BUGS.md #3); with ResetOnLeave off and a running timer reused across races, Game Time is the
   IGT *sum* rather than the last race's time.
5. Add the multi-event reset policy and latch-and-confirm (`MenuDepartureEdge`,
   `ArrivalConfirmEdge`, `ArrivalWrongEdge`, the menu-start policy setting). Test on a
   Scenario: S6 is live as soon as the press sequence is recorded in step 1, so the
   between-race transitions (BUGS.md #2 territory) get exercised with the real start.
6. Add S3/S4 and E4/E5 (campaign). S4 needs only the Act index; S3 and E4/E5 still wait on
   the `UCampaignSubsystem` chain and the event names.
7. Add S5 and E2/E3 as the event names, M8 (medal) and M9 are found.
8. Separately: `IsPaused`, live `EventIgt` as the in-race Game Time, versioned `state` blocks.

## Open items this plan depends on

- `EventId`: chain works (`stageName`). Still need the actual names of Landspeeder Ace, The
  Experiment and the Sebulba / Kestar finals, and to confirm ASL `string` reads auto-detect UTF-16.
- `EventKind` (optional, Debug warning only): `arcadeCategory` works in arcade but is garbage in
  campaign, so decide "campaign" first (or class-check `authoredEvent`).
- Elimination events: `totalLaps` = 100. `LapsSane` must allow 100 (v0.4.1 uses `< 100`, see
  BUGS.md #3), and lap splits / the end condition need checking there (the event ends on
  elimination, not on lap 100).
- Stable chain to `UCampaignSubsystem`; Act III index value; whether `activeRun` flips elsewhere.
- M8 medal result; M9 stage count for Scenarios. (M4 / M5 closed by the flow edges.)
- Flow machine, still to record live: the exact state sequence after Arcade "Start Event"
  (does `FrontEnd.1` go to `LaunchingQuickRace 4` first, or straight to `None`?), after a
  scenario start, on the campaign-reset Accept, and on Act III "Start Run" (`Paddock.2 → 3 → 4`
  or `2 → 4`); `flowRecordCount` in the paddock; `BlueprintCreatedComponents[0]` is the GFSM
  component in all three GameState Blueprints (verified in the race GameState and whichever
  menu state the count was read in; check the third).
- `primaryFlow` chain (`GWorld, 0x228, 0x398`).
- Pause flag (`PauserPlayerState` lead).
- Whether `hudEventTime` is smooth enough at 60 Hz to be the live Game Time.
- Mods: Scenario start point; plain RTA vs load-removed; NG+ Champion% from a fresh save.
