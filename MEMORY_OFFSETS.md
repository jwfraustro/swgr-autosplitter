# Memory offsets

Every offset the autosplitter work has used or found. Struct offsets come from the UE4SS dumps
(`../game/code_dumps/CXXHeaderDump/`); they shift with game patches.

- `GWorld` = `"SWGR-Win64-Shipping.exe"+0xADFF928` (static, current build).
- Pointer-chain bases used below:
  - **GameState** = `GWorld, 0x1B0` (`ARacingGameState` only while the race flow machine is active).
  - **HUD VM** = `GameState, 0x3D8` (`URaceEventVM`; 0 outside a race).
  - **Stage0** = `GameState, 0x3F8` (`EventRecipe.EventStages` data ptr; `FRaceEventInstance` elements are inline, 0x308 bytes each, no deref; stage N = data ptr + N*0x308).
  - **PlayerRace** = `GWorld, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368` (`UPlayerRaceEventComponent` of the local player).
  - **GFSM** = `GameState, 0x298, 0x0` (`UGameFlowStateMachineComponent`, `BlueprintCreatedComponents[0]`).

## Engine / chain hops

| Type | Field | Offset | Notes |
|---|---|---|---|
| UGameEngine | GameInstance | 0x12C8 | |
| UWorld | AuthorityGameMode | 0x1A8 | ARacingGameMode in a race |
| UWorld | GameState | 0x1B0 | ARacingGameState in a race |
| UWorld | OwningGameInstance | 0x228 | |
| UGameInstance | LocalPlayers | 0x38 | TArray; [0] = data ptr + 0x0 |
| UPlayer | PlayerController | 0x30 | |
| AController | PlayerState | 0x2B8 | AGfnPlayerState |
| AController | Pawn | 0x2F0 | |
| AGameStateBase | ReplicatedWorldTimeSecondsDouble | 0x2E0 | server time; lags crossing stamps |
| AActor | BlueprintCreatedComponents | 0x298 | TArray; [0] = GFSM component on every game state |
| AGfnPlayerState | RaceEventComponent | 0x368 | UPlayerRaceEventComponent* |
| UGfnGameInstance | PrimaryFlow | 0x398 | EGfnPrimaryFlow: Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4 (lead) |
| UGfnGameInstance | CampaignResetInfo | 0x268 | dud for NG+ start detection |
| FString | Len | +0x8 | int32 after the data ptr |
| TArray | Num | +0x8 | int32 after the data ptr |

## Flow state machine (GFSM = `GWorld, 0x1B0, 0x298, 0x0`)

| Type | Field | Offset | Notes |
|---|---|---|---|
| UGameFlowStateMachineComponent | ActiveStateMachines | 0xC0 | TArray<FGameFlowStateRecord>; record n = data + n*0x28 |
| UGameFlowStateMachineComponent | ActiveStateMachines.Num | 0xC8 | expect 1 |
| FGameFlowStateRecord | StateMachineClass | 0x00 | TSubclassOf |
| FGameFlowStateRecord | StateMachineStateIdEnum | 0x08 | UEnum*; Names data +0x48, Names.Num +0x50 |
| FGameFlowStateRecord | CurrentStateId | 0x10 | int32; id in the machine's own enum |
| FGameFlowStateRecord | IsNew | 0x14 | bool |
| FGameFlowStateRecord | CurrentStateDuration | 0x18 | double |
| FGameFlowStateRecord | CurrentStateExpirationTime | 0x20 | double |
| UEnum | Names.Num | 0x50 | 37 race, 16 front end, 9 paddock, 4 paddock narrative, >=14 pvp, 0 = loading |
| ARacingGameMode | mRaceState | 0x4C8 | ARacingGameState* |
| ARacingGameMode | StateMachine | 0x4F8 | USimpleRaceStateMachine* |

Full chains: `flowState` = `GFSM, 0xC0, 0x10`; `flowEnumCount` = `GFSM, 0xC0, 0x8, 0x50`; `flowRecordCount` = `GFSM, 0xC8`.

## ARacingGameState (GameState = `GWorld, 0x1B0`)

