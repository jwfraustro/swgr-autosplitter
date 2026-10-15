# Autosplitter notes

Running list of memory values / structures that look useful for splitting. Everything here is
from the UE4SS dumps (`../game/code_dumps/`) unless marked **verified** (observed in-game).
Offsets are from `CXXHeaderDump/Griffin.hpp` and will shift with game patches.

Status legend: **dump** = read from headers only, **verified** = confirmed live.

## Target: LiveSplit ASL

The deliverable is a LiveSplit ASL script (`state` / `startup` / `init` / `update` / `start` /
`split` / `reset` / `isLoading`), memory-read only — no UE4SS mod required for runners.
Reference: `../ProjectWingman_Autosplitter/PW_Autosplitter.asl` (UE game, same structure).

Takeaways from the Project Wingman script:
- Values are declared in `state("SWGR-Win64-Shipping")` as `DeepPointer` chains from the exe
  base: `byte foo: "SWGR-Win64-Shipping.exe", 0xBASE, 0x.., 0x..;`. The PW roots
  (e.g. `0x9150ED0, 0x0, 0x180`) are a static global → game instance style chain.
- Logic compares `current.x` vs `old.x` for transitions (start on 0→1, split on 2→3, etc.).
- Strings (level IDs) are read in `init` helper funcs: deref an FString/FText to
  (data ptr, length) and `game.ReadString(..., ReadStringType.UTF16, len)`.
- `settings.Add` tree for modes (IL vs full game) and optional splits; `refreshRate = 30`
  because 60 Hz gave duplicate ticks.
- `isLoading` only matters when comparing against Game Time.
- Static offsets break on every game patch. Better for us: signature-scan for `GWorld` /
  `GEngine` in `init` (`SigScanTarget`), then hang all chains off that. Plan to do this.

### Pointer chains (engine offsets from `CXXHeaderDump/Engine.hpp`)

Roots (to locate by sigscan): `GWorld` (UWorld*) and/or `GEngine` (UGameEngine*).

**verified** (2026-10-15, current game build): `GWorld` = `"SWGR-Win64-Shipping.exe"+0xADFF928`.
Static offset — will move on patches; still want a sigscan eventually.

Verified chains:

| Value | Chain | Type |
|---|---|---|
| RaceStartTime | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x378` | double |
| bIsRaceStarted | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x388` | byte |
| LapCount (total laps) | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x370` | int |
| Player race data (UPlayerRaceEventComponent*) | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368` | ptr |
| Player CurrentLapNumber | player race data chain + `0xD4` | int |
| HUD lap counter (URaceEventVM.CurrentLapNumber) | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x16C` | int |

Lap counter behaviour (**verified**):
- **Player `CurrentLapNumber`** is **0** from the grid until the player first crosses the
  start/finish line — a racer at the back of the grid stays at 0 for a few seconds after the go.
  It then counts completed-line-crossings. Goes back to **0** when the player leaves the race.
- **HUD lap counter** starts at **1** (what the player sees). Goes **undefined** (chain breaks)
  when the player leaves the race.
- In-race sanity check: HUD lap counter resolves **and** `HUD == CurrentLapNumber + 1`.
  Use as a backup "player is truly in the race" gate.
- Keep both: run rules aren't decided yet. Some categories (e.g. arcade time trials) may time
  from the grid rather than from the first line crossing, so the 0→1 crossing of
  `CurrentLapNumber` is a candidate *alternative* start trigger, not just a lap split.

This also confirms the dump's `UWorld.GameState` (0x1B0) and the `ARacingGameState` layout
(0x370 / 0x378 / 0x388) match the live build, so the other GameState offsets are likely good.

| Hop | Offset | Field |
|---|---|---|
| UGameEngine → | 0x12C8 | GameInstance |
| UWorld → | 0x01A8 | AuthorityGameMode (ARacingGameMode in a race) |
| UWorld → | 0x01B0 | GameState (ARacingGameState in a race) |
| UWorld → | 0x0228 | OwningGameInstance |
| UGameInstance → | 0x0038 | LocalPlayers (TArray: data ptr at +0x0, [0] at data+0x0) |
| UPlayer → | 0x0030 | PlayerController |
| AController → | 0x02B8 | PlayerState (→ AGfnPlayerState) |
| AController → | 0x02F0 | Pawn |
| AGameStateBase → | 0x02E0 | ReplicatedWorldTimeSecondsDouble (server time, for IGT math) |

Draft chains (from GWorld, not yet checked live):
- Race finished (all?): `GWorld, 0x1B0, 0x389` (byte)
- Player race data (chain verified above) → `+0xCC` bHasFinishedEvent (byte),
  `+0xF0` EventFinishTime (float)
- HUD VM (`GWorld, 0x1B0, 0x3D8`, verified) → `+0x140` NumLaps
- Track internal name: `GWorld, 0x1B0, 0x3D8, 0x28, 0x50` → FString (ptr, len)
- Planet engine name: `GWorld, 0x1B0, 0x3D8, 0x30, 0xD8` → FName (needs FName pool lookup —
  prefer the track FString or the object name)

The game state is only an `ARacingGameState` during a race — in menus/paddock the same offsets
point into a different class, so gate on something (e.g. the race state or a class check)
before trusting values.

## IL split plan (first pass)

| Event | Best candidate | Status |
|---|---|---|
| Race start (countdown over, go) | `ARacingGameState.bIsRaceStarted` 0→1; race state → `Racing` (5) | address verified, transition timing TBD |
| Race start (alt: first line crossing) | player `CurrentLapNumber` 0→1 | verified (rules TBD) |
| Lap split | player `CurrentLapNumber` increments n→n+1 for 1 ≤ n < LapCount | verified |
| Race end (final-lap finish) | `bHasFinishedEvent` 0→1 (flips near-frame-perfect); `CurrentLapNumber` also ticks to LapCount+1 on the same crossing | verified |
| Reset / left race | HUD lap counter goes undefined; player `CurrentLapNumber` → 0 | verified |

**Category note (verified in play):** Arcade races are a *rolling start* — the player only gets
control of the speeder once they cross the start line. That makes "start on first line crossing"
(`CurrentLapNumber` 0→1) the natural trigger for Arcade, while grid-start events fit "start on go"
(`bIsRaceStarted` 0→1). Expect the start mode to be chosen per category (or per event type)
rather than as a global setting — likely how the script settings / code end up being organised.

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
| 0x0370 | int32 | LapCount | total laps for this event — **verified** |
| 0x0378 | double | RaceStartTime | server time race started — **verified** |
| 0x0380 | double | RaceTimeoutTime | |
| 0x0388 | bool | bIsRaceStarted | start split candidate — **verified** (address) |
| 0x0389 | bool | bIsRaceFinished | whole race over (all racers? — check vs player finish) |
| 0x03D8 | URaceEventVM* | RaceEventViewModel | HUD data: lap, timers, track/planet |
| 0x03F8 | FEventRecipe | EventRecipe | `TArray<FRaceEventInstance> EventStages` |
| 0x0408 | FEventRecipeState | EventRecipeState_Replication | `+0x0 int32 ActiveStage` |
| 0x0420 | ASimpleRaceRoute* | RaceRoute | checkpoints |

Delegates (research hooks only): `OnRaceStarted`,
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
| 0x00D4 | int32 | CurrentLapNumber | **lap split** — **verified**: 0 until first line crossing, 0 after leaving race |
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
| 0x016C | int32 | CurrentLapNumber — **verified**: starts at 1, undefined after leaving race |
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

## Event hooks (research only — not for the shipped autosplitter)

Useful with UE4SS while *finding/verifying* values (e.g. log when these fire and compare
against the polled fields); the ASL itself must not depend on them.
`UGameplayActionSubsystem` (GameInstance subsystem) broadcasts gameplay actions:
- `OnRacerLapFinished` 0x00D0 → `FRacePlayerLapGameplayAction { AGfnPlayerState* Player; int32 CompletedLapCount; }`
- `OnRacerFinished` 0x0080 → `FRacePlayerFinishedGameplayAction { Player; URaceEventDef* EventPlayed;
  int32 FinishPosition; float FinishTime; bool bUsedCheats; }`


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
- [x] `CurrentLapNumber` is 0 until the first line crossing (HUD counter starts at 1).
- [x] `CurrentLapNumber` ticks on the final crossing too: ends at LapCount+1.
- [x] `bHasFinishedEvent` flips near-perfectly on the finish crossing (revisit if timing drift shows up).
- [ ] `bIsRaceFinished` — player finish or all racers?
- [ ] Rolling-start events: what state sequence, and when does `bIsRaceStarted` flip?
- [ ] Signatures for `GWorld` / `GEngine` in `SWGR-Win64-Shipping.exe` (UE5-style; verify the
      static address with UE4SS / Cheat Engine first, then write the sigscan).
- [x] GWorld static address + GameState chains (RaceStartTime, bIsRaceStarted, LapCount) resolve live.
- [x] Player race data and HUD VM chains resolve live.
- [ ] Track internal name chain (`GWorld, 0x1B0, 0x3D8, 0x28, 0x50`) not resolving yet — recheck (FString: ptr at +0x0, int32 len at +0x8).
- [ ] Is the race state machine's `CurrentStateId` reachable by a fixed chain (component owner)?
- [ ] Pause flag for an optional "pausing stops timer" setting.
