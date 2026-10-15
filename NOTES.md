# Autosplitter notes

Running list of memory values / structures that look useful for splitting. Everything here is
from the UE4SS dumps (`../game/code_dumps/`) unless marked **verified** (observed in-game).
Offsets are from `CXXHeaderDump/Griffin.hpp` and will shift with game patches.

Status legend: **dump** = read from headers only, **verified** = confirmed live.

## IL split plan (first pass)

| Event | Best candidate | Status |
|---|---|---|
| Race start (countdown over, go) | race state → `Racing` (5); also `ARacingGameState.bIsRaceStarted` 0→1 | dump |
| Lap split | `UPlayerRaceEventComponent.CurrentLapNumber` increments | dump |
| Race end (final-lap finish) | `UPlayerRaceEventComponent.bHasFinishedEvent` 0→1 | dump |
| Reset / restart | race state leaves `Racing` back to pre-race states; `CurrentLapNumber` drops | dump |

Load removal (if needed later): race state `LoadingPhase` / `WaitForLevelToLoad`.

## Race flow state machine

`ESimpleRaceGameModeState` (`Griffin_enums.hpp`) — the race game mode's state machine.
Each value has a matching `U<Name>RaceState` class (e.g. `UCountdownRaceState`, `URacingRaceState`).
Values are **not** in order; expected singleplayer sequence is roughly:

```
LoadingPhase(1) → WaitForLevelToLoad(10) → … → PreRacePhase(12) → IntroSequence(13)
→ InRacePhase(2) → PrepareForEventStart(3) → IgnitionSequence(17) → Countdown(4)
→ Racing(5) → PostRacePhase(6) → Outro(14) → Results(15) → PrepareToLeave(30) → Leaving(8)
```

Full enum: Root 0, LoadingPhase 1, InRacePhase 2, PrepareForEventStart 3, Countdown 4,
Racing 5, PostRacePhase 6, PlayFromHere 7, Leaving 8, WaitForPlayersToArrive 9,
WaitForLevelToLoad 10, WaitForClientsToBeReady 11, PreRacePhase 12, IntroSequence 13, Outro 14,
Results 15, IgnitionSequence 17, RollingStart 18, PvpLastPlanetResults 22, IntermissionPhase 23,
RollingRestart 24, SideBets 25, RollingOutro 27, WaitForIntroMovieToFinish 28,
WaitForOutroMovieToFinish 29, PrepareToLeave 30, PvpPostRaceStage 31, PvpLaunchEvent 32,
PvpInstantActionPostRaceStage 33, WaitForPS5MatchSetup 34, PostTourFlow 40,
WaitForOutroCinematicToFinish 41, PlayingCredits 42, PvpLastPlanetPodium 43,
PvpEventCompletePodium 44, Invalid 255.

Notes:
- Some events have a **rolling start** (`RollingStart` 18) instead of `Countdown`;
  `URaceEventDef.bShouldSkipCountdown` / `RollingStartTrigger` control this. Start trigger
  should be "entered `Racing`", not "left `Countdown`".
- `RollingRestart` (24) and `IntermissionPhase` (23) exist (knockout / multi-stage events).

Where the current state lives:
- `UGameFlowStateMachineComponent` (component; owner not yet known — added at runtime)
  - `+0x00C0 TArray<FGameFlowStateRecord> ActiveStateMachines`
- `FGameFlowStateRecord` (size 0x28)
  - `+0x00 TSubclassOf<UGameFlowStateMachine> StateMachineClass` (want `USimpleRaceStateMachine`)
  - `+0x08 UEnum* StateMachineStateIdEnum`
  - `+0x10 int32 CurrentStateId` ← `ESimpleRaceGameModeState` value
  - `+0x18 double CurrentStateDuration`, `+0x20 double CurrentStateExpirationTime`
- `ARacingGameMode` `+0x04F8 USimpleRaceStateMachine* StateMachine`, `+0x04C8 ARacingGameState* mRaceState`
  (game mode exists locally in singleplayer).
- TODO: find which actor owns the `UGameFlowStateMachineComponent` (likely game state or game mode).