| Type | Field | Offset | Notes |
|---|---|---|---|
| ARacingGameState | Racers | 0x348 | TArray<AGfnPlayerState*> |
| ARacingGameState | Vehicles | 0x358 | TArray<AVehiclePawn*> |
| ARacingGameState | CountdownEndTime | 0x368 | double; stamp on the RaceStartTime clock, not seconds left |
| ARacingGameState | LapCount | 0x370 | int32; 100 in Elimination events |
| ARacingGameState | RaceStartTime | 0x378 | double, server time |
| ARacingGameState | RaceTimeoutTime | 0x380 | double |
| ARacingGameState | bIsRaceStarted | 0x388 | 0 -> 1 when the grid is released |
| ARacingGameState | bIsRaceFinished | 0x389 | local player's finish, not all racers |
| ARacingGameState | RaceEventViewModel | 0x3D8 | URaceEventVM* (HUD VM) |
| ARacingGameState | ETimeEliminatorStage | 0x3E3 | |
| ARacingGameState | EventRecipe.EventStages | 0x3F8 | TArray<FRaceEventInstance> data ptr |
| ARacingGameState | EventRecipe.EventStages.Num | 0x400 | stage count |
| ARacingGameState | EventRecipeState_Replication.ActiveStage | 0x408 | int32, 0-indexed |
| ARacingGameState | RaceRoute | 0x420 | ASimpleRaceRoute* |

## URaceEventVM (HUD VM = `GWorld, 0x1B0, 0x3D8`)

| Type | Field | Offset | Notes |
|---|---|---|---|
| URaceEventVM | track | 0x28 | UTrackDef*; bad ptr in Precision, map-only in campaign |
| URaceEventVM | Planet | 0x30 | UPlanetDef* |
| URaceEventVM | ModeName | 0x40 | FText |
| URaceEventVM | ModeType | 0xD8 | ERaceEventModeType: TimeTrial 2, PrecisionDriving 8 |
| URaceEventVM | NumLaps | 0x140 | int32; 100 in Elimination |
| URaceEventVM | CurrentLapNumber | 0x16C | int32; starts at 1, chain breaks after leaving |
| URaceEventVM | CurrentLapTime | 0x178 | double; raw lap IGT, resets each lap |
| URaceEventVM | CurrentEventTime | 0x188 | double; event IGT with Precision deductions applied |
| URaceEventVM | CountdownToRaceFinish | 0x1D0 | float |
| URaceEventVM | bIsSuccess | 0x1D4 | finish outcome |

## UPlayerRaceEventComponent (PlayerRace = `GWorld, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368`)

| Type | Field | Offset | Notes |
|---|---|---|---|
| UPlayerRaceEventComponent | EventPosition | 0xC4 | int32 |
| UPlayerRaceEventComponent | bHasFinishedEvent | 0xCC | 0 -> 1 on the final crossing; end trigger |
| UPlayerRaceEventComponent | bHasTimedOut | 0xCD | |
| UPlayerRaceEventComponent | bHasVehicleWrecked | 0xCF | 1 = wrecked out for good |
| UPlayerRaceEventComponent | bHasBeenEliminated | 0xD0 | |
| UPlayerRaceEventComponent | CurrentLapNumber | 0xD4 | int32; 0 until first crossing, LapCount+1 after finish, 0 after leaving |
| UPlayerRaceEventComponent | CurrentSectorNumber | 0xD8 | uint8 |
| UPlayerRaceEventComponent | SectorStartServerTime | 0xE0 | double |
| UPlayerRaceEventComponent | LapStartServerTime | 0xE8 | double; stamped at each crossing |
| UPlayerRaceEventComponent | EventFinishTime | 0xF0 | float; -1 until finish, then results time (Precision-adjusted) |
| UPlayerRaceEventComponent | BonusTime | 0xF4 | float; Precision deductions total, +1.5 per gate |
| UPlayerRaceEventComponent | BestLapTime | 0xF8 | float |
| UPlayerRaceEventComponent | PreviousLapTime | 0xFC | float |
| UPlayerRaceEventComponent | FailReasons | 0x120 | ERaceFailReason bits: Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8, MissedRequiredWin 16 |

