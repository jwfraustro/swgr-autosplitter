//=====================================================================================================================================================================================================
// Star Wars: Galactic Racer — LiveSplit autosplitter (refactor)
// Version: 0.5.0-skeleton  — NOT FUNCTIONAL. Bones only. Will replace SWGR_Autosplitter.asl (v0.4.1) when finished.
//
// READ FIRST
//   REFACTOR.md   — the plan this file implements. Section names below match it. "Step N" = its Migration order.
//   DEV_NOTES.md  — where every memory value comes from and how it was verified. Offsets are for the current
//                   Steam build (GWorld = exe+0xADFF928) and WILL break on game patches.
//   BUGS.md       — #1 polling jitter / exact Game Time, #2 false starts from torn-down race memory.
//   SWGR_Autosplitter.asl — the working v0.4.1 script. Port behaviour from there, don't reinvent it.
//
// LAYOUT (REFACTOR.md "Shape of the refactored script")
//   1. Readings      state{}            raw memory values, grouped by owning object. No logic.
//   2. Snapshot      init{} + update{}  vars.Snapshot(current) -> vars.Now / vars.Prev, every derived value computed once per tick.
//   3. Predicates    init{}             vars.* lambdas: gates, edges, timing, identity. Pure functions of a snapshot or (prev, now).
//   4. Run state     init{}             vars.Run: persists across ticks AND races (phase, IGT total, dead-race stamps, ...).
//   5. Profiles      init{}             vars.Profiles[category]: which start edge / end condition / split / reset policy applies.
//   Action blocks (start/split/reset/gameTime/isLoading) only read vars.Prev / vars.Now / vars.Run / vars.Run.Profile — never current/old.
//
// MARKERS used in comments
//   HAVE      exists in v0.4.1; port it.                 VERIFIED  address/behaviour confirmed live, not used by v0.4.1 yet.
//   LEAD      candidate offset from the dump, unverified. FIND      no candidate yet; see DEV_NOTES.md "Memory to find" (M1..M11).
//   PARTIAL   resolves live, but only in some event types; the comment says which.
//   TODO(stepN)  what to fill in, and at which REFACTOR.md migration step.
//
// ASL facts to remember (REFACTOR.md): a reading whose chain fails reads as 0/default, not an error; gameTime{} runs before
// split{}; isLoading{} == true freezes Game Time; settings are checkboxes (no radio buttons); no classes — use ExpandoObject.
//=====================================================================================================================================================================================================