## ARacingGameState (size ≥ 0x428)

Reached via `UWorld → GameState`. Simplest single object for start/finish.

| Offset | Type | Field | Use |
|---|---|---|---|
| 0x0348 | TArray<AGfnPlayerState*> | Racers | find local player's state |
| 0x0358 | TArray<AVehiclePawn*> | Vehicles | |
| 0x0368 | double | CountdownEndTime | server time countdown ends |
| 0x0370 | int32 | LapCount | total laps for this event |
| 0x0378 | double | RaceStartTime | server time race started |
| 0x0380 | double | RaceTimeoutTime | |
| 0x0388 | bool | bIsRaceStarted | start split candidate |
| 0x0389 | bool | bIsRaceFinished | whole race over (all racers? — check vs player finish) |
| 0x03D8 | URaceEventVM* | RaceEventViewModel | HUD data: lap, timers, track/planet |
| 0x03F8 | FEventRecipe | EventRecipe | `TArray<FRaceEventInstance> EventStages` |
| 0x0408 | FEventRecipeState | EventRecipeState_Replication | `+0x0 int32 ActiveStage` |
| 0x0420 | ASimpleRaceRoute* | RaceRoute | checkpoints |

Delegates (hook targets for a UE4SS-side helper, if we go that route): `OnRaceStarted`,
`OnLocalPlayerReachedFinalEventPhase` (final lap?).

Times are server-time doubles; compare against `AGameStateBase` replicated server world time
(offset TBD) if we ever want in-game time.

## Per-player race progress — UPlayerRaceEventComponent

`AGfnPlayerState +0x0368 UPlayerRaceEventComponent* RaceEventComponent`.

| Offset | Type | Field | Use |
|---|---|---|---|
| 0x00C4 | int32 | EventPosition | race position |
| 0x00CC | bool | bHasFinishedEvent | **final split** candidate |
| 0x00CD | bool | bHasTimedOut | fail |
| 0x00CF | bool | bHasVehicleWrecked | fail |
| 0x00D0 | bool | bHasBeenEliminated | fail (knockout/eliminator) |
| 0x00D4 | int32 | CurrentLapNumber | **lap split** candidate (0- or 1-based? verify) |
| 0x00D8 | uint8 | CurrentSectorNumber | possible sub-splits |
| 0x00E0 | double | SectorStartServerTime | |
| 0x00E8 | double | LapStartServerTime | changes on each lap cross |
| 0x00F0 | float | EventFinishTime | game's own finish time — compare vs LiveSplit |
| 0x00F4 | float | BonusTime | |
| 0x00F8 | float | BestLapTime | |
| 0x00FC | float | PreviousLapTime | |
| 0x0120 | ERaceFailReason (u8) | FailReasons | bitflags: Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8, MissedRequiredWin 16 |

## HUD view model — URaceEventVM

`ARacingGameState +0x03D8`. Mirrors what the HUD shows; handy for lap and names.

| Offset | Type | Field |
|---|---|---|
| 0x0028 | UTrackDef* | track |
| 0x0030 | UPlanetDef* | Planet |
| 0x0040 | FText | ModeName |
| 0x00D8 | ERaceEventModeType (u8) | ModeType |
| 0x0140 | int32 | NumLaps |
| 0x016C | int32 | CurrentLapNumber |
| 0x0178 | double | CurrentLapTime |
| 0x0188 | double | CurrentEventTime |
| 0x01D0 | float | CountdownToRaceFinish |
| 0x01D4 | bool | bIsSuccess |

## Track / planet / event identity

- `UTrackDef`: `+0x30 FText PlayerFacingName`, `+0x50 FString InternalName` (stable ID — prefer
  this over localized text), `+0xB8 TSoftObjectPtr<UPlanetDef> Planet`, `+0xE8 bool bIsPointToPoint`,
  `+0xE9 bool bIsReverse`, `+0xEC int32 DefaultLapCount`.
