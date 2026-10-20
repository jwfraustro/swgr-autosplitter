# Autosplitter notes

Running list of memory values / structures that look useful for splitting. Everything here is
from the UE4SS dumps (`../game/code_dumps/`) unless marked **verified** (observed in-game).
Offsets are from `CXXHeaderDump/Griffin.hpp` and will shift with game patches.

Status legend: **dump** = read from headers only, **verified** = confirmed live.

> Development scratchpad for now. Eventually this becomes the user-facing doc on how the
> autosplitter behaves in each category / event type — keep the **Categories** section written
> so it can be lifted out for that.

## Categories (per Speedrun.com, 2026-10-17)

Three run categories. The script's mode setting (currently "Arcade Mode" / "Race Mode") becomes
**Arcade** / **Scenarios** / **Tales of Podracing**. Podracing is technically an Arcade event in
the game, but it is timed and scored separately, so it gets its own setting.

| Category | What it is | Start | End | Status |
|---|---|---|---|---|
| **Arcade — Time Trial** | Solo, N laps, rolling start | first start-line crossing (`playerLap` 0→1) | final-lap finish | covered (v0.2.0 "Arcade Mode") |
| **Arcade — Precision Driving** | Time Trial + gates on track; each gate driven through takes **1.5 s off** the time | as Time Trial | final-lap finish; time must account for gate bonuses | not handled |
| **Tales of Podracing** | You vs NPCs, grid start. Podracer vehicles don't change the rules | countdown ends (`bIsRaceStarted` 0→1) | final-lap finish | early handling (v0.2.0 "Race Mode") |
| **Scenarios** | Fixed character with unique abilities; 5 regular races on 5 planets in sequence | first race's go (per-race logic as a regular race) | 5th race finish | not handled |

Category details:
- **Precision Driving:** a plain LiveSplit real-time timer will be wrong by 1.5 s × gates hit.
  Options: read the game's time (`EventFinishTime` 0xF0, `BonusTime` 0xF4 on
  `UPlayerRaceEventComponent`) and drive Game Time from it, or track gate bonuses as they
  accrue. Need to check whether `EventFinishTime` already includes the bonus and how
  `BonusTime` behaves (cumulative? sign?). Also the ~0.03 s polling offset matters more here.
  **Verified (2026-10-19), from the HUD VM (`URaceEventVM`, `GWorld, 0x1B0, 0x3D8`):**
  `+0x188 CurrentEventTime` (double) is the running event time **with the 1.5 s gate deductions
  already applied**, so it's the Precision IGT to drive Game Time from. `+0x178 CurrentLapTime`
  (double) is the **raw** lap time without deductions, and it resets each lap.
  On `UPlayerRaceEventComponent` (**verified**): `+0xF0 EventFinishTime` equals the final
  `CurrentEventTime` at the finish, so it's the **adjusted** time and the existing final-time
  logic works unchanged for Precision. `+0xF4 BonusTime` (float) is the **running total** of gate
  deductions, positive, 1.5 per gate (1 gate = 1.5, 2 = 3.0, …). Gates hit = `BonusTime` / 1.5,
  and raw IGT = adjusted time + `BonusTime`.
- **Scenarios:** ranked by **RTA**, so loads, part selection and menus between the 5 races all
  count (mods, 2026-10-19; see **Multi-event categories** below). Each race is handled like a regular race; the extra work is recognising
  the transitions (race N finished → next race loaded) and not resetting on them. Relevant
  pieces: `EContinueRunState` (campaign run flow), `EventRecipe` / `ActiveStage`, race-state
  `LoadingPhase` / `WaitForLevelToLoad` for load removal if it's ruled in.
- **Tales of Podracing:** grid start with countdown, so start on go rather than line crossing.

## Multi-event categories (mods' rules, 2026-10-19)

Official timing for everything below is **RTA**, and every category requires video. We also
track **IGT**, the sum of each race's `EventFinishTime`, for players who want it. Retries and
menus are left out of IGT. Single events (Time Trial, Arcade, Precision) stay IGT-ranked, with
RTA tracked alongside.

