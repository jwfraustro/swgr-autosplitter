# Autosplitter dev notes

Game facts the script relies on, found by datamining or in play. Companion files:
`MEMORY_OFFSETS.md` (every address), `REFACTOR.md` (script design, start/end/reset tables,
category profiles), `BUGS.md`.

> Eventually this becomes the user-facing doc on how the autosplitter behaves in each
> category; keep **Categories** written so it can be lifted out.

## Categories (speedrun.com, mods' rules as of 2026-10-21)

Three ways of being judged:

| Group | Ranked by | Timer requirement |
|---|---|---|
| Arcade events (Time Trial, Precision Driving, podraces) | IGT | submit the time the game shows on the event selection screen |
| Arcade Scenarios | IGT | as above: the game's own scenario time (loads and menus between the 5 races don't count). No RTA timer needed |
| Arcade% | RTA | real-time timer on screen; also add up and submit total IGT |
| Story Campaign (Sebulba%, Any%, NG+ variants, NG+ Act III) | RTA | real-time timer on screen |

Earlier rulings this replaces: Scenarios were RTA (2026-10-19); "Tales of Podracing" was its own
category and has been removed. Podraces are now ordinary arcade events, identical to any other
grid-start race, and appear both as single events and inside Arcade%.

| Category | Start | End |
|---|---|---|
| Arcade Time Trial / Precision | first start-line crossing (rolling start) | final-lap finish |
| Arcade podrace | grid released (countdown over) | final-lap finish |
| Arcade Scenarios (5 races, fixed character) | first race's go (nothing before it is timed) | finish of the 5th race |
| Arcade% (all 50 events in order; 3 Deluxe excluded; retries allowed) | "Start Event" on *Landspeeder Ace* | finish of *The Experiment* with Bronze beaten |
| Sebulba% / Any% (fresh save, any difficulty) | "Start New Campaign" | final-lap finish vs Sebulba (Act 1) / Kestar's Podracer (Act 3) |
| NG+ Sebulba% / Any% / Champion% | "Accept" on the campaign-reset "Are you sure?" | as above |
| NG+ Act III | "Continue" on the Act III loadout check (after Start Run) | final-lap finish vs Kestar's Podracer |

Precision Driving IGT already has the 1.5 s per gate deducted. A failed Arcade% attempt that gets
retried must not split or end the run; same for failing out and switching vehicle in NG+ Sebulba%.

Open with the mods: whether Arcade% RTA is load-removed (assumed plain); NG+ Champion% from a
fresh save; whether a redone Arcade% event's IGT counts in the submitted total. Deferred until
someone reports a problem: how the game's displayed Scenario time treats a redone race.

## Observed behaviour

**Lap counters**
- `UPlayerRaceEventComponent.CurrentLapNumber` is 0 from the grid until the first line crossing
  (a back-row racer stays at 0 for seconds after the go), counts crossings, ticks to LapCount+1
  on the final crossing, and drops to 0 when the player leaves the race.
- `URaceEventVM.CurrentLapNumber` starts at 1; the HUD VM pointer goes away on leaving.
  In-race sanity: HUD VM present and `HUD == CurrentLapNumber + 1`.
- Arcade Time Trial / Precision are rolling starts: control arrives at the line crossing and
  `bIsRaceStarted` may never be relied on. Grid events (podraces, campaign, Scenarios) release
  on `bIsRaceStarted` 0→1.
- `bHasFinishedEvent` flips on the finish crossing within a tick; `bIsRaceFinished` on the game
  state is the local player's finish, not all racers.
- Elimination campaign events report LapCount 100 ("until top 3 remain"); the event ends on
  elimination, not lap 100.

**Timing**
- `URaceEventVM.CurrentEventTime` is the running IGT with Precision gate deductions applied;
  `CurrentLapTime` is raw and resets each lap.
- `EventFinishTime` equals the final `CurrentEventTime`, so it is already Precision-adjusted.
  `BonusTime` is the positive running total of deductions (1.5 per gate): gates = BonusTime/1.5,
  raw time = adjusted + BonusTime.
- `LapStartServerTime` is stamped on every crossing; finish stamp − `RaceStartTime` =
  `EventFinishTime`. `CountdownEndTime` is a stamp on the same clock, not seconds remaining.