//=====================================================================================================================================================================================================
// 1. READINGS  (REFACTOR.md "Variables > Raw readings")
// One line per value. Commented-out lines are LEAD / FIND / PARTIAL entries: uncomment once the chain is verified in DEV_NOTES.md.
// Patch handling (later): add further state("SWGR-Win64-Shipping", "<build>") blocks and set `version` in init{}.
// Cheat Engine mirror: cheat_engine_resources/SWGR_Refactor.CT, built by make_refactor_ct.py (hand-transcribed — update it when a chain here changes).
//=====================================================================================================================================================================================================
state("SWGR-Win64-Shipping")
{
    //--- A0. Flow state machine  (GameState -> AActor.BlueprintCreatedComponents[0] = UGameFlowStateMachineComponent: exe, 0xADFF928, 0x1B0, 0x298, 0x0).
    //    EVERY GameState carries it: USimpleRaceStateMachine in a race, UFrontEndStateMachine in the menus, UPaddockStateMachine in the campaign hub.
    //    flowState alone is ambiguous (Paddock Leaving 5 == race Racing 5): always pair it with flowEnumCount, which identifies the machine.
    //    Chain reads 0 through a level load (GameState destroyed) — that is the "None" machine, and it is expected, not an error.
    int    flowState        : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x298, 0x0, 0xC0, 0x10;        // VERIFIED  ActiveStateMachines[0].CurrentStateId — id in the machine's own enum (DEV_NOTES "Race flow state machine")
    int    flowEnumCount    : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x298, 0x0, 0xC0, 0x8, 0x50;   // VERIFIED  ActiveStateMachines[0].StateMachineStateIdEnum->Names.Num: 37 race, 16 front end, 9 paddock, 4 paddock narrative, >=14 pvp, 0 = loading
    int    flowRecordCount  : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x298, 0x0, 0xC8;              // VERIFIED (field)  ActiveStateMachines.Num — expect 1; Debug warning if ever 2 (record 0 may then be the wrong machine)
    // byte   primaryFlow      : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x398;                         // LEAD  UGfnGameInstance.PrimaryFlow (EGfnPrimaryFlow): Campaign 1, QuickRace 2, Arcade 3, Multiplayer 4 — per-profile sanity gate

    //--- A. ARacingGameState  (GWorld -> GameState: exe, 0xADFF928, 0x1B0). Only an ARacingGameState while FlowMachine == "Race"; garbage otherwise.
    byte   raceStarted      : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x388;   // HAVE  bIsRaceStarted: 0 -> 1 when the grid is released (countdown over)
    int    totalLaps        : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x370;   // HAVE  LapCount: laps in this event. Elimination (campaign) events read 100 = "until top 3 remain"
    double raceStartTime    : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x378;   // HAVE  RaceStartTime (server time): base for lap-split IGT; dead-race guard
    byte   raceFinished     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x389;   // VERIFIED  bIsRaceFinished: player-based (local player's finish), not all racers
    double countdownEndTime : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x368;   // VERIFIED  CountdownEndTime: server-time stamp on the RaceStartTime clock (e.g. 1670.018), not a 3.0 s countdown
    int    activeStage      : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x408;   // VERIFIED  EventRecipeState.ActiveStage: 0-indexed stage in the recipe (M9)
    int    stageCount       : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x400;   // VERIFIED  EventRecipe.EventStages.Num (TArray count = data ptr + 0x8) (M9)

    //--- B. URaceEventVM  (HUD view model: GameState + 0x3D8). Pointer is 0 / chain breaks once the player leaves the race.
    long   hudVM            : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8;          // HAVE  presence == HUD exists
    int    hudLap           : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x16C;   // HAVE  CurrentLapNumber as shown on HUD: starts at 1
    double hudLapTime       : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x178;   // VERIFIED  CurrentLapTime: raw lap IGT, resets each lap, no Precision deductions
    double hudEventTime     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x188;   // VERIFIED  CurrentEventTime: running event IGT with Precision gate deductions applied
    int    hudNumLaps       : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x140;   // VERIFIED  NumLaps: matches totalLaps; 100 in Elimination events (hidden on the HUD)
    byte   hudModeType      : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x0D8;   // VERIFIED  ERaceEventModeType: TimeTrial 2 seen live; PrecisionDriving 8 (dump)
    byte   hudSuccess       : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x1D4;   // VERIFIED  bIsSuccess — finish outcome
    // long   trackNamePtr     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x28, 0x50;        // PARTIAL  track -> InternalName: OK for Time Trial / Podracing, bad ptr in Precision; campaign = map only ("DAL_SHORT_06"). Use stageName instead
    int    trackNameLen     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3D8, 0x28, 0x58;        // VERIFIED  FString length (int32 at +0x8)

    //--- C. UPlayerRaceEventComponent  (GWorld -> OwningGameInstance -> LocalPlayers[0] -> PlayerController -> PlayerState -> RaceEventComponent)
    int    playerLap          : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD4; // HAVE  CurrentLapNumber: 0 until first crossing; LapCount+1 after the finish; 0 after leaving
    byte   finished           : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCC; // HAVE  bHasFinishedEvent: 0 -> 1 on the final crossing. End trigger for EVERY category
    float  finishTime         : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF0; // HAVE  EventFinishTime: -1 until the finish, then the results-screen time (Precision: already adjusted)
    float  bonusTime          : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF4; // VERIFIED  BonusTime: running total of Precision gate deductions, +1.5 per gate
    double lapStartServerTime : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xE8; // HAVE  LapStartServerTime: stamp at each crossing; dead-race guard
    int    eventPosition      : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xC4;  // VERIFIED  EventPosition — campaign "must win"?
    byte   failReasons        : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0x120; // VERIFIED  ERaceFailReason bitflags: Wrecked 1, ModeRules 2, HighRisk 4, ExtraConditions 8, MissedRequiredWin 16
    // byte   timedOut           : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCD;  // LEAD  bHasTimedOut
    byte   wrecked            : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCF;  // VERIFIED  bHasVehicleWrecked: 1 = wrecked out of the race for good (not a respawnable crash)
    byte   eliminated         : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD0;  // VERIFIED  bHasBeenEliminated
    float  bestLapTime        : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF8;  // VERIFIED  BestLapTime — display only
    float  prevLapTime        : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xFC;  // VERIFIED  PreviousLapTime — display only

    //--- D. Event identity  (GameState + 0x3F8 EventRecipe.EventStages -> FRaceEventInstance[ActiveStage]).
    //    EventStages is TArray<FRaceEventInstance>: elements are INLINE (0x308 bytes each), so there is NO deref after the data ptr.
    //    Stage 0 shown (single-race events). Stage N = data ptr + N * 0x308; state{} can't index, so read it in update{} if Scenarios need it.
    long      stageNamePtr  : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x10;          // VERIFIED  FRaceEventInstance.InternalName FString data ptr
    string128 stageName     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x10, 0x0;     // VERIFIED  InternalName text (UTF-16). Arcade "EVT_ARC_PRE_BIKE_MAS_A_FWD"; campaign "DAL_SHORT_06_TeamRace_Dry". EventId (M6 / M7)
    int    stageNameLen     : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x18;        // VERIFIED  FString length
    long   authoredEvent    : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x58;        // VERIFIED  URaceEventDef* — class check (UArcadeEventDef vs campaign def)
    byte      arcadeCategory: "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x58, 0x321;   // VERIFIED  EArcadeEventCategories: Plane 2 (Podracing) seen live, Precision 4. Undefined in campaign (def isn't an arcade def)
    byte      skipCountdown : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x58, 0xB8;    // VERIFIED  (arcade)  URaceEventDef.bShouldSkipCountdown — rolling vs grid start. Undefined in campaign
    byte      stageLapCount : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x3F8, 0x30;          // VERIFIED  FRaceEventInstance.LapCount — matches totalLaps (100 in Elimination)

    //--- E. Campaign  (UCampaignSubsystem — GameInstance subsystem. Chain TBD: UGfnGameInstance::GetCampaignManager(); see DEV_NOTES "UCampaignSubsystem")
    // byte   playingPrologue    : ???, 0xC1;   // VERIFIED (field) / FIND (chain)  bIsPlayingPrologue: 0 -> 1 on "Start New Campaign" AND on reset "Accept" (M1, M2)
    // long   activeRun          : ???, 0xC8;   // VERIFIED (field) / FIND (chain)  ActiveRun: null -> UCampaignRun* on the Act III loadout "Continue" (M3). Check it doesn't flip elsewhere.
    // int    campaignAct        : ???, 0xE0, 0x28;   // LEAD  MetaProgression -> MainCampaignCurrentTourIx (Tour = Act). Act III index value TBC (0- or 1-based)
    // long   campaignDifficulty : ???, 0xE0, 0x110;  // LEAD  MetaProgression -> LastPickedDifficulty (UCampaignDifficultyDef*). Champion% warning only (M10)
    // byte   continueRunState   : ???;               // LEAD  EContinueRunState: Paddock 0 ... StartEvent 4, PostEvent 5, LeavePlanet 6 — between-race phases (M11)

    //--- F. Front end / menus.  "Start Event" / scenario start (M4, M5) are now flow edges (A0: leaving FrontEnd.PrimaryModeSelect); the selected event is read
    //    from stageName once the race loads. Only the medal result is still a hunt.
    // byte   medalResult         : ???;   // FIND  Bronze beaten on the finished event (M8). Fallback: finishTime vs the event def's Bronze time

    //--- G. Engine / misc
    // long   pauserPlayerState : "SWGR-Win64-Shipping.exe", 0xADFF928, ???, ???, ???;   // LEAD  AWorldSettings.PauserPlayerState via UWorld -> PersistentLevel -> WorldSettings. Non-null while paused (UE standard)
    // double worldTime         : "SWGR-Win64-Shipping.exe", 0xADFF928, 0x1B0, 0x2E0;   // VERIFIED-BAD  ReplicatedWorldTimeSecondsDouble LAGS the crossing stamps — not a live clock (BUGS.md #1). Do not use.
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// startup{}: settings tree (REFACTOR.md "Variables > Settings") and constants. Runs once when the script loads.
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
    settings.Add("Cat_Podracing",    false, "Tales of Podracing",         "Category");
        settings.SetToolTip("Cat_Podracing",    "Single podracer race (grid start). Starts when the countdown ends; ends on the final-lap finish.");
    settings.Add("Cat_Scenarios",    false, "Arcade Scenarios",           "Category");
        settings.SetToolTip("Cat_Scenarios",    "5 races in sequence. RTA. Starts on the scenario start (TBD); splits per race; ends on the 5th race's finish. Does not reset between races.");
    settings.Add("Cat_ArcadePct",    false, "Arcade%",                    "Category");
        settings.SetToolTip("Cat_ArcadePct",    "All 50 events in order. RTA. Starts on 'Start Event' for Landspeeder Ace; splits per event (retries don't split); ends on The Experiment with Bronze beaten.");
    settings.Add("Cat_SebulbaPct",   false, "Sebulba%",                   "Category");
        settings.SetToolTip("Cat_SebulbaPct",   "Fresh save. RTA. Starts on 'Start New Campaign'; splits per race; ends on the final-lap finish vs Sebulba (last race of Act I).");
    settings.Add("Cat_AnyPct",       false, "Any%",                       "Category");
        settings.SetToolTip("Cat_AnyPct",       "Fresh save. RTA. Starts on 'Start New Campaign'; splits per race; ends on the final-lap finish vs Kestar's Podracer (last race of Act III).");
    settings.Add("Cat_NGSebulbaPct", false, "NG+ Sebulba%",               "Category");
        settings.SetToolTip("Cat_NGSebulbaPct", "RTA. Starts on the campaign-reset 'Accept'; ends vs Sebulba.");
    settings.Add("Cat_NGAnyPct",     false, "NG+ Any%",                   "Category");
        settings.SetToolTip("Cat_NGAnyPct",     "RTA. Starts on the campaign-reset 'Accept'; ends vs Kestar's Podracer.");
    settings.Add("Cat_NGChampion",   false, "NG+ Champion%",              "Category");
        settings.SetToolTip("Cat_NGChampion",   "As NG+ Any% on Champion difficulty. (Difficulty check is a Debug warning only, if ever added.)");
    settings.Add("Cat_NGActIII",     false, "NG+ Act III",                "Category");
        settings.SetToolTip("Cat_NGActIII",     "RTA. Starts on 'Continue' at the Act III loadout check; ends vs Kestar's Podracer.");

    //--- Splits
    settings.Add("LapSplits",   true,  "Split on each lap");
        settings.SetToolTip("LapSplits",   "Splits on every completed lap except the last (the finish / race split covers that).");
    settings.Add("RaceSplits",  true,  "Split on each race / event (multi-race categories)");
        settings.SetToolTip("RaceSplits",  "Splits when a race or event finishes and the run is not over. Failed or retried events do not split.");
    settings.Add("FinishSplit", true,  "Split on the run's final finish");
        settings.SetToolTip("FinishSplit", "Splits when the category's end condition is met.");

    //--- Reset
    settings.Add("ResetOnLeave", true, "Reset on restart / leaving the race (single-race categories only)");
        settings.SetToolTip("ResetOnLeave", "Single-race categories: reset when the race is restarted or quit before the finish. Multi-race categories ignore this between races.");

    //--- Timing
    settings.Add("PauseStopsTimer", false, "Pausing stops Game Time (not implemented)");
        settings.SetToolTip("PauseStopsTimer", "Needs the pause flag (REFACTOR.md: pauserPlayerState LEAD). Does nothing yet.");
    settings.Add("MenuStartTrust", false, "Menu-press starts: start the timer on the press (trust, reset if the game goes elsewhere)");
        settings.SetToolTip("MenuStartTrust", "Arcade% / Scenarios start from a menu press that leads into a level load. Off (default): the timer appears once the race confirms the expected event, backdated to the press. On: the timer starts the instant the menu is left, and resets if the game lands somewhere else. Same recorded time either way. REFACTOR.md 'Start States' latch-and-confirm.");

    //--- Debug
    settings.Add("Debug", false, "Debug output");
        settings.SetToolTip("Debug", "Prints every derived edge and profile decision to the debug log (DbgView).");

    // Category setting ids in display order. First ticked one wins (see vars.SelectProfile).
    vars.CategoryIds = new List<string> {
        "Cat_TimeTrial", "Cat_Precision", "Cat_Podracing", "Cat_Scenarios", "Cat_ArcadePct",
        "Cat_SebulbaPct", "Cat_AnyPct", "Cat_NGSebulbaPct", "Cat_NGAnyPct", "Cat_NGChampion", "Cat_NGActIII"
    };

    // Constants. Fill in as identities are found (DEV_NOTES M6 / M7). Compare against vars.EventId(now).
    vars.EVENT_LANDSPEEDER_ACE = "";   // FIND  FRaceEventInstance.InternalName of Landspeeder Ace (Arcade% start, S5)
    vars.EVENT_THE_EXPERIMENT  = "";   // FIND  ... of The Experiment (Arcade% end, E3)
    vars.EVENT_SEBULBA_FINAL   = "";   // FIND  ... of the Sebulba race, last race of Act I (E4)
    vars.EVENT_KESTAR_FINAL    = "";   // FIND  ... of the Kestar's Podracer race, last race of Act III (E5)
    vars.ACT_I   = 0;                  // LEAD  MainCampaignCurrentTourIx values; 0- or 1-based TBC
    vars.ACT_III = 2;                  // LEAD
    vars.PRECISION_GATE_SECONDS = 1.5; // VERIFIED
    vars.SCENARIO_RACE_COUNT    = 5;   // rules

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
    // 3. PREDICATES AND EDGES  (REFACTOR.md "Functions")
    // Conventions: `s` is a snapshot (vars.Now or vars.Prev); `(p, n)` is (vars.Prev, vars.Now). Pure: no side effects, no vars.Run writes.
    // Each stub states: the question it answers, the definition from REFACTOR.md, its status, and which step fills it in.
    //=================================================================================================================================================================================================

    //--- 3a. Gates ("where are we?")

    // Does GameState look like an ARacingGameState? (same offsets read garbage from the menu GameState)
    // Definition: s.FlowMachine == "Race" (&& LapsSane as belt-and-braces; v0.4.1 had only LapsSane).   VERIFIED readings   TODO(step2)
    vars.IsRaceGameState = (Func<dynamic, bool>)((s) => false);

    // Is the local player in a live race?  Definition: HudVmPresent && LapsSane — UNCHANGED from v0.4.1; the ILs must not change behaviour.
    // Flow in Race.{Countdown, Racing, RollingStart} is a Debug cross-check, not a replacement.    HAVE (v0.4.1 vars.InRace)     TODO(step1)
    vars.InRace = (Func<dynamic, bool>)((s) => false);

    // ...and do the lap counters agree?  Definition: InRace && LapsInSync (hudLap == playerLap + 1). Only stable away from a crossing.
    //                                                                                             HAVE (v0.4.1 InRace + LapsInSync)   TODO(step1)
    vars.InRaceStrict = (Func<dynamic, bool>)((s) => false);

    // Is the game paused?  Definition: pauserPlayerState != 0.                                   LEAD (reading commented out)   TODO(step8)
    vars.IsPaused = (Func<dynamic, bool>)((s) => false);

    // Between levels / race not live?  Definition: FlowMachine == "None" (chain broken: GameState destroyed) || Race in {LOADING 1, WAIT_LEVEL 10, WAIT_CLIENTS 11}.
    //                                                                                             VERIFIED readings             TODO(step5)
    vars.IsLoading = (Func<dynamic, bool>)((s) => false);

    // In a menu (front end or paddock), not a race, not a load?  Definition: FlowMachine in {"FrontEnd", "Paddock"}.   VERIFIED readings   TODO(step5)
    vars.InMenu = (Func<dynamic, bool>)((s) => false);

    // Did the race we were in just go away (restart / quit / between races)?
    // Definition: p.FlowMachine == "Race" && (n.FlowMachine != "Race" || n.FlowState in {PREPARE_TO_LEAVE 30, LEAVING 8});
    // fallback (v0.4.1): p.InRace && !n.InRace, or p.playerLap >= 1 && n.playerLap == 0.         HAVE (v0.4.1 reset conditions) + VERIFIED flow   TODO(step1 fallback, step2 flow)
    vars.IsTearingDown = (Func<dynamic, dynamic, bool>)((p, n) => false);

    //--- 3b. Edges ("what just happened?")  — all (p, n). Start edges must also pass vars.NewRaceInstance.

    // Grid released: raceStarted 0 -> 1, InRaceStrict(n), fresh RaceStamp.                       HAVE (v0.4.1 "Race" start)     TODO(step2)
    vars.RaceGoEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // First start-line crossing (rolling start): playerLap 0 -> 1, !Finished, LapsSane, fresh LapStamp.
    // Deliberately NOT gated on the HUD VM (DEV_NOTES "v0.1.0 field testing"): the VM can appear on/after the crossing tick.
    //                                                                                             HAVE (v0.4.1 "Arcade" start)   TODO(step2)
    vars.FirstCrossingEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Lap completed: playerLap k -> k+1 with 1 <= k < totalLaps, !Finished.                       HAVE (v0.4.1 split)            TODO(step2)
    vars.LapEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Player crossed the final line: finished 0 -> 1.                                             HAVE (v0.4.1 split/gameTime)   TODO(step2)
    vars.FinishEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Player failed the event: Failed false -> true (timed out / wrecked / eliminated / failReasons).   LEAD   TODO(step5)
    vars.FailEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Entered a (new) race: !p.InRace && n.InRace with a RaceStamp we haven't seen.               —    TODO(step3)
    vars.RaceEnteredEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Is this a real new race and not the torn-down race's memory replaying (BUGS.md #2)?
    // Definition: n.RaceStamp != Run.DeadRaceStamp && n.LapStamp != Run.DeadLapStamp.             HAVE (v0.4.1 inline in start)   TODO(step1)
    vars.NewRaceInstance = (Func<dynamic, dynamic, bool>)((p, n) => false);

    //--- Flow edges (A0). Implemented: they are pure string compares on the snapshot and are needed in step 1 to record the state sequences.
    // Any flow transition, including into/out of "None" (level load).
    vars.FlowEdge  = (Func<dynamic, dynamic, bool>)((p, n) => p.Flow != n.Flow);
    // Entered machine.state this tick.   e.g. vars.FlowEnter(p, n, "Paddock", vars.PAD_INWORLD)
    vars.FlowEnter = (Func<dynamic, dynamic, string, int, bool>)((p, n, machine, state) => p.Flow != n.Flow && n.FlowMachine == machine && n.FlowState == state);
    // Left machine.state this tick (to anything, including "None").
    vars.FlowLeave = (Func<dynamic, dynamic, string, int, bool>)((p, n, machine, state) => p.Flow != n.Flow && p.FlowMachine == machine && p.FlowState == state);

    // New campaign / campaign reset confirmed: playingPrologue 0 -> 1 (covers M1 and M2; profile decides which).
    // Flow cross-check for a new campaign: FlowLeave(FrontEnd, PRIMARY_MODE_SELECT) -> FrontEnd.LAUNCHING_CAMPAIGN; the reset-Accept sequence is not recorded yet.
    //                                                                                             VERIFIED field, chain TBD   TODO(step6)
    vars.PrologueEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Act III "Start Run" -> loadout -> Continue: FlowEnter(Paddock, INWORLD 4) from Paddock.{CAMPAIGN_SETUP 2, PREWORLD 3} && CampaignAct == ACT_III.
    // Same machine, no level load: a clean single-tick edge. activeRun 0 -> non-zero confirms a run START rather than a resume.
    //                                                                                             VERIFIED flow; Act index + activeRun chain TBD   TODO(step6)
    vars.ActIIIStartRunEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Menu departure = the "Start Event" / scenario start press, within one poll: FlowLeave(FrontEnd, PRIMARY_MODE_SELECT 1).
    // ARMS the run (Run.ArmedAt / ArmedFrom, Phase = "Armed"); does not start by itself unless settings["MenuStartTrust"].
    // Exact sequence after the press TBC (straight to "None", or via FrontEnd.LAUNCHING_QUICKRACE 4 first?) — record it with the Debug flow log.
    //                                                                                             VERIFIED readings, sequence TBC   TODO(step5)
    vars.MenuDepartureEdge = (Func<dynamic, dynamic, bool>)((p, n) => false);

    // Arrival confirmed: Run.Phase == "Armed" && FlowEnter(Race, *) && vars.IsEvent(n, eventId). Under the backdated policy this is the start tick,
    // with timer.Run.Offset = -(DateTime.Now - Run.ArmedAt). stageName is populated with the GameState, so EventId is readable from Race.LOADING on.
    //                                                                                             VERIFIED readings   TODO(step5)
    vars.ArrivalConfirmEdge = (Func<dynamic, dynamic, string, bool>)((p, n, eventId) => false);

    // Arrival wrong: Run.Phase == "Armed" && (FlowEnter(FrontEnd, *) || (n.FlowMachine == "Race" && n.EventId != "" && n.EventId != expected)).
    // Backdated policy: drop the arm (Phase = "Idle"). Trust policy: reset (R7).                 VERIFIED readings   TODO(step5)
    vars.ArrivalWrongEdge = (Func<dynamic, dynamic, string, bool>)((p, n, eventId) => false);

    //--- 3c. Timing ("what time is it?")  — all (s) -> double, in seconds.

    // Running event IGT (Precision-adjusted): hudEventTime.                                        VERIFIED   TODO(step3; step8 for live use)
    vars.EventIgt = (Func<dynamic, double>)((s) => 0.0);

    // Running raw lap time: hudLapTime.                                                           VERIFIED   TODO(step3) (display/debug)
    vars.LapIgt = (Func<dynamic, double>)((s) => 0.0);

    // Exact elapsed race time at the last crossing: LapStamp - RaceStamp.                         HAVE (v0.4.1 gameTime lap edge)   TODO(step2)
    vars.LapSplitIgt = (Func<dynamic, double>)((s) => 0.0);

    // Final adjusted time: finishTime (-1 before the finish).                                     HAVE (v0.4.1 gameTime finish)     TODO(step2)
    vars.FinishIgt = (Func<dynamic, double>)((s) => -1.0);

    // Final unadjusted time: finishTime + bonusTime.                                              VERIFIED   TODO(step3) (Precision display)
    vars.RawFinishIgt = (Func<dynamic, double>)((s) => -1.0);

    // Precision gates driven through: round(bonusTime / PRECISION_GATE_SECONDS).                  VERIFIED   TODO(step3) (display)
    vars.GatesHit = (Func<dynamic, int>)((s) => 0);

    // Game Time for the whole run: Run.IgtTotal + (InRace ? EventIgt : 0); snaps to IgtTotal + FinishIgt on the FinishEdge.
    // Covers ILs (IgtTotal = 0) and multi-race runs with one formula. See REFACTOR.md note on live use vs real-time + re-sync.   TODO(step3)
    vars.RunGameTime = (Func<dynamic, double>)((s) => 0.0);

    //--- 3d. Identity ("which race / event is this?")

    // Track / map name: FString at HUD VM -> track -> InternalName (UTF-16). Bad ptr in Precision; campaign gives only the map ("DAL_SHORT_06").
    // Prefer deriving the map from EventId's prefix where needed.                                  PARTIAL   TODO(step6)
    vars.MapId = (Func<dynamic, string>)((s) => "");

    // Stable event name: stageName = EventStages[ActiveStage].InternalName. Arcade "EVT_ARC_<mode>_<vehicle>_<track>_<variant>"
    // (e.g. EVT_ARC_PRE_BIKE_MAS_A_FWD = arcade precision, bike, Mastiff); campaign "<MAP>_<race type>_<condition>"
    // (e.g. DAL_SHORT_06_TeamRace_Dry). Works in every mode seen so far.                          VERIFIED (M6 / M7)   TODO(step6)
    vars.EventId = (Func<dynamic, string>)((s) => "");

    // Is this the named event?  Definition: EventId(s) == name.                                   LEAD   TODO(step6)
    vars.IsEvent = (Func<dynamic, string, bool>)((s, name) => false);

    // TimeTrial / Precision / Podracing / Scenario / Campaign / Unknown. OPTIONAL — Debug mismatch warning only, never selects behaviour.
    // Definition: arcadeCategory if authoredEvent is an arcade def (Plane 2 -> Podracing, Precision 4 -> Precision, else TimeTrial);
    // Campaign if CampaignRunActive; Scenario if stageCount > 1 and not campaign.                 VERIFIED readings (arcadeCategory garbage in campaign: check campaign FIRST)   TODO(optional)
    vars.EventKind = (Func<dynamic, string>)((s) => "Unknown");

    // Last race of a multi-stage recipe?  Definition: StageIndex == StageCount - 1 (ActiveStage is 0-indexed).   VERIFIED readings (M9)   TODO(step7)
    vars.IsLastStage = (Func<dynamic, bool>)((s) => false);

    // Did the finish beat the medal tier?  Definition: medalResult, or FinishIgt <= the event def's tier time.   FIND (M8)   TODO(step7)
    vars.MedalBeaten = (Func<dynamic, string, bool>)((s, tier) => false);

    // Current campaign Act index: campaignAct.                                                    LEAD   TODO(step6)
    vars.CampaignAct = (Func<dynamic, int>)((s) => -1);

    //=================================================================================================================================================================================================
    // 2. SNAPSHOT  (REFACTOR.md "Variables > Derived, per tick")
    // vars.Snapshot(current) builds an ExpandoObject with raw copies + every derived value, computed ONCE per tick in update{}.
    // Action blocks read vars.Now / vars.Prev only. Add a property here whenever a reading or predicate is added above.
    //=================================================================================================================================================================================================
    vars.Snapshot = (Func<dynamic, dynamic>)((c) =>
    {
        dynamic s = new System.Dynamic.ExpandoObject();

        //--- raw copies (so predicates never need `current`)
        s.flowState          = c.flowState;             // VERIFIED  (A0)
        s.flowEnumCount      = c.flowEnumCount;         // VERIFIED  (A0)
        s.flowRecordCount    = c.flowRecordCount;       // VERIFIED field (A0)
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
        s.raceFinished       = c.raceFinished;          // VERIFIED  player-based
        s.countdownEndTime   = c.countdownEndTime;      // VERIFIED
        s.activeStage        = c.activeStage;           // VERIFIED (M9)
        s.stageCount         = c.stageCount;            // VERIFIED (M9)
        s.hudNumLaps         = c.hudNumLaps;            // VERIFIED
        s.hudModeType        = c.hudModeType;           // VERIFIED
        s.hudSuccess         = c.hudSuccess;            // VERIFIED
        s.eventPosition      = c.eventPosition;         // VERIFIED
        s.failReasons        = c.failReasons;           // VERIFIED
        s.wrecked            = c.wrecked;               // VERIFIED
        s.bestLapTime        = c.bestLapTime;           // VERIFIED
        s.prevLapTime        = c.prevLapTime;           // VERIFIED
        s.stageName          = c.stageName;             // VERIFIED  stage 0 only (see state{} D)
        s.arcadeCategory     = c.arcadeCategory;        // VERIFIED  arcade only; garbage in campaign
        s.skipCountdown      = c.skipCountdown;         // VERIFIED  arcade only; garbage in campaign
        s.stageLapCount      = c.stageLapCount;         // VERIFIED
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

        //--- derived: presence / sanity                                                         status      step
        s.HudVmPresent = c.hudVM != 0;                                                        // HAVE        step1
        s.LapsSane     = false;  // TODO(step1): totalLaps in (0, 100] && 0 <= playerLap <= totalLaps + 1   (v0.4.1 vars.LapsSane)
        s.LapsInSync   = false;  // TODO(step1): hudLap == playerLap + 1                                   (v0.4.1 vars.LapsInSync)
        s.InRace       = false;  // TODO(step1): vars.InRace(s)      — set AFTER LapsSane / HudVmPresent
        s.RaceGo       = c.raceStarted != 0;                                                  // HAVE        step1
        s.Finished     = c.finished != 0;                                                     // HAVE        step1
        s.Failed       = false;  // TODO(step5): timedOut || wrecked || eliminated || failReasons != 0     wrecked/failReasons VERIFIED; timedOut/eliminated LEAD
        s.Paused       = false;  // TODO(step8): vars.IsPaused(s)                                          LEAD
        s.Loading      = false;  // TODO(step5): vars.IsLoading(s)   — FlowMachine == "None" || Race in {1, 10, 11}   VERIFIED readings
        s.InMenu       = false;  // TODO(step5): vars.InMenu(s)      — FlowMachine in {"FrontEnd", "Paddock"}         VERIFIED readings

        //--- derived: identity
        s.EventKind    = "Unknown"; // TODO(optional): vars.EventKind(s)   — Debug warning only
        s.EventId      = "";        // TODO(step6): vars.EventId(s)        VERIFIED chain (M6 / M7)
        s.MapId        = "";        // TODO(step6): vars.MapId(s)          PARTIAL
        s.StageIndex   = -1;        // TODO(step7): activeStage            VERIFIED (M9)
        s.StageCount   = -1;        // TODO(step7): stageCount             VERIFIED (M9)
        s.IsLastStage  = false;     // TODO(step7): vars.IsLastStage(s)

        //--- derived: timing
        s.LapIgt       = 0.0;       // TODO(step3): vars.LapIgt(s)        VERIFIED
        s.EventIgt     = 0.0;       // TODO(step3): vars.EventIgt(s)      VERIFIED
        s.FinishIgt    = -1.0;      // TODO(step2): vars.FinishIgt(s)     HAVE
        s.GateBonus    = 0.0;       // TODO(step3): bonusTime             VERIFIED
        s.GatesHit     = 0;         // TODO(step3): vars.GatesHit(s)      VERIFIED
        s.RaceStamp    = c.raceStartTime;                                                     // HAVE        identity of this race instance
        s.LapStamp     = c.lapStartServerTime;                                                // HAVE

        //--- derived: campaign
        s.CampaignAct       = -1;    // TODO(step6): campaignAct                               LEAD
        s.CampaignRunActive = false; // TODO(step6): activeRun != 0                            VERIFIED field
        s.PrologueFlag      = false; // TODO(step6): playingPrologue != 0                      VERIFIED field

        return s;
    });

    //=================================================================================================================================================================================================
    // 4. RUN STATE  (REFACTOR.md "Variables > Run state")  — persists across ticks AND races. Written only by the bookkeeping lambdas below and the lifecycle blocks.
    //=================================================================================================================================================================================================
    vars.ResetRun = (Action)(() =>
    {
        dynamic r = new System.Dynamic.ExpandoObject();
        r.Profile             = null;    // set by vars.SelectProfile()
        r.Phase               = "Idle";  // Idle -> Armed (menu start seen, no race yet) -> InRace -> Between (race done, next not loaded) -> Done.
                                         // Except for Armed / Done this is a PROJECTION of Now.Flow (REFACTOR.md "Run state"): FrontEnd.* => Idle,
                                         // Race.{4, 5, 18} => InRace, Race.{6, 14, 15, 30, 8} / Paddock.* / None => Between.
        r.ArmedAt             = DateTime.MinValue;  // wall-clock stamp of the menu departure that armed the run (latch-and-confirm; backdated start offset)
        r.ArmedFrom           = "";      // Flow key we departed from (e.g. "FrontEnd.1"), for the Debug log and ArrivalWrongEdge
        r.EventsDone          = 0;       // races / events completed in this run
        r.IgtTotal            = 0.0;     // sum of FinishIgt over completed races (the Game Time column for RTA categories)
        r.LastEventId         = "";      // identity of the race last entered
        r.LastMapId           = "";
        r.LastFinishedEventId = "";      // for retry detection (same EventId finishing again != progress)
        r.LastAttemptFailed   = false;   // set by OnRaceFailed; next RaceEnteredEdge with the same EventId is a retry
        r.DeadRaceStamp       = 0.0;     // torn-down race's RaceStartTime        (BUGS.md #2)
        r.DeadLapStamp        = 0.0;     // torn-down race's LapStartServerTime   (BUGS.md #2)
        r.PendingStart        = false;   // latched S1 edge waiting for InRace to confirm (DEV_NOTES v0.1.0), if needed
        vars.Run = r;
    });
    vars.ResetRun();

    //--- Bookkeeping (called from update{} in this order; the only writers of vars.Run besides the lifecycle blocks)

    // On IsTearingDown(p, n): store p.RaceStamp / p.LapStamp (only non-zero readings) into Run.Dead*.   HAVE (v0.4.1 update)   TODO(step1)
    vars.CaptureDeadStamps = (Action<dynamic, dynamic>)((p, n) => { });

    // On RaceEnteredEdge: Run.LastEventId / LastMapId = n.*, Phase = "InRace".                           TODO(step3)
    vars.OnRaceEntered = (Action<dynamic, dynamic>)((p, n) => { });

    // On FinishEdge (not failed, not a retry): IgtTotal += n.FinishIgt, EventsDone++, LastFinishedEventId = n.EventId, Phase = "Between".
    // Must run BEFORE gameTime{} reads RunGameTime on the finish tick (update{} runs first, so it does).   TODO(step3)
    vars.OnRaceFinished = (Action<dynamic, dynamic>)((p, n) => { });

    // On FailEdge: Run.LastAttemptFailed = true (retries are allowed in Arcade% / NG+ Sebulba%).          LEAD   TODO(step5)
    vars.OnRaceFailed = (Action<dynamic, dynamic>)((p, n) => { });

    //=================================================================================================================================================================================================
    // 5. PROFILES  (REFACTOR.md "Category profiles", "Start States", "End States", "Reset / ignore states")
    // One record per category. Fields: Name, Start(p,n), IsEnd(p,n), SplitOnLap, SplitOnRace, ResetPolicy ("IL" | "Multi"), RankedBy, ExpectedEventKind (Debug only).
    // S1..S6 / E1..E5 / R1..R7 are the catalogue numbers in REFACTOR.md.
    //=================================================================================================================================================================================================
    vars.MakeProfile = (Func<string, string, Func<dynamic, dynamic, bool>, Func<dynamic, dynamic, bool>, bool, bool, string, string, dynamic>)
        ((name, rankedBy, start, isEnd, splitOnLap, splitOnRace, resetPolicy, expectedKind) =>
    {
        dynamic pr = new System.Dynamic.ExpandoObject();
        pr.Name = name; pr.RankedBy = rankedBy; pr.Start = start; pr.IsEnd = isEnd;
        pr.SplitOnLap = splitOnLap; pr.SplitOnRace = splitOnRace; pr.ResetPolicy = resetPolicy; pr.ExpectedEventKind = expectedKind;
        return pr;
    });

    //--- Start states (S#) and end states (E#), each a (p, n) -> bool built from the edges above. Guards shared by all starts live in start{}.
    Func<dynamic, dynamic, bool> S1_FirstCrossing   = (p, n) => vars.FirstCrossingEdge(p, n);                                              // HAVE      Time Trial, Precision
    Func<dynamic, dynamic, bool> S2_GridGo          = (p, n) => vars.RaceGoEdge(p, n);                                                     // HAVE      Podracing
    Func<dynamic, dynamic, bool> S3_Prologue        = (p, n) => vars.PrologueEdge(p, n);                                                   // VERIFIED  Sebulba%, Any%, NG+ x3. Same flag for new campaign and reset.
    Func<dynamic, dynamic, bool> S4_ActIIIStartRun  = (p, n) => vars.ActIIIStartRunEdge(p, n);                                             // VERIFIED flow  NG+ Act III (Paddock.2 -> Paddock.4)
    // S5 / S6 are latch-and-confirm (REFACTOR.md "Start States"): the profile's Start fires on the CONFIRMING tick under the default (backdated)
    // policy, or on the departure tick under settings["MenuStartTrust"]. MenuDepartureEdge itself only arms the run, in update{}.
    Func<dynamic, dynamic, bool> S5_ArcadeStart     = (p, n) => settings["MenuStartTrust"] ? vars.MenuDepartureEdge(p, n)
                                                                                           : vars.ArrivalConfirmEdge(p, n, vars.EVENT_LANDSPEEDER_ACE);   // VERIFIED readings; event name FIND   Arcade%
    Func<dynamic, dynamic, bool> S6_ScenarioStart   = (p, n) => settings["MenuStartTrust"] ? vars.MenuDepartureEdge(p, n)
                                                                                           : vars.ArrivalConfirmEdge(p, n, "");                           // VERIFIED readings; "" = any event with stageCount > 1   Scenarios

    Func<dynamic, dynamic, bool> E1_SingleFinish    = (p, n) => vars.FinishEdge(p, n);                                                     // HAVE      all ILs
    Func<dynamic, dynamic, bool> E2_LastScenarioRace= (p, n) => vars.FinishEdge(p, n) && (n.IsLastStage || vars.Run.EventsDone + 1 >= vars.SCENARIO_RACE_COUNT); // LEAD M9
    Func<dynamic, dynamic, bool> E3_ExperimentBronze= (p, n) => vars.FinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_THE_EXPERIMENT) && vars.MedalBeaten(n, "Bronze"); // FIND M7, M8
    Func<dynamic, dynamic, bool> E4_SebulbaFinal    = (p, n) => vars.FinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_SEBULBA_FINAL);          // LEAD M6   (sanity: CampaignAct == ACT_I)
    Func<dynamic, dynamic, bool> E5_KestarFinal     = (p, n) => vars.FinishEdge(p, n) && vars.IsEvent(n, vars.EVENT_KESTAR_FINAL);           // LEAD M6   (sanity: CampaignAct == ACT_III)

    //--- The table (REFACTOR.md "Category profiles").           Name                         RankedBy  Start               IsEnd                 Lap    Race   Reset    ExpectedEventKind
    vars.Profiles = new Dictionary<string, dynamic>();
    vars.Profiles["Cat_TimeTrial"]    = vars.MakeProfile("Arcade — Time Trial",        "IGT",    S1_FirstCrossing,   E1_SingleFinish,      true,  false, "IL",    "TimeTrial");
    vars.Profiles["Cat_Precision"]    = vars.MakeProfile("Arcade — Precision Driving", "IGT",    S1_FirstCrossing,   E1_SingleFinish,      true,  false, "IL",    "Precision");
    vars.Profiles["Cat_Podracing"]    = vars.MakeProfile("Tales of Podracing",         "IGT",    S2_GridGo,          E1_SingleFinish,      true,  false, "IL",    "Podracing");
    vars.Profiles["Cat_Scenarios"]    = vars.MakeProfile("Arcade Scenarios",           "RTA",    S6_ScenarioStart,   E2_LastScenarioRace,  false, true,  "Multi", "Scenario");
    vars.Profiles["Cat_ArcadePct"]    = vars.MakeProfile("Arcade%",                    "RTA",    S5_ArcadeStart,     E3_ExperimentBronze,  false, true,  "Multi", "");
    vars.Profiles["Cat_SebulbaPct"]   = vars.MakeProfile("Sebulba%",                   "RTA",    S3_Prologue,        E4_SebulbaFinal,      false, true,  "Multi", "Campaign");
    vars.Profiles["Cat_AnyPct"]       = vars.MakeProfile("Any%",                       "RTA",    S3_Prologue,        E5_KestarFinal,       false, true,  "Multi", "Campaign");
    vars.Profiles["Cat_NGSebulbaPct"] = vars.MakeProfile("NG+ Sebulba%",               "RTA",    S3_Prologue,        E4_SebulbaFinal,      false, true,  "Multi", "Campaign");
    vars.Profiles["Cat_NGAnyPct"]     = vars.MakeProfile("NG+ Any%",                   "RTA",    S3_Prologue,        E5_KestarFinal,       false, true,  "Multi", "Campaign");
    vars.Profiles["Cat_NGChampion"]   = vars.MakeProfile("NG+ Champion%",              "RTA",    S3_Prologue,        E5_KestarFinal,       false, true,  "Multi", "Campaign");
    vars.Profiles["Cat_NGActIII"]     = vars.MakeProfile("NG+ Act III",                "RTA",    S4_ActIIIStartRun,  E5_KestarFinal,       false, true,  "Multi", "Campaign");

    // First ticked category wins. Returns true if the profile changed — this is REFACTOR.md's CategoryChanged edge (R6: reset run state, not the timer).
    vars.SelectProfile = (Func<bool>)(() =>
    {
        string chosen = null;
        foreach (string id in vars.CategoryIds) { if (settings[id]) { if (chosen == null) chosen = id; else vars.Log("WARNING: more than one category ticked; using " + chosen); } }
        if (chosen == null) chosen = "Cat_TimeTrial";
        dynamic next = vars.Profiles[chosen];
        if (vars.Run.Profile != null && vars.Run.Profile.Name == next.Name) return false;
        vars.ResetRun();
        vars.Run.Profile = next;
        vars.Log("profile: " + next.Name + " (" + next.RankedBy + ", reset policy " + next.ResetPolicy + ")");
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

    vars.SelectProfile();                       // R6: category changed -> ResetRun (keeps the timer)

    // Bookkeeping, in this order (REFACTOR.md "Run bookkeeping").
    vars.CaptureDeadStamps(p, n);               // every teardown, regardless of reset policy (BUGS.md #2 happens between Scenario races too)
    // TODO(step3): if (vars.RaceEnteredEdge(p, n))  vars.OnRaceEntered(p, n);
    // TODO(step5): if (vars.FailEdge(p, n))         vars.OnRaceFailed(p, n);
    // TODO(step3): if (vars.FinishEdge(p, n) && !n.Failed && !retry) vars.OnRaceFinished(p, n);
    // TODO(step3): project Run.Phase from n.Flow unless Phase is "Armed" or "Done" (REFACTOR.md "Run state").
    // TODO(step5): if (Run.Phase == "Idle" && Profile uses S5/S6 && vars.MenuDepartureEdge(p, n)) { Run.ArmedAt = DateTime.Now; Run.ArmedFrom = p.Flow; Run.Phase = "Armed"; }
    // TODO(step5): if (Run.Phase == "Armed" && vars.ArrivalWrongEdge(p, n, expected) && !settings["MenuStartTrust"]) { Run.Phase = "Idle"; }   (trust policy: reset{} R7 handles it)

    // Debug: print raw edges (port of v0.4.1 update{}) and derived edges.
    if (settings["Debug"])
    {
        if (vars.FlowEdge(p, n))            vars.Log("flow " + p.Flow + " -> " + n.Flow + (n.flowRecordCount > 1 ? "  WARNING: " + n.flowRecordCount + " active state machines" : ""));
        if (n.raceStarted != p.raceStarted) vars.Log("raceStarted " + p.raceStarted + " -> " + n.raceStarted + "  (RaceStamp " + n.RaceStamp + ")");
        if (n.playerLap   != p.playerLap)   vars.Log("playerLap "   + p.playerLap   + " -> " + n.playerLap + "  hudLap " + n.hudLap + "  totalLaps " + n.totalLaps + "  LapStamp " + n.LapStamp);
        if (n.finished    != p.finished)    vars.Log("finished "    + p.finished    + " -> " + n.finished + "  finishTime " + n.finishTime + "  bonusTime " + n.bonusTime);
        if (n.HudVmPresent != p.HudVmPresent) vars.Log("hudVM " + (n.HudVmPresent ? "defined" : "undefined"));
        if (n.InRace != p.InRace)           vars.Log("InRace " + p.InRace + " -> " + n.InRace);
        // TODO(step3+): EventId / MapId / Phase / EventsDone / IgtTotal changes; EventKind vs Profile.ExpectedEventKind mismatch warning.
    }
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// isLoading{}: true freezes Game Time. With RunGameTime driving Game Time this is simply "not in a live race, or already finished" (REFACTOR.md "Timing" note).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
isLoading
{
    // TODO(step2): port v0.4.1 — return vars.Now.Finished;   (freeze after the finish so the gameTime{} value stays exact)
    // TODO(step3): return !vars.Now.InRace || vars.Now.Finished;   (multi-race: Game Time stops between races)
    // TODO(step8): || (settings["PauseStopsTimer"] && vars.Now.Paused)
    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// gameTime{}: Game Time = run IGT. Runs BEFORE split{} on a tick, so the finish split records the snapped value.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
gameTime
{
    dynamic p = vars.Prev, n = vars.Now;

    // TODO(step2): finish tick — port v0.4.1: if (vars.FinishEdge(p, n) && n.FinishIgt >= 0) return TimeSpan.FromSeconds(vars.Run.IgtTotal + n.FinishIgt);
    //              (Run.IgtTotal is 0 for ILs; OnRaceFinished has already added this race for multi-race profiles — don't double count. Decide which side owns the add.)
    // TODO(step2): lap edge — port v0.4.1: on vars.LapEdge(p, n) with a moved LapStamp, return IgtTotal + LapSplitIgt(n) if within 0.5 s of the running Game Time (garbage guard).
    // TODO(step8): live — return TimeSpan.FromSeconds(vars.RunGameTime(n)) every tick, if hudEventTime proves smooth at 60 Hz (BUGS.md #1 live jitter).
    return null;   // fall back to real time (v0.4.1 behaviour between crossings)
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// start{}: profile's start edge + shared guards (REFACTOR.md "Start States").
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
start
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;

    // Shared guards:
    //   - run.Phase == "Idle"                      (a run in progress never re-starts; R5 handles "runner restarted the category")
    //   - vars.NewRaceInstance(p, n) for race-value starts (S1, S2) — rejects the torn-down race's replayed memory (BUGS.md #2)
    //   - flow-edge starts (S3, S4, and S5/S6 under MenuStartTrust) fire outside a race and need no race-value guard.
    //   - S5/S6 under the default (backdated) policy fire while run.Phase == "Armed", on the confirming tick; the Phase guard below must allow that.
    // TODO(step2): if (run.Phase != "Idle" && !(run.Phase == "Armed" && !settings["MenuStartTrust"])) return false;
    // TODO(step2): bool fired = run.Profile.Start(p, n);
    // TODO(step5): if (fired && run.Phase == "Armed") timer.Run.Offset = -(DateTime.Now - run.ArmedAt);   // backdate to the press (set in start{} — onStart fires after the timer is already running)
    // TODO(step2): if (fired && run.Profile.ResetPolicy == "IL" && !vars.NewRaceInstance(p, n)) { vars.Log("start rejected: torn-down race stamps"); return false; }
    // TODO(step2): if (fired) vars.Log("START (" + run.Profile.Name + ")");
    // TODO(step2): return fired;
    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// split{}: end condition first, then race splits, then lap splits (REFACTOR.md "End States", "Category profiles").
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
split
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;
    // TODO(step2): if (!n.InRace) return false;   (v0.4.1 gate; revisit for multi-race, where the FinishEdge tick is still in-race)

    // E#: the run is over.
    // TODO(step2): if (run.Profile.IsEnd(p, n)) { run.Phase = "Done"; return settings["FinishSplit"]; }

    // Race / event split: a finish that isn't the end. Not on a failed attempt or a retry of LastFinishedEventId.
    // TODO(step3): if (run.Profile.SplitOnRace && vars.FinishEdge(p, n) && !n.Failed && !retry) return settings["RaceSplits"];

    // Lap split: lap k -> k+1 for 1 <= k < totalLaps (0 -> 1 is the start crossing; totalLaps -> totalLaps+1 is the finish).
    // TODO(step2): if (run.Profile.SplitOnLap && settings["LapSplits"] && vars.LapEdge(p, n)) return true;

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// reset{}: owned by the profile's ResetPolicy (REFACTOR.md "Reset / ignore states" R1..R6).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
reset
{
    dynamic p = vars.Prev, n = vars.Now, run = vars.Run;
    if (run.Profile == null) return false;

    if (run.Profile.ResetPolicy == "IL")
    {
        // R1: teardown before the finish -> reset (if enabled). R2: after the finish -> no-op. R3: FailEdge -> reset (if enabled).
        // TODO(step2): port v0.4.1 — if (!settings["ResetOnLeave"]) return false;
        // TODO(step2):   if (vars.IsTearingDown(p, n) && !p.Finished) return true;
        // TODO(step2):   if (p.raceStarted != 0 && n.raceStarted == 0 && !p.Finished) return true;   (restart in place)
        // TODO(step5):   if (vars.FailEdge(p, n)) return true;
        return false;
    }
    else // "Multi"
    {
        // R1/R2/R3: teardowns and fails between races are expected -> never reset on them.
        // R4: FlowEnter(FrontEnd, ROOT / PRIMARY_MODE_SELECT) with Phase in {InRace, Between} — the runner backed out to the main menu. Crisp edge now; still default OFF.
        // R5: a fresh S3/S4/S5/S6 edge while Phase != Idle -> reset (then start{} fires on the same or next tick).
        // R7: trust policy only — Armed and the press led somewhere other than the expected event -> reset.
        // TODO(step5/6): if (run.Phase != "Idle" && run.Phase != "Armed" && run.Profile.Start(p, n)) { vars.Log("RESET: category start seen mid-run"); return true; }
        // TODO(step5):   if (run.Phase == "Armed" && settings["MenuStartTrust"] && vars.ArrivalWrongEdge(p, n, expected)) { vars.Log("RESET: menu start led to " + n.Flow + " / " + n.EventId); return true; }
        return false;
    }
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Lifecycle hooks: keep vars.Run in step with the LiveSplit timer.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
onStart
{
    // TODO(step3): vars.Run.Phase = (race-value start) ? "InRace" : "Armed";  IgtTotal = 0; EventsDone = 0;   (Phase is then projected from Flow each tick)
    vars.Log("timer started" + (vars.Run.Phase == "Armed" ? " (armed from " + vars.Run.ArmedFrom + " at " + vars.Run.ArmedAt.ToString("HH:mm:ss.fff") + ")" : ""));
}

onReset
{
    // Timer reset by the script or the runner: clear run state but keep the profile and the dead-race stamps (they belong to memory, not the run).
    // TODO(step3): dynamic keep = vars.Run.Profile; double dr = vars.Run.DeadRaceStamp, dl = vars.Run.DeadLapStamp; vars.ResetRun(); vars.Run.Profile = keep; ...
    vars.Log("timer reset");
}