| Category | Timing | Start | End |
|---|---|---|---|
| **Arcade Scenarios** | RTA, with IGT included in the submission | **TBD**: the mods time from video and the timer is optional. Likely the scenario's start confirm (ask them) | finish of the scenario's last race |
| **Arcade%** (all 50 events in order; 3 Deluxe excluded; retries allowed) | RTA | **"Start Event"** pressed on *Landspeeder Ace* (a menu press, not the line crossing) | finish of *The Experiment* **with Bronze beaten** |
| **Sebulba%** (fresh save, any difficulty) | RTA | **"Start New Campaign"** selected | final-lap finish vs **Sebulba** (last race of Act 1) |
| **Any%** (fresh save, any difficulty) | RTA | **"Start New Campaign"** selected | final-lap finish vs **Kestar's Podracer** (last race of Act 3) |
| **NG+ Sebulba%** | RTA | **"Accept"** on the campaign-reset *"Are you sure?"* dialog | final-lap finish vs Sebulba |
| **NG+ Any%** | RTA | reset-campaign **"Accept"** | final-lap finish vs Kestar's Podracer |
| **NG+ Champion%** (Champion difficulty) | RTA | reset-campaign **"Accept"** | final-lap finish vs Kestar's Podracer |
| **NG+ Act III** | RTA | **"Continue"** on the Act III loadout check (after *Start Run* → Racer Style and Favors) | final-lap finish vs Kestar's Podracer |

That gives **5 start triggers**: New Campaign, reset Accept, Act III loadout Continue, Arcade
"Start Event", and Scenario start. There are **4 end triggers**, all on the existing final-lap
finish (`bHasFinishedEvent` 0→1) plus an identity check: Sebulba race, Kestar race, The
Experiment with Bronze, and the scenario's last race.

Splits: one per race (campaign or scenario) and one per event (Arcade%). A failed Arcade% attempt
that gets retried must **not** split or end the run. The same goes for failing out and switching
vehicle in NG+ Sebulba%.

Open with the mods:
- [ ] Exact Scenario start point.
- [ ] Is "Real Time" plain RTA, or load-removed? (Assumed plain.)
- [ ] NG+ Champion%: is a fresh-save start also allowed? The rules title says NG+ but the text
      doesn't.

### Memory to find (multi-event categories)

Starts are all menu actions, so they need front-end / UI state rather than race state.
Leads from the dump are marked as *lead* and are unchecked.

| # | What | Used by | Leads |
|---|---|---|---|
| M1 | "Start New Campaign" selected (main menu) | Sebulba%, Any% | **verified**: `UCampaignSubsystem +0xC1 bIsPlayingPrologue` 0→1 (see below) |
| M2 | Reset-campaign "Are you sure?" → **Accept** | NG+ Sebulba% / Any% / Champion% | **verified**: same flag as M1, `bIsPlayingPrologue` 0→1 on confirm. (`UGfnGameInstance +0x268 CampaignResetInfo` was a dud.) |
| M3 | Act III loadout check → **Continue** (after Start Run) | NG+ Act III | **verified**: `UCampaignSubsystem +0xC8 ActiveRun` null → `UCampaignRun*` on Continue; gate on `UCampaignMetaProgression +0x28 MainCampaignCurrentTourIx` = Act III (Tour = Act; index value TBC, presumably 2) |
| M4 | Arcade "Start Event" pressed | Arcade% | front-end arcade VM (`UArcadeEntryVM`); event def = Landspeeder Ace |
| M5 | Scenario start | Scenarios | after the mods rule; probably the same mechanism as M4 |
| M6 | Current campaign **act + race** identity (to recognise the Sebulba and Kestar finals) | all campaign | **verified chain**: `FRaceEventInstance.InternalName` (`stageName`, see **Track / planet / event identity**), e.g. `DAL_SHORT_06_TeamRace_Dry`. Still need the finals' names; act from the campaign progress object |
| M7 | Current arcade **event identity** (Landspeeder Ace, The Experiment) | Arcade% | **verified chain**: same `stageName`, e.g. `EVT_ARC_PRE_BIKE_MAS_A_FWD`. Still need those two events' names |
| M8 | Arcade **medal result** for the finished event (Bronze beaten?) | Arcade% | results / goal state (`WBP_Arcade_Goal` shows beaten vs unbeaten; want the underlying data, not the widget); or compare `EventFinishTime` against the event def's Bronze time |
| M9 | Scenario **race index / last race** | Scenarios | **verified readings**: `EventRecipeState.ActiveStage` (0-indexed) vs `EventStages` count. Still to check that a Scenario is one recipe |
| M10 | Campaign **difficulty** (optional; Champion% validity warning) | NG+ Champion% | *lead*: `APaddockGameState +0x318 PreRunChosenDifficulty`, `UCampaignMetaProgression +0x110 LastPickedDifficulty` (`UCampaignDifficultyDef*`; Rookie / Racer / Ace / Champion) |
| M11 | Load / menu state between races (only if load removal is ever wanted) | all multi-event | race state `LoadingPhase` / `WaitForLevelToLoad`; `EContinueRunState` |

