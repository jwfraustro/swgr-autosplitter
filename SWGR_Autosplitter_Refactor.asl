//=====================================================================================================================================================================================================
// Star Wars: Galactic Racer — LiveSplit autosplitter (refactor)
// Version: 0.5.0-dev  — migration steps 1–5 implemented (REFACTOR.md). IL family (Time Trial, Precision) behaves like v0.4.1 except that
//                       Elimination events (100 laps) pass LapsSane (BUGS.md #3). Run-length family (Arcade%, campaign): start on leaving
//                       the menu, split once per finished event, never auto-reset; Arcade% has its end condition, the campaign ends still
//                       need event names (step 6). Scenarios: grid-go start, Game Time = IGT sum (frozen outside a live race), split on
//                       every lap and finish, no end condition (the runner's split count ends the run). UNTESTED in LiveSplit as of 2026-10-21.
//                       Will replace SWGR_Autosplitter.asl (v0.4.1) when finished.
//
// READ FIRST
//   REFACTOR.md       — design rationale, the S/E/R catalogue, invariants, remaining work.
//   MEMORY_OFFSETS.md — every address. Offsets are for the current Steam build (GWorld = exe+0x0AE0C968) and WILL break on game patches.
//   DEV_NOTES.md      — game behaviour, enums, the mods' rules, open items.
//   BUGS.md       — ...bugs.
//   SWGR_Autosplitter.asl — the working v0.4.1 script. Port behaviour from there, don't reinvent it.
//
// LAYOUT (REFACTOR.md "Shape")
//   1. Readings      state{}            raw memory values, grouped by owning object. No logic.
//   2. Snapshot      init{} + update{}  vars.Snapshot(current) -> vars.Now / vars.Prev, every derived value computed once per tick.
//   3. Predicates    init{}             vars.* lambdas: gates, edges, timing, identity. Pure functions of a snapshot or (prev, now).
//   4. Run state     init{}             vars.Run: persists across ticks AND races (phase, IGT total, dead-race stamps, ...).
//   5. Profiles      init{}             vars.Profiles[category]: family (IL / Run), start edge, end condition, what splits.
//   Action blocks (start/split/reset/gameTime/isLoading) only read vars.Prev / vars.Now / vars.Run / vars.Run.Profile — never current/old.
//
// MARKERS used in comments
//   HAVE      exists in v0.4.1; port it.                 VERIFIED  address/behaviour confirmed live, not used by v0.4.1 yet.
//   LEAD      candidate offset from the dump, unverified. FIND      no candidate yet; see DEV_NOTES.md "Open".
//   PARTIAL   resolves live, but only in some event types; the comment says which.
//   TODO(stepN)  what to fill in; step numbers are the original migration order (REFACTOR.md "Status and remaining work").
//
// ASL facts to remember: a reading whose chain fails reads as 0/default, not an error; gameTime{} runs before
// split{}; isLoading{} == true freezes Game Time; settings are checkboxes (no radio buttons); no classes — use ExpandoObject.
//=====================================================================================================================================================================================================