- After a race tears down its stamps replay briefly during the next load (BUGS.md #2, #6).

**Event identity**
- `FRaceEventInstance.InternalName` (stage 0 of `EventRecipe.EventStages`) is the event ID and
  works in every mode seen, including Precision where the track pointer is bad:
  - arcade `EVT_ARC_<mode>_<vehicle>_<track>_<variant>`, e.g. `EVT_ARC_PRE_BIKE_MAS_A_FWD`
    (Precision, bike, Mastiff, variant A), `EVT_ARC_TMR_PLANE_BGL_PLANE_FWD`;
  - campaign `<MAP>_<race type>_<condition>`, e.g. `DAL_SHORT_06_TeamRace_Dry`.
- Each Scenario race is its own 1-stage recipe, so `ActiveStage` / stage count cannot tell
  "last race"; count distinct finishes instead.
- `UArcadeEventDef.Category` and `bShouldSkipCountdown` only mean anything when
  `AuthoredEvent` is an arcade def; campaign reads garbage there.

**Campaign start triggers** (`UCampaignSubsystem`, found 2026-10-19; no fixed chain yet)
- `bIsPlayingPrologue` 0→1 on both "Start New Campaign" and the reset Accept; the category
  setting tells them apart.
- `ActiveRun` null→set on the Act III loadout Continue. Gate on
  `MainCampaignCurrentTourIx` (Tour = Act; Act III value TBC) to screen out Acts I/II and
  resuming a save. `UGfnGameInstance.CampaignResetInfo` was a dud.

**Flow state machine** (`UGameFlowStateMachineComponent`, `BlueprintCreatedComponents[0]` of
every game state)
- The record's `CurrentStateId` is an id in whichever machine is active, so pair it with the
  enum's entry count: 37 race, 16 front end, 9 paddock, 4 paddock narrative, ≥14 PvP, 0 while
  the chain is broken during a load.
- Recorded scenario start: `FrontEnd.1 → FrontEnd.2 → None` (flickers once) `→ Paddock.1 → 3
  → 4 → None → Race.9 → 10 → 11 → 13 → 3 → 17 → 4 → 5`; finish `→ 14 → 15 → None`.
  NG+ Act III is `Paddock.2 → 4` (or `2 → 3 → 4`, TBC) with no load.

## Enums

`ESimpleRaceGameModeState` (race machine, 37 entries). Expected singleplayer sequence:
`LoadingPhase 1 → WaitForLevelToLoad 10 → PreRacePhase 12 → IntroSequence 13 → InRacePhase 2
→ PrepareForEventStart 3 → IgnitionSequence 17 → Countdown 4 | RollingStart 18 → Racing 5
→ PostRacePhase 6 → Outro 14 → Results 15 → PrepareToLeave 30 → Leaving 8`.
Full: Root 0, LoadingPhase 1, InRacePhase 2, PrepareForEventStart 3, Countdown 4, Racing 5,
PostRacePhase 6, PlayFromHere 7, Leaving 8, WaitForPlayersToArrive 9, WaitForLevelToLoad 10,
WaitForClientsToBeReady 11, PreRacePhase 12, IntroSequence 13, Outro 14, Results 15,
IgnitionSequence 17, RollingStart 18, PvpLastPlanetResults 22, IntermissionPhase 23,
RollingRestart 24, SideBets 25, RollingOutro 27, WaitForIntroMovieToFinish 28,
WaitForOutroMovieToFinish 29, PrepareToLeave 30, PvpPostRaceStage 31, PvpLaunchEvent 32,
PvpInstantActionPostRaceStage 33, WaitForPS5MatchSetup 34, PostTourFlow 40,
WaitForOutroCinematicToFinish 41, PlayingCredits 42, PvpLastPlanetPodium 43,
PvpEventCompletePodium 44, Invalid 255.

`EFrontEndFlowState` (16), `EPaddockFlowState` (9; Leaving 5, WipeToBlackBeforeLeaving 6),
`EPaddockNarrativeFlowState` (4): values in `Griffin_enums.hpp`.

`EArcadeEventCategories`: Default 0, FieldTest 1, Plane 2 (Podracing), Quick 3, Precision 4,
Acid 5, FireIce 6, Advanced 7, Deluxe 8. Everything but Plane and Precision is a Time Trial.

`ERaceEventModeType`: INVALID 0, TeamRace 1, TimeTrial 2, HotLap 3, TimeEliminator 4,
KnockoutRace 5, Takedowns 6, RamjetDistance 7, PrecisionDriving 8.

`ERaceFailReason` (bits): Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8,
MissedRequiredWin 16.

`EGfnPrimaryFlow`: Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4.

`EContinueRunState` (campaign run flow): Paddock 0 … StartEvent 4, PostEvent 5, LeavePlanet 6.

`EKnockoutRaceState`: PreRace 0, WarmUpGraceTime 1, EliminationTimerRunning 2,
CinematicRecap 3, RollingRestart 4, Racing 5.

`EIgnitionPhase`: Offline 0, EngineIgnite 1, PerfectStart 2, PostPerfectStart 3.

## Research hooks (UE4SS only; the ASL must not depend on them)

- `UGameplayActionSubsystem.OnRacerLapFinished` → `{ Player, CompletedLapCount }`;
  `OnRacerFinished` → `{ Player, EventPlayed, FinishPosition, FinishTime, bUsedCheats }`.
- `ARacingGameMode::RacerCrossedCheckpoint(Vehicle, checkpoint, isEndOfLap)`;
  `UVehicleRouteMarker.OnCrossedCheckpoint`.
- `ARacingGameState` delegates `OnRaceStarted`, `OnLocalPlayerReachedFinalEventPhase`.

## Open

- [ ] `stageName`s for the Sebulba final and the Kestar final (The Experiment is known).
- [ ] Fixed pointer chain to `UCampaignSubsystem`; `MainCampaignCurrentTourIx` value for Act III.
- [ ] Record the flow sequence for Arcade "Start Event", the campaign-reset Accept (main menu
      and paddock), Act III "Start Run"; whether `PaddockNarrative` appears in normal paddock
      play; `flowRecordCount` in the paddock; GFSM is `BlueprintCreatedComponents[0]` in the
      third GameState Blueprint.
- [ ] Elimination events: lap splits and finish behaviour (BUGS.md #3).
- [ ] Scenarios: what resets falsely between races (BUGS.md #6).
- [ ] Pause flag (`PauserPlayerState`) for an optional pause setting.
- [ ] Arcade medal result (M8), only if a Bronze check is ever wanted.
- [ ] Sigscan for `GWorld` (or versioned `state` blocks) so patches don't break the script.