#### `UCampaignSubsystem` (GameInstance subsystem): campaign start triggers

The start triggers for M1–M3 found in-game (2026-10-19) all live here.

| Offset | Type | Field | Use |
|---|---|---|---|
| 0x00C1 | bool | bIsPlayingPrologue | **verified**: flips 0→1 as soon as a campaign is reset (after Accept) **and** when starting a new campaign. One trigger covers M1 and M2 |
| 0x00C8 | UCampaignRun* | ActiveRun | **verified**: null → `UCampaignRun` immediately on the Act III loadout Continue (M3) |
| 0x00E0 | UCampaignMetaProgression* | MetaProgression | → `+0x28 int32 MainCampaignCurrentTourIx` (current Act; check it for NG+ Act III) |

- Start for Sebulba% / Any% / NG+ (all three): `bIsPlayingPrologue` 0→1. The script's category
  setting decides which run it is, since the flag can't tell a new campaign from a reset.
- Start for NG+ Act III: `ActiveRun` 0 → non-zero **and** `MainCampaignCurrentTourIx` = Act III.
  Need to confirm `ActiveRun` doesn't also flip at other points (e.g. starting Acts I/II, resuming
  a run after loading a save). The Tour check should screen out the Act I/II cases.
- TODO: a pointer chain to the subsystem. `UGfnGameInstance::GetCampaignManager()` returns it.
  The fixed path is GameInstance → subsystem collection map, or use whatever path you found it by
  in UE4SS / CE. Write the chain here once settled.
- TODO: confirm the `MainCampaignCurrentTourIx` value for Act III (0- or 1-based).

### Detecting the event type: `EArcadeEventCategories`

Game enum on every arcade event (`UArcadeEventDef +0x0321 Category`, u8; also on
`UArcadeEntryVM +0x015C`, the front-end tile). Values: Default 0, FieldTest 1, **Plane 2**,
Quick 3, **Precision 4**, Acid 5, FireIce 6, Advanced 7, Deluxe 8.

| Value | Maps to |
|---|---|
| `Plane` (2) | Tales of Podracing (internal name for podracers) |
| `Precision` (4) | Arcade — Precision Driving |
| `FieldTest` 1, `Quick` 3, `Acid` 5 | Arcade — Time Trial (themed, e.g. Acid = acid-heavy maps) |
| `FireIce` 6, `Advanced` 7, `Deluxe` 8, `Default` 0 | Arcade - Time Trial |

Reaching it (**verified** 2026-10-19, read Plane 2 on a podracing event): `UArcadeEventDef` is a
`URaceEventDef` subclass, so from the running event: `GameState +0x3F8 EventRecipe.EventStages`
(TArray data ptr) → `[ActiveStage]` `FRaceEventInstance +0x58 AuthoredEvent` → `+0x321 Category`.
For stage 0: `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x58, 0x321` (byte). The
elements are inline, so there is no deref between the data pointer and the field (the earlier
`…0x3F8, 0x0, 0x58…` chain was wrong). Only valid if `AuthoredEvent` is actually a
`UArcadeEventDef`: in campaign it reads undefined, and Scenario races probably won't be arcade
defs either, so decide campaign / Scenario first (or check the class).
Cross-check: `URaceEventVM +0xD8 ModeType` (`ERaceEventModeType`), where `PrecisionDriving` = 8
and `TimeTrial` = 2.

Could auto-select behaviour from this instead of relying only on the user's setting — at least
use it to warn / pick Precision handling inside the Arcade setting.

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

**Start trigger by category (verified in play):** Arcade Time Trials / Precision are a *rolling
start* — the player only gets control once they cross the start line, so start on first line
crossing (`CurrentLapNumber` 0→1). Grid-start events (Tales of Podracing, Scenario races) start
on go (`bIsRaceStarted` 0→1). See **Categories** above.