## Event identity (Stage0 = `GWorld, 0x1B0, 0x3F8`)

| Type | Field | Offset | Notes |
|---|---|---|---|
| FRaceEventInstance | PlayerFacingName | 0x00 | FText |
| FRaceEventInstance | InternalName | 0x10 | FString; event ID, e.g. `EVT_ARC_PRE_BIKE_MAS_A_FWD`, `DAL_SHORT_06_TeamRace_Dry` |
| FRaceEventInstance | InternalName.Len | 0x18 | |
| FRaceEventInstance | Track | 0x20 | UTrackDef* |
| FRaceEventInstance | LapCount | 0x30 | uint8; matches GameState LapCount |
| FRaceEventInstance | ModeType | 0x4A | ERaceEventModeType |
| FRaceEventInstance | AuthoredEvent | 0x58 | URaceEventDef*; UArcadeEventDef in arcade |
| URaceEventDef | PlayerFacingName | 0x30 | FText |
| URaceEventDef | Track | 0x50 | UTrackDef* |
| URaceEventDef | LapCount | 0x78 | uint8 |
| URaceEventDef | bShouldSkipCountdown | 0xB8 | rolling vs grid start; undefined in campaign |
| URaceEventDef | RollingStartTrigger | 0x1A8 | EStageToTriggerRollingStart |
| UArcadeEventDef | Category | 0x321 | EArcadeEventCategories: Plane 2, Precision 4; undefined in campaign |
| UArcadeEntryVM | Category | 0x15C | same enum, front-end tile |
| UTrackDef | PlayerFacingName | 0x30 | FText |
| UTrackDef | InternalName | 0x50 | FString |
| UTrackDef | Planet | 0xB8 | TSoftObjectPtr<UPlanetDef> |
| UTrackDef | bIsPointToPoint | 0xE8 | |
| UTrackDef | bIsReverse | 0xE9 | |
| UTrackDef | DefaultLapCount | 0xEC | int32 |
| UPlanetDef | PlayerFacingName | 0x30 | FText |
| UPlanetDef | EngineFacingName | 0xD8 | FName |

## Campaign (UCampaignSubsystem, GameInstance subsystem; no fixed chain yet)

| Type | Field | Offset | Notes |
|---|---|---|---|
| UCampaignSubsystem | bIsPlayingPrologue | 0xC1 | 0 -> 1 on new campaign and on reset Accept (M1/M2) |
| UCampaignSubsystem | ActiveRun | 0xC8 | UCampaignRun*; null -> set on Act III loadout Continue (M3) |
| UCampaignSubsystem | MetaProgression | 0xE0 | UCampaignMetaProgression* |
| UCampaignMetaProgression | MainCampaignCurrentTourIx | 0x28 | int32; Tour = Act, Act III value TBC |
| UCampaignMetaProgression | LastPickedDifficulty | 0x110 | UCampaignDifficultyDef* (lead) |
| APaddockGameState | PreRunChosenDifficulty | 0x318 | lead |

## Route / checkpoints / misc

| Type | Field | Offset | Notes |
|---|---|---|---|
| ASimpleRaceRoute | Checkpoints | 0x2D8 | TArray<ASimpleRaceCheckpoint*> |
| ASimpleRaceRoute | bIsPointToPoint | 0x2F0 | |
| ASimpleRaceCheckpoint | CheckpointIndex | 0x2B8 | int32 |
| UVehicleRouteMarker | EventProgress | 0x34 | |
| UVehicleRouteMarker | EventProgressNormalised | 0x38 | |
| UVehicleRouteMarker | DistanceToFinish | 0x3C | |
| UVehicleRouteMarker | mRoute | 0x88 | |
| UVehicleState | IgnitionPhase | 0x380 | EIgnitionPhase: Offline 0, EngineIgnite 1, PerfectStart 2, PostPerfectStart 3 |
| UVehicleIgnitionComponent | IgnitionPhase | 0xC8 | same enum |
| UGameplayActionSubsystem | OnRacerFinished | 0x80 | delegate; research hook only |
| UGameplayActionSubsystem | OnRacerLapFinished | 0xD0 | delegate; research hook only |