- `UPlanetDef`: `+0x30 FText PlayerFacingName`, `+0xD8 FName EngineFacingName` (stable ID).
- `FRaceEventInstance` (elements of `EventRecipe.EventStages`, index `ActiveStage`):
  `+0x00 FText PlayerFacingName`, `+0x10 FString InternalName`, `+0x20 UTrackDef*`,
  `+0x30 uint8 LapCount`, `+0x4A ERaceEventModeType`, `+0x58 URaceEventDef* AuthoredEvent`.
- `URaceEventDef`: `+0x30 FText PlayerFacingName`, `+0x50 UTrackDef*`, `+0x78 uint8 LapCount`,
  `+0xB8 bool bShouldSkipCountdown`, `+0x1A8 EStageToTriggerRollingStart RollingStartTrigger`.
- Object names (`FName` in the UObject header) of the UTrackDef / URaceEventDef are probably the
  easiest identifier of all (e.g. asset names under `Content/Griffin/...`).

`ERaceEventModeType`: INVALID 0, TeamRace 1, TimeTrial 2, HotLap 3, TimeEliminator 4,
KnockoutRace 5, Takedowns 6, RamjetDistance 7, PrecisionDriving 8.

## Checkpoints / finish line

- `ASimpleRaceRoute +0x02D8 TArray<ASimpleRaceCheckpoint*> Checkpoints`; each has
  `+0x2B8 int32 CheckpointIndex`. `bIsPointToPoint` at `+0x2F0`.
- `UVehicleRouteMarker` (per vehicle): `EventProgress` 0x34, `EventProgressNormalised` 0x38,
  `DistanceToFinish` 0x3C, `mRoute` 0x88. Delegate `OnCrossedCheckpoint(vehicle, checkpoint, isEndOfLap)`.
- `ARacingGameMode::RacerCrossedCheckpoint(Vehicle, checkpoint, isEndOfLap)` — function hook
  point for lap crossings.

## Event hooks (UE4SS-side alternative to polling)

`UGameplayActionSubsystem` (GameInstance subsystem) broadcasts gameplay actions:
- `OnRacerLapFinished` 0x00D0 → `FRacePlayerLapGameplayAction { AGfnPlayerState* Player; int32 CompletedLapCount; }`
- `OnRacerFinished` 0x0080 → `FRacePlayerFinishedGameplayAction { Player; URaceEventDef* EventPlayed;
  int32 FinishPosition; float FinishTime; bool bUsedCheats; }`

Could hook `PlayerLapFinished` / `PlayerActionRacerFinished` from Lua and write to a shared value,
but a pure memory-read autosplitter (LiveSplit ASL) is preferable for runners.

## Ignition / start

`EIgnitionPhase`: Offline 0, EngineIgnite 1, PerfectStart 2, PostPerfectStart 3.
Lives on `UVehicleState +0x0380` (same object `tools/vehicle_state_logger.py` reads) and
`UVehicleIgnitionComponent +0x00C8`. Probably not the start trigger, but useful to cross-check timing.

## Other enums of note

- `EKnockoutRaceState`: PreRace 0, WarmUpGraceTime 1, EliminationTimerRunning 2, CinematicRecap 3,
  RollingRestart 4, Racing 5.
- `ETimeEliminatorStage` on `ARacingGameState +0x03E3`.
- `EContinueRunState` (campaign run flow): Paddock 0 … StartEvent 4, PostEvent 5, LeavePlanet 6 —
  relevant for full-game runs later.
- `EFrontEndFlowState` — menus / quick race setup; relevant for full-game start/reset.

## Open questions / to verify in-game

- [ ] Which actor owns `UGameFlowStateMachineComponent`; confirm `CurrentStateId` tracks the enum above.
- [ ] Is `CurrentLapNumber` 0- or 1-based, and does it tick on the final crossing too?
- [ ] Does `bHasFinishedEvent` flip exactly on the finish-line frame?
- [ ] `bIsRaceFinished` — player finish or all racers?
- [ ] Rolling-start events: what state sequence, and when does `bIsRaceStarted` flip?
- [ ] Stable pointer path from the exe base (GWorld / GEngine signature) for an ASL script.
- [ ] Find `AGameStateBase` server world time offset (for in-game-time option).