//=====================================================================================================================================================================================================
// 1. READINGS  (MEMORY_OFFSETS.md)
// One line per value. Commented-out lines are LEAD / FIND / PARTIAL entries: uncomment once the chain is verified live.
// Patch handling (later): add further state("SWGR-Win64-Shipping", "<build>") blocks and set `version` in init{}.
// Cheat Engine mirror: cheat_engine_resources/SWGR_Refactor.CT, built by make_refactor_ct.py (hand-transcribed — update it when a chain here changes).
//=====================================================================================================================================================================================================
state("SWGR-Win64-Shipping")
{
    //--- A0. Flow state machine  (GameState -> AActor.BlueprintCreatedComponents[0] = UGameFlowStateMachineComponent: exe, 0x0AE0C968, 0x1B0, 0x298, 0x0).
    //    EVERY GameState carries it: USimpleRaceStateMachine in a race, UFrontEndStateMachine in the menus, UPaddockStateMachine in the campaign hub.
    //    flowState alone is ambiguous (Paddock Leaving 5 == race Racing 5): always pair it with flowEnumCount, which identifies the machine.
    //    Chain reads 0 through a level load (GameState destroyed) — that is the "None" machine, and it is expected, not an error.
    int    flowState        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x10;        // VERIFIED  ActiveStateMachines[0].CurrentStateId — id in the machine's own enum (DEV_NOTES "Flow state machine")
    int    flowEnumCount    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x8, 0x50;   // VERIFIED  ActiveStateMachines[0].StateMachineStateIdEnum->Names.Num: 37 race, 16 front end, 9 paddock, 4 paddock narrative, >=14 pvp, 0 = loading
    int    flowRecordCount  : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC8;              // VERIFIED (field)  ActiveStateMachines.Num — expect 1; Debug warning if ever 2 (record 0 may then be the wrong machine)
    // byte   primaryFlow      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x398;                         // LEAD  UGfnGameInstance.PrimaryFlow (EGfnPrimaryFlow): Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4 — Debug only

    //--- A. ARacingGameState  (GWorld -> GameState: exe, 0x0AE0C968, 0x1B0). Only an ARacingGameState while FlowMachine == "Race"; garbage otherwise.
    byte   raceStarted      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x388;   // HAVE  bIsRaceStarted: 0 -> 1 when the grid is released (countdown over)
    int    totalLaps        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x370;   // HAVE  LapCount: laps in this event. Elimination (campaign) events read 100 = "until top 3 remain"
    double raceStartTime    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x378;   // HAVE  RaceStartTime (server time): base for lap-split IGT; dead-race guard
    byte   raceFinished     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x389;   // VERIFIED  bIsRaceFinished: player-based (local player's finish), not all racers
    double countdownEndTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x368;   // VERIFIED  CountdownEndTime: server-time stamp on the RaceStartTime clock (e.g. 1670.018), not a 3.0 s countdown
    int    activeStage      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x408;   // VERIFIED  EventRecipeState.ActiveStage: 0-indexed stage in the recipe (M9)
    int    stageCount       : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x400;   // VERIFIED  EventRecipe.EventStages.Num (TArray count = data ptr + 0x8) (M9)

    //--- B. URaceEventVM  (HUD view model: GameState + 0x3D8). Pointer is 0 / chain breaks once the player leaves the race.
    long   hudVM            : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8;          // HAVE  presence == HUD exists
    int    hudLap           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x16C;   // HAVE  CurrentLapNumber as shown on HUD: starts at 1
    double hudLapTime       : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x178;   // VERIFIED  CurrentLapTime: raw lap IGT, resets each lap, no Precision deductions
    double hudEventTime     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x188;   // VERIFIED  CurrentEventTime: running event IGT with Precision gate deductions applied
    int    hudNumLaps       : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x140;   // VERIFIED  NumLaps: matches totalLaps; 100 in Elimination events (hidden on the HUD)
    byte   hudModeType      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x0D8;   // VERIFIED  ERaceEventModeType: TimeTrial 2 seen live; PrecisionDriving 8 (dump)
    byte   hudSuccess       : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x1D4;   // VERIFIED  bIsSuccess — finish outcome
    // long   trackNamePtr     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x28, 0x50;        // PARTIAL  track -> InternalName: OK for Time Trial / Podracing, bad ptr in Precision; campaign = map only ("DAL_SHORT_06"). Use stageName instead
    int    trackNameLen     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x28, 0x58;        // VERIFIED  FString length (int32 at +0x8)

    //--- C. UPlayerRaceEventComponent  (GWorld -> OwningGameInstance -> LocalPlayers[0] -> PlayerController -> PlayerState -> RaceEventComponent)
    int    playerLap          : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD4; // HAVE  CurrentLapNumber: 0 until first crossing; LapCount+1 after the finish; 0 after leaving
    byte   finished           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCC; // HAVE  bHasFinishedEvent: 0 -> 1 on the final crossing. End trigger for EVERY category
    float  finishTime         : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF0; // HAVE  EventFinishTime: -1 until the finish, then the results-screen time (Precision: already adjusted)
    float  bonusTime          : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF4; // VERIFIED  BonusTime: running total of Precision gate deductions, +1.5 per gate
    double lapStartServerTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xE8; // HAVE  LapStartServerTime: stamp at each crossing; dead-race guard
    int    eventPosition      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xC4;  // VERIFIED  EventPosition — campaign "must win"?
    byte   failReasons        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0x120; // VERIFIED  ERaceFailReason bitflags: Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8, MissedRequiredWin 16
    // byte   timedOut           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCD;  // LEAD  bHasTimedOut
    byte   wrecked            : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCF;  // VERIFIED  bHasVehicleWrecked: 1 = wrecked out of the race for good (not a respawnable crash)
    byte   eliminated         : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD0;  // VERIFIED  bHasBeenEliminated
    float  bestLapTime        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF8;  // VERIFIED  BestLapTime — display only
    float  prevLapTime        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xFC;  // VERIFIED  PreviousLapTime — display only

    //--- D. Event identity  (GameState + 0x3F8 EventRecipe.EventStages -> FRaceEventInstance[ActiveStage]).
    //    EventStages is TArray<FRaceEventInstance>: elements are INLINE (0x308 bytes each), so there is NO deref after the data ptr.
    //    Stage 0 shown (single-race events). Stage N = data ptr + N * 0x308; state{} can't index, so read it in update{} if Scenarios need it.
    long      stageNamePtr  : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x10;          // VERIFIED  FRaceEventInstance.InternalName FString data ptr
    string128 stageName     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x10, 0x0;     // VERIFIED  InternalName text (UTF-16). Arcade "EVT_ARC_PRE_BIKE_MAS_A_FWD"; campaign "DAL_SHORT_06_TeamRace_Dry". EventId (M6 / M7)
    int    stageNameLen     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x18;        // VERIFIED  FString length
    long   authoredEvent    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x58;        // VERIFIED  URaceEventDef* — class check (UArcadeEventDef vs campaign def)
    byte      arcadeCategory: "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x58, 0x321;   // VERIFIED  EArcadeEventCategories: Plane 2 (Podracing) seen live, Precision 4. Undefined in campaign (def isn't an arcade def)
    byte      skipCountdown : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x58, 0xB8;    // VERIFIED  (arcade)  URaceEventDef.bShouldSkipCountdown — rolling vs grid start. Undefined in campaign
    byte      stageLapCount : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x30;          // VERIFIED  FRaceEventInstance.LapCount — matches totalLaps (100 in Elimination)

    //--- E. Campaign  (UCampaignSubsystem — GameInstance subsystem. Chain TBD: UGfnGameInstance::GetCampaignManager(); see DEV_NOTES "Campaign start triggers")
    // byte   playingPrologue    : ???, 0xC1;   // VERIFIED (field) / FIND (chain)  bIsPlayingPrologue: 0 -> 1 on "Start New Campaign" AND on reset "Accept" (M1, M2)
    // long   activeRun          : ???, 0xC8;   // VERIFIED (field) / FIND (chain)  ActiveRun: null -> UCampaignRun* on the Act III loadout "Continue" (M3). Check it doesn't flip elsewhere.
    // int    campaignAct        : ???, 0xE0, 0x28;   // LEAD  MetaProgression -> MainCampaignCurrentTourIx (Tour = Act). Act III index value TBC (0- or 1-based)
    // long   campaignDifficulty : ???, 0xE0, 0x110;  // LEAD  MetaProgression -> LastPickedDifficulty (UCampaignDifficultyDef*). Champion% warning only (M10)
    // byte   continueRunState   : ???;               // LEAD  EContinueRunState: Paddock 0 ... StartEvent 4, PostEvent 5, LeavePlanet 6 — between-race phases (M11)

    //--- F. Front end / menus.  Every run-starting press is a flow edge (A0: the FrontEnd / Paddock machine goes away). M4 / M5 closed.
    // byte   medalResult         : ???;   // DEFERRED (M8)  Bronze beaten on the finished event. Not an MVP check — the moderator sees the medal. Only if runners ask.

    //--- G. Engine / misc
    // long   pauserPlayerState : "SWGR-Win64-Shipping.exe", 0x0AE0C968, ???, ???, ???;   // LEAD  AWorldSettings.PauserPlayerState via UWorld -> PersistentLevel -> WorldSettings. Non-null while paused (UE standard)
    // double worldTime         : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x2E0;   // VERIFIED-BAD  ReplicatedWorldTimeSecondsDouble LAGS the crossing stamps — not a live clock (BUGS.md #1). Do not use.
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// startup{}: settings tree and constants. Runs once when the script loads.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
startup
{
    //--- Category (pick one). No auto-detect: the runner's choice selects the profile (see 5. PROFILES).
    settings.Add("Category", true, "Category — pick ONE");
        settings.SetToolTip("Category", "Select exactly one. The category decides the start trigger, the end condition, what counts as a split and when the timer resets.");
    settings.Add("Cat_TimeTrial",    true,  "Arcade — Time Trial",        "Category");
        settings.SetToolTip("Cat_TimeTrial",    "Single Arcade time trial (rolling start). Starts on the first start-line crossing; ends on the final-lap finish. Game Time = in-game time.");
    settings.Add("Cat_Precision",    false, "Arcade — Precision Driving", "Category");
        settings.SetToolTip("Cat_Precision",    "Single Precision Driving event. As Time Trial; Game Time already includes the 1.5 s gate deductions.");
    // settings.Add("Cat_Podracing",    false, "Tales of Podracing",         "Category");
    //     settings.SetToolTip("Cat_Podracing",    "Single podracer race (grid start). Starts when the countdown ends; ends on the final-lap finish.");

    // Run-length categories: the timer starts the moment you leave the menu (any 'Start Event' / 'Start' / 'New Campaign' / reset 'Accept').
    // The script does not check WHICH event you started on — the moderator does, from the video. A wrong start is your reset.
    settings.Add("Cat_Scenarios",    false, "Arcade Scenarios",           "Category");
        settings.SetToolTip("Cat_Scenarios",    "5 races in sequence. IGT: Game Time runs only during a live race (countdowns, loads and menus between races are not counted). Starts on the first race's go; splits on every lap and every finish; no end condition — the run ends when your last split is hit, so lay out your splits to match (e.g. 5 races x N laps, or 5 race splits with lap splits off). Never auto-resets.");
    settings.Add("Cat_ArcadePct",    false, "Arcade%",                    "Category");
        settings.SetToolTip("Cat_ArcadePct",    "All events in order. RTA. Starts when you leave the menu; splits on every finish (a redone event splits again — skip or undo the split yourself); ends on The Experiment's finish. Never auto-resets.");
    settings.Add("Cat_SebulbaPct",   false, "Sebulba%",                   "Category");
        settings.SetToolTip("Cat_SebulbaPct",   "Fresh save. RTA. Starts when you leave the menu ('Start New Campaign'); ends on the final-lap finish vs Sebulba (last race of Act I). End event name still to be found.");
    settings.Add("Cat_AnyPct",       false, "Any%",                       "Category");
        settings.SetToolTip("Cat_AnyPct",       "Fresh save. RTA. Starts when you leave the menu ('Start New Campaign'); ends on the final-lap finish vs Kestar's Podracer (last race of Act III). End event name still to be found.");
    settings.Add("Cat_NGSebulbaPct", false, "NG+ Sebulba%",               "Category");
        settings.SetToolTip("Cat_NGSebulbaPct", "RTA. Starts when you leave the menu (campaign-reset 'Accept'); ends vs Sebulba. End event name still to be found.");
    settings.Add("Cat_NGAnyPct",     false, "NG+ Any%",                   "Category");
        settings.SetToolTip("Cat_NGAnyPct",     "RTA. Starts when you leave the menu (campaign-reset 'Accept'); ends vs Kestar's Podracer. End event name still to be found.");
    settings.Add("Cat_NGChampion",   false, "NG+ Champion%",              "Category");
        settings.SetToolTip("Cat_NGChampion",   "As NG+ Any% on Champion difficulty (not checked by the script).");
    settings.Add("Cat_NGActIII",     false, "NG+ Act III",                "Category");
        settings.SetToolTip("Cat_NGActIII",     "RTA. Starts on 'Start Run' at the Act III loadout check (paddock CampaignSetup -> InWorld); ends vs Kestar's Podracer. End event name still to be found.");

    //--- Splits
    settings.Add("LapSplits",   true,  "Split on each lap");
        settings.SetToolTip("LapSplits",   "Splits on every completed lap except the last (the finish / race split covers that).");
    settings.Add("RaceSplits",  true,  "Split on each race / event (run-length categories)");
        settings.SetToolTip("RaceSplits",  "Splits on every race or event finish while the run is not over. A redone event splits again: skip or undo the split yourself.");
    settings.Add("FinishSplit", true,  "Split on the run's final finish");
        settings.SetToolTip("FinishSplit", "Splits when the category's end condition is met.");

    //--- Reset
    settings.Add("ResetOnLeave", true, "Reset on restart / leaving the race (single-race categories only)");
        settings.SetToolTip("ResetOnLeave", "Single-race categories: reset when the race is restarted or quit before the finish. Run-length categories never auto-reset; reset the timer yourself.");

    //--- Timing
    settings.Add("PauseStopsTimer", false, "Pausing stops Game Time (not implemented)");
        settings.SetToolTip("PauseStopsTimer", "Needs the pause flag (pauserPlayerState LEAD, group G). Does nothing yet.");

    //--- Debug
    settings.Add("Debug", false, "Debug output");
        settings.SetToolTip("Debug", "Prints every derived edge and profile decision to the debug log (DbgView).");

    // Category setting ids in display order. First ticked one wins (see vars.SelectProfile).
    vars.CategoryIds = new List<string> {
        "Cat_TimeTrial", "Cat_Precision", /*"Cat_Podracing",*/ "Cat_Scenarios", "Cat_ArcadePct",
        "Cat_SebulbaPct", "Cat_AnyPct", "Cat_NGSebulbaPct", "Cat_NGAnyPct", "Cat_NGChampion", "Cat_NGActIII"
    };

    // Event identities (FRaceEventInstance.InternalName, compared against vars.EventId(now)). Used to stop the timer, e.g. when the final race of a category is reached.
    //vars.EVENT_LANDSPEEDER_ACE = "EVT_ARC_TT_CAR_MAS_A_SHORT_02";   // Landspeeder Ace — (Arcade% first event; reference only)
    vars.EVENT_THE_EXPERIMENT  = "EVT_ARC_TT_CAR_WHP_A_FWD";        // The Experiment (Arcade% end, E3)
    vars.EVENT_SEBULBA_FINAL   = "";   // FIND  the Sebulba race, last race of Act I (E4). "" = end condition can never fire
    vars.EVENT_KESTAR_FINAL    = "";   // FIND  the Kestar's Podracer race, last race of Act III (E5). "" = end condition can never fire

    vars.PRECISION_GATE_SECONDS = 1.5; // The number of seconds a player's race time is reduced by in Precision Driving

    // Flow state machine (A0). Machine from the state-id enum's entry count (VERIFIED 2026-10-19); state ids from Griffin_enums.hpp.
    vars.FlowMachines = new Dictionary<int, string> { { 37, "Race" }, { 16, "FrontEnd" }, { 9, "Paddock" }, { 4, "PaddockNarrative" } };   // EPvpFlowState (>=14) not needed: singleplayer only
    // ESimpleRaceGameModeState ("Race")

    vars.RACE_LOADING = 1;  vars.RACE_WAIT_LEVEL = 10;  vars.RACE_WAIT_CLIENTS = 11;  vars.RACE_PRERACE = 12;  vars.RACE_INTRO = 13;
    vars.RACE_COUNTDOWN = 4;  vars.RACE_ROLLING_START = 18;  vars.RACE_RACING = 5;  vars.RACE_INTERMISSION = 23;
    vars.RACE_POSTRACE = 6;  vars.RACE_OUTRO = 14;  vars.RACE_RESULTS = 15;  vars.RACE_PREPARE_TO_LEAVE = 30;  vars.RACE_LEAVING = 8;

    // EFrontEndFlowState ("FrontEnd")
    vars.FE_ROOT = 0;  vars.FE_PRIMARY_MODE_SELECT = 1;  vars.FE_LAUNCHING_CAMPAIGN = 2;  vars.FE_QUICKRACE_SETUP = 3;  vars.FE_LAUNCHING_QUICKRACE = 4;
    // EPaddockFlowState ("Paddock")
    vars.PAD_ROOT = 0;  vars.PAD_INTRO = 1;  vars.PAD_CAMPAIGN_SETUP = 2;  vars.PAD_PREWORLD = 3;  vars.PAD_INWORLD = 4;  vars.PAD_LEAVING = 5;

    refreshRate = 60;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// init{}: runs on attach. Layers 2–5 are defined here as vars.* lambdas / objects. Nothing here reads memory.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
init
{
    // TODO(later): game-build detection -> `version = "...";` to pick between state blocks when the game patches.

    vars.Log = (Action<string>)((msg) => { if (settings["Debug"]) print("[SWGR] " + msg); });

    //=================================================================================================================================================================================================
    // 3. PREDICATES AND EDGES
    // Conventions: `s` is a snapshot (vars.Now or vars.Prev); `(p, n)` is (vars.Prev, vars.Now).
    //=================================================================================================================================================================================================

    //--- 3a. Gates ("where are we?")

    // Does GameState look like an ARacingGameState? (same offsets read garbage from the menu GameState)
    // Flow says so AND the lap values are sane. Debug / cross-check only so far: InRace below is what the ILs run on.
    vars.IsRaceGameState = (Func<dynamic, bool>)((s) => s.FlowMachine == "Race" && s.LapsSane);

    // Is the local player in a live race?
    vars.InRace = (Func<dynamic, bool>)((s) => s.HudVmPresent && s.LapsSane);

    // ...and do the lap counters agree? Only stable away from a crossing (the two counters can update a tick apart).   HAVE (v0.4.1 InRace + LapsInSync)
    vars.InRaceStrict = (Func<dynamic, bool>)((s) => s.HudVmPresent && s.LapsSane && s.LapsInSync);

    // Is the game paused?  Definition: pauserPlayerState != 0.                                   LEAD (reading commented out)   TODO(step8)
    vars.IsPaused = (Func<dynamic, bool>)((s) => false);

    // Between levels / race not live?  Chain broken (GameState destroyed) or the race machine is still loading.
    vars.IsLoading = (Func<dynamic, bool>)((s) =>
        s.FlowMachine == "None"
        || (s.FlowMachine == "Race" && (s.FlowState == vars.RACE_LOADING || s.FlowState == vars.RACE_WAIT_LEVEL || s.FlowState == vars.RACE_WAIT_CLIENTS)));

    // In a menu (front end, paddock, or a paddock cutscene), not a race, not a load?  PaddockNarrative counts as menu so a cutscene can't fire S3.
    vars.InMenu = (Func<dynamic, bool>)((s) => s.FlowMachine == "FrontEnd" || s.FlowMachine == "Paddock" || s.FlowMachine == "PaddockNarrative");

    // Did the race we were in just go away (restart / quit / between races)?
    // Flow: the race machine left or entered PrepareToLeave / Leaving. Legacy (v0.4.1 reset conditions): HUD VM gone, or playerLap >= 1 -> 0.
    // The IL reset{} keeps the exact v0.4.1 raw conditions; this union is for Debug (run-length profiles never reset).   HAVE + VERIFIED flow
    vars.IsTearingDown = (Func<dynamic, dynamic, bool>)((p, n) =>
        (p.FlowMachine == "Race" && (n.FlowMachine != "Race" || n.FlowState == vars.RACE_PREPARE_TO_LEAVE || n.FlowState == vars.RACE_LEAVING))
        || (p.HudVmPresent && !n.HudVmPresent)
        || (p.playerLap >= 1 && n.playerLap == 0));

    //--- 3b. Edges ("what just happened?")  — all (p, n). Race-value start edges must also pass vars.NewRaceInstance.

    // Grid released: raceStarted 0 -> 1 while in race, before the first crossing, counters in sync.
    vars.RaceGoEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        vars.InRace(n) && n.raceStarted == 1 && p.raceStarted == 0 && n.playerLap == 0 && n.LapsInSync);

    // First start-line crossing (rolling start): playerLap 0 -> 1, !Finished, LapsSane.
    // Deliberately NOT gated on the HUD VM (v0.1.0 field testing): the VM can appear on/after the crossing tick.
    vars.FirstCrossingEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        n.playerLap == 1 && p.playerLap == 0 && !n.Finished && n.LapsSane);

    // Lap completed: playerLap k -> k+1 with 1 <= k < totalLaps, !Finished. (0 -> 1 is the start crossing; totalLaps -> totalLaps+1 is the finish.)
    vars.LapEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        n.playerLap == p.playerLap + 1 && p.playerLap >= 1 && n.playerLap <= n.totalLaps && !n.Finished);

    // Player crossed the final line: finished 0 -> 1. EventFinishTime lands on the same tick.
    vars.FinishEdge = (Func<dynamic, dynamic, bool>)((p, n) => n.Finished && !p.Finished);

    // A finish that COUNTS: FinishEdge with a real time, in a live race with a real RaceStartTime, and not the torn-down race's memory replaying.
    // While the next level loads, the chain flickers back to the dead race GameState and replays finished = 1 (BUGS.md #2 for starts, #6 for finishes).
    // Seen live in a Scenario (2026-10-20/21): once with the dead RaceStartTime (caught by the dead-stamp check) and once more with RaceStartTime
    // read as 0, HUD VM gone and EventId empty — a half-torn-down state that no stamp comparison can catch, hence the InRace and RaceStamp > 0 guards
    // (RaceStartTime reads -1 before a start and 0 through a broken chain; a real finish always has the HUD VM and a positive stamp).
    // A dead stamp of 0 means nothing was torn down yet.
    // Drives bookkeeping, gameTime{}'s finish snap, the race split and every run-length end condition. E1 (IL) stays on the raw v0.4.1 edge.
    vars.ValidFinishEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        vars.FinishEdge(p, n) && n.FinishIgt >= 0 && vars.InRace(n) && n.RaceStamp > 0
        && (vars.Run.DeadRaceStamp == 0.0 || n.RaceStamp != vars.Run.DeadRaceStamp));

    // Player failed the event: Failed false -> true. Debug only — no reset policy uses it (an IL retry goes through R1).
    vars.FailEdge = (Func<dynamic, dynamic, bool>)((p, n) => n.Failed && !p.Failed);

    // Race identity established: in race with a live RaceStamp we have not booked yet (and not the dead race's).
    // Arcade: fires at the first crossing (RaceStartTime is set there); grid events: at the countdown end. Drives OnRaceEntered.
    vars.RaceEnteredEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        vars.InRace(n) && n.RaceStamp > 0 && n.RaceStamp != vars.Run.LastRaceStamp && n.RaceStamp != vars.Run.DeadRaceStamp);   // RaceStartTime reads -1 before the start

    // Is this a real new race and not the torn-down race's memory replaying (BUGS.md #2)?
    // `kind` says which stamp identifies the start — "Lap" for crossing starts (v0.4.1 Arcade checked LapStartServerTime),
    // "Race" for grid starts (v0.4.1 Race checked RaceStartTime), "None" for flow-edge starts. A dead stamp of 0 means nothing was torn down yet.
    vars.NewRaceInstance = (Func<dynamic, dynamic, string, bool>)((p, n, kind) =>
    {
        if (kind == "Lap")  return vars.Run.DeadLapStamp  == 0.0 || n.LapStamp  != vars.Run.DeadLapStamp;
        if (kind == "Race") return vars.Run.DeadRaceStamp == 0.0 || n.RaceStamp != vars.Run.DeadRaceStamp;
        return true;
    });

    //--- Flow edges (A0). Implemented: they are pure string compares on the snapshot and are needed in step 1 to record the state sequences.
    // Any flow transition, including into/out of "None" (level load).
    vars.FlowEdge  = (Func<dynamic, dynamic, bool>)((p, n) => p.Flow != n.Flow);
    // Entered machine.state this tick.   e.g. vars.FlowEnter(p, n, "Paddock", vars.PAD_INWORLD)
    vars.FlowEnter = (Func<dynamic, dynamic, string, int, bool>)((p, n, machine, state) => p.Flow != n.Flow && n.FlowMachine == machine && n.FlowState == state);
    // Left machine.state this tick (to anything, including "None").
    vars.FlowLeave = (Func<dynamic, dynamic, string, int, bool>)((p, n, machine, state) => p.Flow != n.Flow && p.FlowMachine == machine && p.FlowState == state);

    // Left the menu: the FrontEnd / Paddock machine gave way to Race, or to "None" (the GameState is gone for the level load).
    // This IS the RTA start for the RTA run-length categories ("Start Event", "New Campaign", campaign-reset "Accept") — within one poll
    // of the press, and the timer visibly starts on it. Where the game goes next is deliberately not checked (REFACTOR.md "What the script is for").
    //                                                                                             VERIFIED readings   (S3)
    vars.MenuLeaveEdge = (Func<dynamic, dynamic, bool>)((p, n) => p.InMenu && !n.InMenu);

    // Act III "Start Run" after the loadout check: left Paddock.CAMPAIGN_SETUP 2 for Paddock.{PREWORLD 3, INWORLD 4}. Same machine, no level load.
    // Whether PreWorld 3 is seen within a poll (2 -> 3 -> 4) or skipped (2 -> 4) is TBC; both land here. No Act / activeRun check.
    //                                                                                             VERIFIED flow; sequence TBC   (S4)
    vars.ActIIIStartRunEdge = (Func<dynamic, dynamic, bool>)((p, n) =>
        vars.FlowLeave(p, n, "Paddock", vars.PAD_CAMPAIGN_SETUP) && n.FlowMachine == "Paddock" && (n.FlowState == vars.PAD_PREWORLD || n.FlowState == vars.PAD_INWORLD));

    //--- 3c. Timing ("what time is it?")  — all (s) -> double, in seconds.

    // Running event IGT (Precision-adjusted): hudEventTime.
    vars.EventIgt = (Func<dynamic, double>)((s) => (double)s.hudEventTime);

    // Running raw lap time: hudLapTime.
    vars.LapIgt = (Func<dynamic, double>)((s) => (double)s.hudLapTime);

    // Exact elapsed race time at the last crossing: LapStamp - RaceStamp. RaceStamp = first-crossing stamp (Arcade) or countdown end (grid).
    // Raw: the stamps know nothing about Precision gate deductions (Precision's gameTime{} uses hudEventTime instead).
    vars.LapSplitIgt = (Func<dynamic, double>)((s) => (double)s.LapStamp - (double)s.RaceStamp);

    // Final adjusted time: finishTime (-1 before the finish). Precision: gate deductions already applied.
    vars.FinishIgt = (Func<dynamic, double>)((s) => (double)s.finishTime);

    // Final unadjusted time: finishTime + bonusTime.
    vars.RawFinishIgt = (Func<dynamic, double>)((s) => (double)s.finishTime + (double)s.bonusTime);

    // Precision gates driven through: round(bonusTime / PRECISION_GATE_SECONDS).
    vars.GatesHit = (Func<dynamic, int>)((s) => (int)Math.Round((double)s.bonusTime / vars.PRECISION_GATE_SECONDS));

    // Game Time for the whole run: Run.IgtTotal + (InRace ? EventIgt : 0). Covers ILs (IgtTotal = 0) and multi-race runs with one formula.
    // Defined for Debug / step 8; gameTime{} still runs on real time + stamp re-sync (v0.4.1 behaviour).
    vars.RunGameTime = (Func<dynamic, double>)((s) => (double)vars.Run.IgtTotal + (s.InRace && !s.Finished ? vars.EventIgt(s) : 0.0));

    //--- 3d. Identity ("which race / event is this?")

    // Track / map name: FString at HUD VM -> track -> InternalName (UTF-16). Bad ptr in Precision; campaign gives only the map ("DAL_SHORT_06").
    // Prefer deriving the map from EventId's prefix where needed.                                  PARTIAL   TODO(step6)
    vars.MapId = (Func<dynamic, string>)((s) => "");

    // Stable event name: stageName = EventStages[ActiveStage].InternalName. Arcade "EVT_ARC_<mode>_<vehicle>_<track>_<variant>"
    // (e.g. EVT_ARC_PRE_BIKE_MAS_A_FWD = arcade precision, bike, Mastiff); campaign "<MAP>_<race type>_<condition>"
    // (e.g. DAL_SHORT_06_TeamRace_Dry). Only meaningful while the race GameState exists; "" otherwise.
    vars.EventId = (Func<dynamic, string>)((s) => s.FlowMachine == "Race" ? (string)(s.stageName ?? "") : "");

    // Is this the named event?  An empty name never matches (so an unfilled end-event constant can never end a run).
    vars.IsEvent = (Func<dynamic, string, bool>)((s, name) => name != "" && s.EventId == name);

    // TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown. OPTIONAL — Debug mismatch warning only, never selects behaviour.
    // Definition: arcadeCategory if authoredEvent is an arcade def (Plane 2 -> Podracing, Precision 4 -> Precision, else TimeTrial);
    // Campaign if CampaignRunActive; Scenario if stageCount > 1 and not campaign.                 VERIFIED readings (arcadeCategory garbage in campaign: check campaign FIRST)   TODO(optional)
    vars.EventKind = (Func<dynamic, string>)((s) => "Unknown");

    // Last race of a multi-stage recipe?  StageIndex == StageCount - 1 (ActiveStage is 0-indexed). Only meaningful with the race GameState.   VERIFIED readings (M9)
    vars.IsLastStage = (Func<dynamic, bool>)((s) => s.FlowMachine == "Race" && s.StageCount > 0 && s.StageIndex == s.StageCount - 1);


    //=================================================================================================================================================================================================
    // 2. SNAPSHOT
    // vars.Snapshot(current) builds an ExpandoObject with raw copies + every derived value, computed ONCE per tick in update{}.
    // Action blocks read vars.Now / vars.Prev only. Add a property here whenever a reading or predicate is added above.
    //=================================================================================================================================================================================================
    vars.Snapshot = (Func<dynamic, dynamic>)((c) =>
    {
        dynamic s = new System.Dynamic.ExpandoObject();

        //--- raw copies (so predicates never need `current`)
        s.flowState          = c.flowState;
        s.flowEnumCount      = c.flowEnumCount;
        s.flowRecordCount    = c.flowRecordCount;
        // s.primaryFlow     = c.primaryFlow;           // LEAD
        s.raceStarted        = c.raceStarted;
        s.totalLaps          = c.totalLaps;
        s.raceStartTime      = c.raceStartTime;
        s.hudVM              = c.hudVM;
        s.hudLap             = c.hudLap;
        s.hudLapTime         = c.hudLapTime;
        s.hudEventTime       = c.hudEventTime;
        s.playerLap          = c.playerLap;
        s.finished           = c.finished;
        s.finishTime         = c.finishTime;
        s.bonusTime          = c.bonusTime;
        s.lapStartServerTime = c.lapStartServerTime;
        s.raceFinished       = c.raceFinished;
        s.countdownEndTime   = c.countdownEndTime;
        s.activeStage        = c.activeStage;
        s.stageCount         = c.stageCount;
        s.hudNumLaps         = c.hudNumLaps;
        s.hudModeType        = c.hudModeType;
        s.hudSuccess         = c.hudSuccess;
        s.eventPosition      = c.eventPosition;
        s.failReasons        = c.failReasons;
        s.wrecked            = c.wrecked;
        s.eliminated         = c.eliminated;
        s.bestLapTime        = c.bestLapTime;
        s.prevLapTime        = c.prevLapTime;
        s.stageName          = c.stageName;
        s.arcadeCategory     = c.arcadeCategory;
        s.skipCountdown      = c.skipCountdown;
        s.stageLapCount      = c.stageLapCount;
        // s.authoredEvent   = c.authoredEvent;        // LEAD
        // s.playingPrologue = c.playingPrologue;      // VERIFIED field / FIND chain (M1, M2)
        // s.activeRun       = c.activeRun;            // VERIFIED field / FIND chain (M3)
        // s.campaignAct     = c.campaignAct;          // LEAD
        // s.pauserPlayerState = c.pauserPlayerState;  // LEAD

        //--- derived: flow (A0). Implemented — read-only, and step 1 needs it to log the state sequences.
        //    FlowMachine: "None" while the chain is broken (level load), "Unknown" for a count we don't map, else the machine name.
        var machines = (Dictionary<int, string>)vars.FlowMachines;
        int cnt = (int)c.flowEnumCount;
        string fm = (cnt == 0) ? "None" : (machines.ContainsKey(cnt) ? machines[cnt] : "Unknown");
        s.FlowMachine = fm;
        s.FlowState   = (int)c.flowState;
        s.Flow        = (fm == "None") ? "None" : fm + "." + s.FlowState;                     // e.g. "Race.5", "Paddock.4" — the key edges are detected on

        //--- derived: presence / sanity                                                         status
        s.HudVmPresent = c.hudVM != 0;                                                        // HAVE
        // v0.4.1 bound was totalLaps < 100; Elimination events report 100 (BUGS.md #3), so the bound is now <= 100.
        s.LapsSane     = c.totalLaps > 0 && c.totalLaps <= 100 && c.playerLap >= 0 && c.playerLap <= c.totalLaps + 1;   // HAVE (v0.4.1 vars.LapsSane)
        s.LapsInSync   = c.hudLap == c.playerLap + 1;                                         // HAVE (v0.4.1 vars.LapsInSync)
        s.InRace       = vars.InRace(s);                                                      // HAVE — after LapsSane / HudVmPresent
        s.RaceGo       = c.raceStarted != 0;                                                  // HAVE
        s.Finished     = c.finished != 0;                                                     // HAVE
        s.Failed       = s.InRace && (c.wrecked != 0 || c.eliminated != 0 || c.failReasons != 0);   // VERIFIED readings (timedOut LEAD, not read). Garbage outside a race, hence the InRace gate
        s.Paused       = false;  // TODO(step8): vars.IsPaused(s)                                          LEAD
        s.Loading      = vars.IsLoading(s);
        s.InMenu       = vars.InMenu(s);

        //--- derived: identity (only meaningful while FlowMachine == "Race"; the lambdas guard that)
        s.EventKind    = "Unknown"; // TODO(optional): vars.EventKind(s)   — Debug warning only
        s.EventId      = vars.EventId(s);
        s.MapId        = "";        // TODO(step6): vars.MapId(s)          PARTIAL
        s.StageIndex   = (fm == "Race") ? (int)c.activeStage : -1;
        s.StageCount   = (fm == "Race") ? (int)c.stageCount  : -1;
        s.IsLastStage  = vars.IsLastStage(s);

        //--- derived: timing
        s.LapIgt       = vars.LapIgt(s);
        s.EventIgt     = vars.EventIgt(s);
        s.FinishIgt    = vars.FinishIgt(s);                                                   // HAVE   -1 before the finish
        s.GateBonus    = (double)c.bonusTime;
        s.GatesHit     = vars.GatesHit(s);
        s.RaceStamp    = (double)c.raceStartTime;                                             // HAVE   identity of this race instance
        s.LapStamp     = (double)c.lapStartServerTime;                                        // HAVE

        // (campaign readings — playingPrologue / activeRun / campaignAct — are Debug leads only; no profile reads them. See group E above.)

        return s;
    });

    //=================================================================================================================================================================================================
    // 4. RUN STATE  — persists across ticks AND races. Written only by the bookkeeping lambdas below and the lifecycle blocks.
    //=================================================================================================================================================================================================
    vars.ResetRun = (Action)(() =>
    {
        dynamic r = new System.Dynamic.ExpandoObject();
        r.Profile             = null;    // set by vars.SelectProfile()
        r.Phase               = "Idle";  // Idle -> Running (onStart) -> Done (end condition split). Nothing finer: where the game is comes from Now.Flow.
        r.EventsDone          = 0;       // finishes booked in this run (log only)
        r.IgtTotal            = 0.0;     // sum of FinishIgt over completed races (the Game Time column for RTA categories)
        r.LastEventId         = "";      // identity of the race last entered
        r.LastMapId           = "";
        r.LastRaceStamp       = 0.0;     // RaceStamp of the race last booked by OnRaceEntered (so RaceEnteredEdge fires once per race)
        r.DeadRaceStamp       = 0.0;     // torn-down race's RaceStartTime        (BUGS.md #2)
        r.DeadLapStamp        = 0.0;     // torn-down race's LapStartServerTime   (BUGS.md #2)
        vars.Run = r;
    });
    vars.ResetRun();

    //--- Bookkeeping (called from update{} in this order; the only writers of vars.Run besides the lifecycle blocks)

    // Remember the torn-down race's timestamps, only from real non-zero readings (BUGS.md #2).   HAVE (v0.4.1 update{}, verbatim)
    // Runs on every teardown regardless of reset policy — Scenario transitions go through the same teardown.
    vars.CaptureDeadStamps = (Action<dynamic, dynamic>)((p, n) =>
    {
        if (p.playerLap >= 1 && n.playerLap == 0 && p.LapStamp != 0.0)  vars.Run.DeadLapStamp  = p.LapStamp;
        if (p.raceStarted == 1 && n.raceStarted == 0 && p.RaceStamp != 0.0) vars.Run.DeadRaceStamp = p.RaceStamp;
    });

    // On RaceEnteredEdge: book the race's identity (Debug / future use; nothing gates on it).
    vars.OnRaceEntered = (Action<dynamic, dynamic>)((p, n) =>
    {
        vars.Run.LastEventId   = n.EventId;
        vars.Run.LastMapId     = n.MapId;
        vars.Run.LastRaceStamp = n.RaceStamp;
        vars.Log("race entered: " + n.EventId + "  RaceStamp " + n.RaceStamp + "  laps " + n.totalLaps + "  flow " + n.Flow);
    });

    // On FinishEdge with a valid time: IgtTotal += FinishIgt ALWAYS (the IGT column is driving time, a redone race's time included — REFACTOR.md "Invariants").
    // No redo detection: EventId is not a race identity (the Nik Skandaro scenario's races share one), and a redone race is the runner's business.
    // Owns the IgtTotal add — gameTime{} returns Run.IgtTotal on the finish tick and must NOT add again. update{} runs before gameTime{}, so the order holds.
    vars.OnRaceFinished = (Action<dynamic, dynamic>)((p, n) =>
    {
        vars.Run.IgtTotal   += n.FinishIgt;
        vars.Run.EventsDone += 1;
        vars.Log("race finished: " + n.EventId + "  FinishIgt " + n.FinishIgt + "  IgtTotal " + vars.Run.IgtTotal
                 + "  EventsDone " + vars.Run.EventsDone + "  (stamp - RaceStamp " + (n.LapStamp - n.RaceStamp) + ", raw " + vars.RawFinishIgt(n) + ", gates " + n.GatesHit + ")");
    });

    //=================================================================================================================================================================================================
    // 5. PROFILES  (REFACTOR.md "Catalogue")
    // One record per category. Fields: Name, Family ("IL" | "Run"), RankedBy, Start(p,n), StartStamp ("Lap" | "Race" | "None": which dead stamp
    // guards the start, BUGS.md #2), IsEnd(p,n), SplitOnLap, SplitOnRace, ExpectedEventKind (Debug only).
    // Family decides the reset policy (IL: R1 if ResetOnLeave; Run: never) and isLoading{} (Run: Game Time frozen outside a live race).
    // S1..S4 / E1..E5 / R1..R4 are the catalogue numbers in REFACTOR.md.
    //=================================================================================================================================================================================================
    vars.MakeProfile = (Func<string, string, string, Func<dynamic, dynamic, bool>, string, Func<dynamic, dynamic, bool>, bool, bool, string, dynamic>)
        ((name, family, rankedBy, start, startStamp, isEnd, splitOnLap, splitOnRace, expectedKind) =>
    {
        dynamic pr = new System.Dynamic.ExpandoObject();
        pr.Name = name; pr.Family = family; pr.RankedBy = rankedBy; pr.Start = start; pr.StartStamp = startStamp; pr.IsEnd = isEnd;
        pr.SplitOnLap = splitOnLap; pr.SplitOnRace = splitOnRace; pr.ExpectedEventKind = expectedKind;
        return pr;
    });

    //--- Start states (S#) and end states (E#), each a (p, n) -> bool built from the edges above. Guards shared by all starts live in start{}.
    Func<dynamic, dynamic, bool> S1_FirstCrossing   = (p, n) => vars.FirstCrossingEdge(p, n);     // HAVE            Time Trial, Precision
    Func<dynamic, dynamic, bool> S2_GridGo          = (p, n) => vars.RaceGoEdge(p, n);            // HAVE            Scenarios (first race's go); podraces once revived
    Func<dynamic, dynamic, bool> S3_MenuLeave       = (p, n) => vars.MenuLeaveEdge(p, n);
    Func<dynamic, dynamic, bool> S4_ActIIIStartRun  = (p, n) => vars.ActIIIStartRunEdge(p, n);

    Func<dynamic, dynamic, bool> E0_Never           = (p, n) => false;                                                                      // Scenarios: no end condition; the runner's split count ends the run (LiveSplit stops at the last split)
    Func<dynamic, dynamic, bool> E1_SingleFinish    = (p, n) => vars.FinishEdge(p, n);                                                     // HAVE      all ILs
    // E3–E5 use ValidFinishEdge so a replayed finish (BUGS.md #6) can't end the run.
    Func<dynamic, dynamic, bool> E3_TheExperiment   = (p, n) => vars.ValidFinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_THE_EXPERIMENT);
    Func<dynamic, dynamic, bool> E4_SebulbaFinal    = (p, n) => vars.ValidFinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_SEBULBA_FINAL);    // name FIND — never fires until filled in
    Func<dynamic, dynamic, bool> E5_KestarFinal     = (p, n) => vars.ValidFinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_KESTAR_FINAL);     // name FIND — never fires until filled in

    //--- The table.                                                      Name                         Family RankedBy  Start               Stamp   IsEnd                 Lap    Race   ExpectedEventKind
    vars.Profiles = new Dictionary<string, dynamic>();
    vars.Profiles["Cat_TimeTrial"]    = vars.MakeProfile("Arcade — Time Trial",        "IL",  "IGT",    S1_FirstCrossing,   "Lap",  E1_SingleFinish,      true,  false, "TimeTrial");
    vars.Profiles["Cat_Precision"]    = vars.MakeProfile("Arcade — Precision Driving", "IL",  "IGT",    S1_FirstCrossing,   "Lap",  E1_SingleFinish,      true,  false, "Precision");
    // vars.Profiles["Cat_Podracing"]    = vars.MakeProfile("Arcade — Podrace",           "IL",  "IGT",    S2_GridGo,          "Race", E1_SingleFinish,      true,  false, "Podracing");
    vars.Profiles["Cat_Scenarios"]    = vars.MakeProfile("Arcade Scenarios",           "Run", "IGT",    S2_GridGo,          "Race", E0_Never,             true,  true,  "Scenario");
    vars.Profiles["Cat_ArcadePct"]    = vars.MakeProfile("Arcade%",                    "Run", "RTA",    S3_MenuLeave,       "None", E3_TheExperiment,     false, true,  "");
    vars.Profiles["Cat_SebulbaPct"]   = vars.MakeProfile("Sebulba%",                   "Run", "RTA",    S3_MenuLeave,       "None", E4_SebulbaFinal,      false, true,  "Campaign");
    vars.Profiles["Cat_AnyPct"]       = vars.MakeProfile("Any%",                       "Run", "RTA",    S3_MenuLeave,       "None", E5_KestarFinal,       false, true,  "Campaign");
    vars.Profiles["Cat_NGSebulbaPct"] = vars.MakeProfile("NG+ Sebulba%",               "Run", "RTA",    S3_MenuLeave,       "None", E4_SebulbaFinal,      false, true,  "Campaign");
    vars.Profiles["Cat_NGAnyPct"]     = vars.MakeProfile("NG+ Any%",                   "Run", "RTA",    S3_MenuLeave,       "None", E5_KestarFinal,       false, true,  "Campaign");
    vars.Profiles["Cat_NGChampion"]   = vars.MakeProfile("NG+ Champion%",              "Run", "RTA",    S3_MenuLeave,       "None", E5_KestarFinal,       false, true,  "Campaign");
    vars.Profiles["Cat_NGActIII"]     = vars.MakeProfile("NG+ Act III",                "Run", "RTA",    S4_ActIIIStartRun,  "None", E5_KestarFinal,       false, true,  "Campaign");

    // First ticked category wins. Returns true if the profile changed — this is the R4 edge (REFACTOR.md "Catalogue": reset run state, not the timer).
    vars.SelectProfile = (Func<bool>)(() =>
    {
        string chosen = null;
        foreach (string id in vars.CategoryIds) { if (settings[id]) { if (chosen == null) chosen = id; else vars.Log("WARNING: more than one category ticked; using " + chosen); } }
        if (chosen == null) chosen = "Cat_TimeTrial";
        dynamic next = vars.Profiles[chosen];
        if (vars.Run.Profile != null && vars.Run.Profile.Name == next.Name) return false;
        vars.ResetRun();
        vars.Run.Profile = next;
        vars.Log("profile: " + next.Name + " (" + next.Family + " family, ranked by " + next.RankedBy + ")");
        return true;
    });

    // Prime the snapshots so Prev is never null on the first tick.
    vars.Now  = vars.Snapshot(current);
    vars.Prev = vars.Now;
    vars.SelectProfile();
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// update{}: the ONLY place that touches `current`. Build the snapshot, run bookkeeping, print debug edges. Runs before every other block each tick.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
update
{
    vars.Prev = vars.Now;
    vars.Now  = vars.Snapshot(current);
    dynamic p = vars.Prev, n = vars.Now;

    vars.SelectProfile();                       // R4: category changed -> ResetRun (keeps the timer)

    // Bookkeeping, in this order (REFACTOR.md "Invariants").
    string phaseBefore = vars.Run.Phase;
    vars.CaptureDeadStamps(p, n);               // every teardown, regardless of family (BUGS.md #2 happens between Scenario races too)
    if (vars.RaceEnteredEdge(p, n)) vars.OnRaceEntered(p, n);
    if (vars.ValidFinishEdge(p, n)) vars.OnRaceFinished(p, n);   // every finish that counts
    else if (vars.FinishEdge(p, n)) vars.Log("finish ignored: finishTime " + n.FinishIgt + "  RaceStamp " + n.RaceStamp + "  InRace " + n.InRace
                                             + (n.RaceStamp == vars.Run.DeadRaceStamp ? "  == dead race (replay, BUGS.md #6)" : !n.InRace || n.RaceStamp <= 0 ? "  not a live race (replay, BUGS.md #6)" : ""));

    // Debug: print raw edges (port of v0.4.1 update{}) and derived edges.
    if (settings["Debug"])
    {
        if (vars.FlowEdge(p, n))            vars.Log("flow " + p.Flow + " -> " + n.Flow + (n.flowRecordCount > 1 ? "  WARNING: " + n.flowRecordCount + " active state machines" : ""));
        if (n.raceStarted != p.raceStarted) vars.Log("raceStarted " + p.raceStarted + " -> " + n.raceStarted + "  (RaceStamp " + n.RaceStamp + ")");
        if (n.playerLap   != p.playerLap)   vars.Log("playerLap "   + p.playerLap   + " -> " + n.playerLap + "  hudLap " + n.hudLap + "  totalLaps " + n.totalLaps
                                                     + "  LapStamp " + p.LapStamp + " -> " + n.LapStamp + "  (lap time " + (n.LapStamp - p.LapStamp) + ")");
        if (n.finished    != p.finished)    vars.Log("finished "    + p.finished    + " -> " + n.finished + "  finishTime " + n.finishTime + "  bonusTime " + n.bonusTime);
        if (n.HudVmPresent != p.HudVmPresent) vars.Log("hudVM " + (n.HudVmPresent ? "defined" : "undefined"));
        if (n.InRace != p.InRace)           vars.Log("InRace " + p.InRace + " -> " + n.InRace + "  (flow " + n.Flow + ", IsRaceGameState " + vars.IsRaceGameState(n) + ")");
        if (n.EventId != p.EventId)         vars.Log("EventId '" + p.EventId + "' -> '" + n.EventId + "'  stage " + n.StageIndex + "/" + n.StageCount);
        if (n.Failed && !p.Failed)          vars.Log("Failed: wrecked " + n.wrecked + "  eliminated " + n.eliminated + "  failReasons " + n.failReasons);
        if (vars.Run.Phase != phaseBefore)  vars.Log("phase " + phaseBefore + " -> " + vars.Run.Phase);
        // TODO(optional): EventKind vs Profile.ExpectedEventKind mismatch warning.
    }
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// isLoading{}: true freezes Game Time. With RunGameTime driving Game Time this is simply "not in a live race, or already finished" (REFACTOR.md "Invariants").
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
isLoading
{
    dynamic n = vars.Now, run = vars.Run;
    // IL (v0.4.1, verbatim): freeze after the finish so the value set in gameTime{} stays exact.
    // Run-length: also freeze whenever we are not in a LIVE race, so Game Time stops through menus, loads and the grid countdown (the IGT-sum
    //   column, and the whole Game Time for Scenarios). Live = in race and the clock has started: grid released (raceStarted, grid events) or
    //   first crossing (playerLap >= 1, rolling starts where bIsRaceStarted may never be set). Without the live check the countdown before
    //   each grid race would be timed, and the lap-edge re-sync in gameTime{} (0.5 s guard) could not take it back out.
    //   NOT applied to ILs on purpose: in Arcade the HUD VM can appear a tick after the start crossing, and a one-tick freeze there would be a behaviour change.
    bool loading = n.Finished;
    if (run.Profile != null && run.Profile.Family == "Run" && !(n.InRace && (n.raceStarted == 1 || n.playerLap >= 1))) loading = true;
    // TODO(step8): if (settings["PauseStopsTimer"] && n.Paused) loading = true;
    return loading;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// gameTime{}: Game Time = run IGT. Runs BEFORE split{} on a tick, so the finish split records the snapped value.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
gameTime
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;

    // Finish tick (v0.4.1): Game Time snaps to EventFinishTime — the difference of the game's LapStartServerTime stamps at the start and finish
    // crossings, so it matches the results screen and carries none of our polling latency (BUGS.md #1). OnRaceFinished (update{}) has already
    // added FinishIgt to Run.IgtTotal, so return the total: IgtTotal == FinishIgt for ILs, the run's IGT sum for run-length categories.
    if (vars.ValidFinishEdge(p, n))
    {
        vars.Log("finish: finishTime " + n.FinishIgt + "  stamp - RaceStamp " + (n.LapStamp - n.RaceStamp) + "  Game Time -> " + run.IgtTotal);
        return TimeSpan.FromSeconds(run.IgtTotal);
    }

    // Precision Driving ONLY (BUGS.md #7): Game Time IS the HUD's CurrentEventTime, every tick. The crossing stamps are raw but this value already
    // has the 1.5 s gate deductions taken off as each gate is passed, so lap splits, the live display and pauses all come out right for free.
    // (Tested 2026-10-22.) The shared v0.4.1 lap-edge block below is not reached.
    if (settings["Cat_Precision"])
    {
        return TimeSpan.FromSeconds(n.hudEventTime);
    }

    // Lap crossings (v0.4.1): the game stamps LapStartServerTime at the crossing, so stamp - RaceStartTime is the exact elapsed race time
    // (RaceStartTime = first-crossing stamp in Arcade, countdown end in grid events). Re-syncs the live Game Time and makes the lap split exact.
    // Only on a tick where the stamp actually moved, and only if within 0.5 s of the running Game Time (garbage guard).
    if (vars.LapEdge(p, n) && n.LapStamp != p.LapStamp)
    {
        double lapElapsed = run.IgtTotal + vars.LapSplitIgt(n);
        double running = timer.CurrentTime.GameTime.HasValue ? timer.CurrentTime.GameTime.Value.TotalSeconds : -1;
        vars.Log("lap edge: IgtTotal + (stamp - RaceStamp) " + lapElapsed + "  running Game Time " + running + "  correction " + (lapElapsed - running));
        if (vars.LapSplitIgt(n) > 0 && Math.Abs(lapElapsed - running) < 0.5)
            return TimeSpan.FromSeconds(lapElapsed);
    }

    // TODO(step8): live — return TimeSpan.FromSeconds(vars.RunGameTime(n)) every tick for the other categories too; hudEventTime is live and smooth
    // in Precision (above), so the same would remove the real-time jitter between crossings everywhere (BUGS.md #1).
    return null;   // real time between crossings (v0.4.1 behaviour)
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// start{}: profile's start edge + shared guards (REFACTOR.md "Catalogue", Starts).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
start
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;

    // Shared guards:
    //   - run.Phase == "Idle": a run in progress never re-starts. onReset puts Phase back to Idle; LiveSplit ignores start{} while the timer runs anyway.
    //   - vars.NewRaceInstance(p, n, StartStamp) for race-value starts (S1 "Lap", S2 "Race") — rejects the torn-down race's replayed memory (BUGS.md #2).
    //   - menu-leave starts ("None") fire outside a race and need no race-value guard. They are NOT checked against the event they lead to.
    if (run.Phase != "Idle") return false;
    if (!run.Profile.Start(p, n)) return false;
    if (!vars.NewRaceInstance(p, n, run.Profile.StartStamp))
    {
        vars.Log("start rejected: " + run.Profile.StartStamp + " stamp " + (run.Profile.StartStamp == "Lap" ? n.LapStamp : n.RaceStamp) + " is the torn-down race's");
        return false;
    }
    vars.Log("START (" + run.Profile.Name + ")  " + n.EventId + "  RaceStamp " + n.RaceStamp + "  LapStamp " + n.LapStamp + "  flow " + p.Flow + " -> " + n.Flow);
    return true;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// split{}: end condition first, then race splits, then lap splits (REFACTOR.md "Catalogue", Ends).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
split
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;
    if (!n.InRace) return false;   // v0.4.1 gate. The FinishEdge tick is still in-race for run-length categories too.

    // Run-length: once the end condition has fired, nothing else splits (a replayed or extra finish after the end must not advance the splits).
    if (run.Profile.Family == "Run" && run.Phase == "Done") return false;

    // E#: the run is over.
    if (run.Profile.IsEnd(p, n)) { run.Phase = "Done"; vars.Log("END (" + run.Profile.Name + ")  IgtTotal " + run.IgtTotal + "  EventsDone " + run.EventsDone); return settings["FinishSplit"]; }

    // Race / event split: every valid finish that isn't the end.
    if (run.Profile.SplitOnRace && vars.ValidFinishEdge(p, n)) return settings["RaceSplits"];

    // Lap split: lap k -> k+1 for 1 <= k < totalLaps (0 -> 1 is the start crossing; totalLaps -> totalLaps+1 is the finish, handled above).
    if (run.Profile.SplitOnLap && settings["LapSplits"] && vars.LapEdge(p, n)) return true;

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// reset{}: owned by the profile's Family (REFACTOR.md "Catalogue", Resets R1..R4).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
reset
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;

    if (run.Profile.Family == "IL")
    {
        if (!settings["ResetOnLeave"]) return false;
        if (p.HudVmPresent && !n.HudVmPresent)                      { vars.Log("RESET: HUD VM gone");                 return true; }   // player left the race
        if (p.raceStarted == 1 && n.raceStarted == 0)               { vars.Log("RESET: raceStarted 1 -> 0");          return true; }   // race restarted in place
        if (p.playerLap >= 1 && n.playerLap == 0 && !n.Finished)    { vars.Log("RESET: playerLap " + p.playerLap + " -> 0"); return true; }   // covers Arcade restarts, where bIsRaceStarted may never be set
        return false;
    }

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Lifecycle hooks: keep vars.Run in step with the LiveSplit timer.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
onStart
{
    // Fires for script starts AND manual starts. A fresh run: zero the totals, Phase = Running.
    dynamic run = vars.Run;
    run.IgtTotal = 0.0; run.EventsDone = 0;
    run.Phase = "Running";
    vars.Log("timer started  (" + (run.Profile != null ? run.Profile.Name : "no profile") + ")  flow " + vars.Now.Flow);
}

onReset
{
    // Timer reset by the script or the runner: clear run state but keep the profile and the dead-race stamps (they belong to memory, not the run).
    dynamic keep = vars.Run.Profile;
    double deadRace = vars.Run.DeadRaceStamp, deadLap = vars.Run.DeadLapStamp, lastRace = vars.Run.LastRaceStamp;
    vars.ResetRun();
    vars.Run.Profile = keep; vars.Run.DeadRaceStamp = deadRace; vars.Run.DeadLapStamp = deadLap; vars.Run.LastRaceStamp = lastRace;
    vars.Log("timer reset  (phase Idle; dead stamps kept: race " + deadRace + ", lap " + deadLap + ")");
}