**v0.1.0 field testing (Arcade):**
- Start is occasionally flaky in Arcade (start-on-line).
- Final time is ~0.03 s off the results screen — moved to `BUGS.md` (#1).
- The HUD lap counter appears very close to, or just after, the moment the player gains control.
  Suspect: `InRace` requires `hudVM != 0`, so if the HUD view model is created on/after the
  `playerLap` 0→1 tick, `start` sees InRace false on that tick and the edge is lost (next tick
  `old.playerLap` is already 1). Fix idea: do not gate start-on-line on the HUD VM, or latch
  the 0→1 edge in `update` and fire once InRace becomes true.

**v0.2.0 changes:** settings split into **Arcade Mode** (start on `playerLap` 0→1, *not* gated on
the HUD VM or `bIsRaceStarted`, only on sane lap values) and **Race Mode** (start on
`bIsRaceStarted` 0→1 with the full InRace + HUD/lap sync check). Added a reset on `playerLap`
dropping back to 0 before finishing, since Arcade may never set `bIsRaceStarted`.
Next: rename settings to Arcade / Scenarios / Tales of Podracing (Race Mode → Tales of
Podracing; Scenarios adds multi-race handling). Known issues are tracked in `BUGS.md`.

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

Where the current state lives — **verified (2026-10-19)**:
- The `UGameFlowStateMachineComponent` is owned by the **game state**, added in its Blueprint
  (no typed C++ member anywhere in the dump), so it is reached through
  `AActor.BlueprintCreatedComponents` (`+0x298`, `TArray<UActorComponent*>`), element 0:

  | | Chain |
  |---|---|
  | component | `"SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x298, 0x0` |
  | `CurrentStateId` (record 0) | `…, 0x1B0, 0x298, 0x0, 0xC0, 0x10` (int) |
  | machine identity: `StateMachineStateIdEnum->Names.Num` | `…, 0x1B0, 0x298, 0x0, 0xC0, 0x8, 0x50` (int) |

  Record *n* is at `0xC0 → + n*0x28`; record count at component `+0xC8`.
- **Every game state carries this component**, not just `ARacingGameState`: outside a race the
  game state is a FrontEnd / Paddock flow state and the record holds that machine instead.
  `CurrentStateId` is therefore ambiguous on its own (Paddock `Leaving` = 5 = race `Racing`).
  The enum's entry count disambiguates: `ESimpleRaceGameModeState` **37**, `EFrontEndFlowState`
  **16**, `EPvpFlowState` ≥14, `EPaddockFlowState` **9**, `EPaddockNarrativeFlowState` **4**.
- `UGameFlowStateMachineComponent` `+0x00C0 TArray<FGameFlowStateRecord> ActiveStateMachines`
- `FGameFlowStateRecord` (size 0x28)
  - `+0x00 TSubclassOf<UGameFlowStateMachine> StateMachineClass`
  - `+0x08 UEnum* StateMachineStateIdEnum` (`Names` TArray data at `+0x48`, count at `+0x50`)
  - `+0x10 int32 CurrentStateId`
  - `+0x14 bool IsNew`
  - `+0x18 double CurrentStateDuration`, `+0x20 double CurrentStateExpirationTime`
- `ARacingGameMode` `+0x04F8 USimpleRaceStateMachine* StateMachine`, `+0x04C8 ARacingGameState* mRaceState`
  (game mode exists locally in singleplayer).
- Still to check: element 0 is the GFSM component in all three game-state Blueprints; how many
  records the paddock holds (narrative machine may ride alongside); the exact state sequences
  on Arcade "Start Event" and on Act III "Start Run" (see `EPaddockFlowState` / `EFrontEndFlowState`
  in `Griffin_enums.hpp`).
- Consequence for the refactor: menu-press starts (S3–S6) and `Run.Phase` become flow-state
  edges. NG+ Act III = `Paddock 2 CampaignSetup → 4 InWorld` (same machine, no load).
  Arcade% / Scenarios = departure from `FrontEnd 1 PrimaryModeSelect`, latched through the
  load (chain reads 0), confirmed by `stageName` once the race machine appears.

## ARacingGameState (size ≥ 0x428)

Reached via `UWorld → GameState`. Simplest single object for start/finish.

| Offset | Type | Field | Use |
|---|---|---|---|
| 0x0348 | TArray<AGfnPlayerState*> | Racers | find local player's state |
| 0x0358 | TArray<AVehiclePawn*> | Vehicles | |
| 0x0368 | double | CountdownEndTime | server time countdown ends — **verified**: a stamp on the `RaceStartTime` clock (e.g. 1670.018), not seconds left |
| 0x0370 | int32 | LapCount | total laps for this event — **verified**. **100** in Elimination campaign events (they run until the top 3 remain) |
| 0x0378 | double | RaceStartTime | server time race started — **verified** |
| 0x0380 | double | RaceTimeoutTime | |
| 0x0388 | bool | bIsRaceStarted | start split candidate — **verified** (address) |
| 0x0389 | bool | bIsRaceFinished | **verified**: player-based (local player's finish), not all racers |
| 0x03D8 | URaceEventVM* | RaceEventViewModel | HUD data: lap, timers, track/planet |
| 0x03F8 | FEventRecipe | EventRecipe | `TArray<FRaceEventInstance> EventStages`: data ptr at 0x3F8, Num at 0x400 — **verified**. Elements inline, 0x308 bytes |
| 0x0408 | FEventRecipeState | EventRecipeState_Replication | `+0x0 int32 ActiveStage` — **verified**, 0-indexed |
| 0x0420 | ASimpleRaceRoute* | RaceRoute | checkpoints |

Delegates (research hooks only): `OnRaceStarted`,
`OnLocalPlayerReachedFinalEventPhase` (final lap?).

Times are server-time doubles; compare against `AGameStateBase` replicated server world time
(offset TBD) if we ever want in-game time.

## Per-player race progress — UPlayerRaceEventComponent

`AGfnPlayerState +0x0368 UPlayerRaceEventComponent* RaceEventComponent`.

| Offset | Type | Field | Use |
|---|---|---|---|
| 0x00C4 | int32 | EventPosition | race position — **verified** |
| 0x00CC | bool | bHasFinishedEvent | **final split** candidate |
| 0x00CD | bool | bHasTimedOut | fail |
| 0x00CF | bool | bHasVehicleWrecked | fail — **verified**: 1 = wrecked out of the race for good |
| 0x00D0 | bool | bHasBeenEliminated | fail (knockout/eliminator) |
| 0x00D4 | int32 | CurrentLapNumber | **lap split** — **verified**: 0 until first line crossing, 0 after leaving race |
| 0x00D8 | uint8 | CurrentSectorNumber | possible sub-splits |
| 0x00E0 | double | SectorStartServerTime | |
| 0x00E8 | double | LapStartServerTime | stamped on each line crossing; finish stamp − start stamp = EventFinishTime |
| 0x00F0 | float | EventFinishTime | −1 until the finish; = results-screen time; drives Game Time (v0.3.0) |
| 0x00F4 | float | BonusTime | **verified**: running total of Precision gate deductions, +1.5 per gate |
| 0x00F8 | float | BestLapTime | **verified** |
| 0x00FC | float | PreviousLapTime | **verified** |
| 0x0120 | ERaceFailReason (u8) | FailReasons | bitflags: Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8, MissedRequiredWin 16 — **verified** (address) |

## HUD view model — URaceEventVM

`ARacingGameState +0x03D8`. Mirrors what the HUD shows; handy for lap and names.

| Offset | Type | Field |
|---|---|---|
| 0x0028 | UTrackDef* | track — **partial**: `→ +0x50 InternalName` resolves in Time Trial / Podracing, bad pointer in Precision; in campaign it is just the map (`DAL_SHORT_06`) |
| 0x0030 | UPlanetDef* | Planet |
| 0x0040 | FText | ModeName |
| 0x00D8 | ERaceEventModeType (u8) | ModeType — **verified** (TimeTrial 2 seen) |
| 0x0140 | int32 | NumLaps — **verified**; 100 in Elimination (hidden on the HUD) |
| 0x016C | int32 | CurrentLapNumber — **verified**: starts at 1, undefined after leaving race |
| 0x0178 | double | CurrentLapTime — **verified**: raw IGT for the current lap, resets each lap, no Precision deductions |
| 0x0188 | double | CurrentEventTime — **verified**: total event time **minus** Precision gate deductions (1.5 s each) |
| 0x01D0 | float | CountdownToRaceFinish |
| 0x01D4 | bool | bIsSuccess — **verified** |

## Track / planet / event identity

- `UTrackDef`: `+0x30 FText PlayerFacingName`, `+0x50 FString InternalName` (stable ID — prefer
  this over localized text), `+0xB8 TSoftObjectPtr<UPlanetDef> Planet`, `+0xE8 bool bIsPointToPoint`,
  `+0xE9 bool bIsReverse`, `+0xEC int32 DefaultLapCount`.
- `UPlanetDef`: `+0x30 FText PlayerFacingName`, `+0xD8 FName EngineFacingName` (stable ID).
- `FRaceEventInstance` (elements of `EventRecipe.EventStages`, index `ActiveStage`; size 0x308,
  stored inline): `+0x00 FText PlayerFacingName`, `+0x10 FString InternalName`, `+0x20 UTrackDef*`,
  `+0x30 uint8 LapCount`, `+0x4A ERaceEventModeType`, `+0x58 URaceEventDef* AuthoredEvent`.
  - **Verified** (2026-10-19), stage 0: `GWorld, 0x1B0, 0x3F8, 0x10` → UTF-16 string. This is the
    event ID to use. Works in every mode seen so far, including Precision where the track chain fails:
    - arcade: `EVT_ARC_<mode>_<vehicle>_<track>_<variant>` — `EVT_ARC_PRE_BIKE_MAS_A_FWD`
      (arcade, Precision, bike, Mastiff, variant A), `EVT_ARC_TMR_PLANE_BGL_PLANE_FWD`;
    - campaign: `<MAP>_<race type>_<condition>` — `DAL_SHORT_06_TeamRace_Dry` (Dalmatian, team race, dry).
  - `+0x30 LapCount` **verified** (matches `ARacingGameState.LapCount`, 100 in Elimination).
  - `+0x58 AuthoredEvent → +0x321 Category` and `→ +0xB8 bShouldSkipCountdown` **verified in arcade**;
    both read undefined in campaign.
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

- [x] Which actor owns `UGameFlowStateMachineComponent`: the game state, via `BlueprintCreatedComponents[0]` (`GWorld, 0x1B0, 0x298, 0x0`). Enum count at `…, 0xC0, 0x8, 0x50` identifies the machine.
- [x] `CurrentLapNumber` is 0 until the first line crossing (HUD counter starts at 1).
- [x] `CurrentLapNumber` ticks on the final crossing too: ends at LapCount+1.
- [x] `bHasFinishedEvent` flips near-perfectly on the finish crossing (revisit if timing drift shows up).
- [x] `bIsRaceFinished` — player finish or all racers? Player-based (2026-10-19).
- [x] Rolling-start events: what state sequence, and when does `bIsRaceStarted` flip?
- [ ] Signatures for `GWorld` / `GEngine` in `SWGR-Win64-Shipping.exe` (UE5-style; verify the
      static address with UE4SS / Cheat Engine first, then write the sigscan).
- [x] GWorld static address + GameState chains (RaceStartTime, bIsRaceStarted, LapCount) resolve live.
- [x] Player race data and HUD VM chains resolve live.
- [x] Track internal name chain (`GWorld, 0x1B0, 0x3D8, 0x28, 0x50`): resolves for Time Trial / Podracing, bad in Precision, map-only in campaign. Superseded by the `FRaceEventInstance.InternalName` chain.
- [x] Is the race state machine's `CurrentStateId` reachable by a fixed chain: yes, `GWorld, 0x1B0, 0x298, 0x0, 0xC0, 0x10`.
- [ ] Pause flag for an optional "pausing stops timer" setting.
- [x] `EArcadeEventCategories` chain: correct chain is `…0x1B0, 0x3F8, 0x58, 0x321` (no `0x0`); reads Plane 2 live. Undefined in campaign.
- [ ] Event `InternalName`s for Landspeeder Ace, The Experiment, and the Sebulba / Kestar finals.
- [ ] Elimination events (`LapCount` 100): how lap splits and the finish behave; v0.4.1 `LapsSane` rejects them (BUGS.md #3).
- [x] Which category values `FireIce` / `Advanced` / `Deluxe` events use (assumed Time Trial).
- [x] Precision Driving IGT: HUD VM `CurrentEventTime` (0x188) already has the gate deductions;
      `CurrentLapTime` (0x178) is raw.
- [x] Precision: `EventFinishTime` = final `CurrentEventTime` (adjusted); `BonusTime` = total
      deduction, 1.5 per gate.
- [ ] Scenarios: state sequence between the 5 races (results → load → next race); what resets falsely.
- [x] Mods' ruling on whether Scenario loads / part selection / menus are timed: Scenarios are RTA,
      so everything counts (2026-10-19). Start point still TBD.
- [ ] Multi-event memory hunt: M1–M11 in **Memory to find** above. M1–M3 found
      (`UCampaignSubsystem`); still need a stable chain to the subsystem and the Act III Tour index.
