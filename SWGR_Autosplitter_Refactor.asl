//=====================================================================================================================================================================================================
// Star Wars: Galactic Racer — LiveSplit autosplitter
// Version: 0.5.0-dev  — Time Trial, Precision Driving and Scenarios tested in LiveSplit (2026-10-22). Arcade% and the campaign categories
//                       are wired (start on leaving the menu, split on every finish, end on a named event) but untested; the campaign end
//                       events still need their names (vars.EVENT_*). Will replace SWGR_Autosplitter.asl (v0.4.1) when finished.
//
// READ FIRST
//   REFACTOR.md       — design notes, the S/E/R catalogue, invariants, remaining work.
//   MEMORY_OFFSETS.md — every address. Offsets are for the current Steam build (GWorld = exe+0x0AE0C968) and WILL break on game patches.
//   DEV_NOTES.md      — game behaviour, enums, the mods' rules, open items.
//   BUGS.md           — ...bugs.
//
// SHAPE
//   state{}   the readings the script uses — nothing speculative. Readings that were verified but have no consumer live in MEMORY_OFFSETS.md.
//   startup{} settings and the category table (family, start edge, end event, what splits).
//   init{}    a few lambdas over `current` / `old` (gates and edges) and the run state (phase, IGT total, dead-race stamps).
//   update{}  category selection, dead-stamp capture, IGT bookkeeping on every valid finish, Debug output.
//   isLoading / gameTime / start / split / reset  read `current`, `old`, the lambdas, the run state and the selected category.
//
// ASL facts: a reading whose chain fails reads as 0/default, not an error; update{} runs first on a tick, then isLoading{}, gameTime{},
// start{}/split{}/reset{}; a returned gameTime{} value is applied even while isLoading{} is true; settings are checkboxes (no radio buttons).
//=====================================================================================================================================================================================================


//=====================================================================================================================================================================================================
// READINGS  (MEMORY_OFFSETS.md)
//=====================================================================================================================================================================================================
state("SWGR-Win64-Shipping")
{
    //--- Flow state machine  (GameState -> AActor.BlueprintCreatedComponents[0] = UGameFlowStateMachineComponent -> ActiveStateMachines[0]).
    //    EVERY GameState carries one: the race machine in a race, the front-end machine in the menus, the paddock machine in the campaign hub.
    //    flowState alone is ambiguous (Paddock Leaving 5 == race Racing 5): always pair it with flowEnumCount, which identifies the machine.
    //    Both read 0 through a level load (GameState destroyed) — that is the "None" machine and it is expected.
    int    flowState        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x10;        // CurrentStateId — id in the machine's own enum (DEV_NOTES "Flow state machine")
    int    flowEnumCount    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x8, 0x50;   // StateMachineStateIdEnum->Names.Num: 37 race, 16 front end, 9 paddock, 4 paddock narrative, 0 = loading

    //--- ARacingGameState  (GWorld -> GameState). Only an ARacingGameState in a race; garbage otherwise, hence the InRace gate.
    byte   raceStarted      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x388;   // bIsRaceStarted: 0 -> 1 when the grid is released (countdown over). May never be set in Arcade rolling starts
    int    totalLaps        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x370;   // LapCount: laps in this event. Elimination (campaign) events read 100
    double raceStartTime    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x378;   // RaceStartTime (server time): -1 before the start; identity of this race instance (dead-race guard)

    //--- URaceEventVM  (HUD view model: GameState + 0x3D8). Pointer is 0 / chain breaks once the player leaves the race.
    long   hudVM            : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8;          // presence == HUD exists
    int    hudLap           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x16C;   // CurrentLapNumber as shown on HUD: starts at 1
    double hudEventTime     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x188;   // CurrentEventTime: running event IGT, Precision gate deductions already applied. Live Game Time

    //--- UPlayerRaceEventComponent  (GWorld -> OwningGameInstance -> LocalPlayers[0] -> PlayerController -> PlayerState -> RaceEventComponent)
    int    playerLap          : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD4; // CurrentLapNumber: 0 until first crossing; LapCount+1 after the finish; 0 after leaving
    byte   finished           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCC; // bHasFinishedEvent: 0 -> 1 on the final crossing. End trigger for EVERY category
    float  finishTime         : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF0; // EventFinishTime: -1 until the finish, then the results-screen time (Precision: already adjusted)
    double lapStartServerTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xE8; // LapStartServerTime: stamp at each crossing (dead-race guard for crossing starts)

    //--- Event identity  (GameState + 0x3F8 EventRecipe.EventStages -> FRaceEventInstance[0].InternalName, UTF-16).
    //    Arcade "EVT_ARC_TT_CAR_WHP_A_FWD"; campaign "DAL_SHORT_06_TeamRace_Dry". Compared against the category's end event. Stage 0 only (state{} can't index).
    string128 stageName     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x10, 0x0;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// startup{}: settings and the category table. Runs once when the script loads.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
startup
{
    //--- Category (pick one). No auto-detect: the runner's choice decides the start trigger, the end condition, what splits and the reset policy.
    settings.Add("Category", true, "Category — pick ONE");
        settings.SetToolTip("Category", "Select exactly one. The category decides the start trigger, the end condition, what counts as a split and when the timer resets.");
    settings.Add("Cat_TimeTrial",    true,  "Arcade — Time Trial",        "Category");
        settings.SetToolTip("Cat_TimeTrial",    "Single Arcade time trial (rolling start). Starts on the first start-line crossing; ends on the final-lap finish. Game Time = in-game time.");
    settings.Add("Cat_Precision",    false, "Arcade — Precision Driving", "Category");
        settings.SetToolTip("Cat_Precision",    "Single Precision Driving event. As Time Trial; Game Time already includes the 1.5 s gate deductions.");
    // settings.Add("Cat_Podracing",    false, "Arcade — Podracing",         "Category");
    //     settings.SetToolTip("Cat_Podracing",    "Single podracer race (grid start). Starts when the countdown ends; ends on the final-lap finish.");

    // Run-length categories: several races in one run. Never auto-reset. Game Time = sum of the races' in-game times.
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

    //--- Debug
    settings.Add("Debug", false, "Debug output");
        settings.SetToolTip("Debug", "Prints value changes and every start / split / reset decision to the debug log (DbgView).");

    //--- End events (FRaceEventInstance.InternalName). "" never matches, so an unfilled name can never end a run.
    vars.EVENT_THE_EXPERIMENT = "EVT_ARC_TT_CAR_WHP_A_FWD";   // The Experiment — Arcade% end
    vars.EVENT_SEBULBA_FINAL  = "";                            // FIND  the Sebulba race, last race of Act I
    vars.EVENT_KESTAR_FINAL   = "";                            // FIND  the Kestar's Podracer race, last race of Act III

    //--- Category table (REFACTOR.md "Catalogue"). First ticked category in this order wins.
    //    Family   "IL"  single race: start on a race edge, end on its finish, reset on leave if ResetOnLeave.
    //             "Run" several races: never auto-reset, Game Time frozen outside a live race, split on every finish, end on EndEvent.
    //    Start    "Crossing" first start-line crossing (S1) | "GridGo" grid released (S2) | "MenuLeave" left the menu (S3) | "ActIII" Act III Start Run (S4)
    //    EndEvent Run family only: event name that ends the run, "" = never (the runner's split count ends it). IL always ends on the finish.
    vars.Categories = new List<string> {
        "Cat_TimeTrial", "Cat_Precision", /*"Cat_Podracing",*/ "Cat_Scenarios", "Cat_ArcadePct",
        "Cat_SebulbaPct", "Cat_AnyPct", "Cat_NGSebulbaPct", "Cat_NGAnyPct", "Cat_NGChampion", "Cat_NGActIII"
    };
    vars.MakeCat = (Func<string, string, string, bool, bool, dynamic>)((family, start, endEvent, lapSplits, raceSplits) =>
    {
        dynamic c = new System.Dynamic.ExpandoObject();
        c.Family = family; c.Start = start; c.EndEvent = endEvent; c.LapSplits = lapSplits; c.RaceSplits = raceSplits;
        return c;
    });
    //                                                       Family  Start        EndEvent                    Lap    Race
    vars.CatTable = new Dictionary<string, dynamic>();
    vars.CatTable["Cat_TimeTrial"]    = vars.MakeCat("IL",  "Crossing",  "",                         true,  false);
    vars.CatTable["Cat_Precision"]    = vars.MakeCat("IL",  "Crossing",  "",                         true,  false);
    // vars.CatTable["Cat_Podracing"]    = vars.MakeCat("IL",  "GridGo",    "",                         true,  false);
    vars.CatTable["Cat_Scenarios"]    = vars.MakeCat("Run", "GridGo",    "",                         true,  true);
    vars.CatTable["Cat_ArcadePct"]    = vars.MakeCat("Run", "MenuLeave", vars.EVENT_THE_EXPERIMENT,  false, true);
    vars.CatTable["Cat_SebulbaPct"]   = vars.MakeCat("Run", "MenuLeave", vars.EVENT_SEBULBA_FINAL,   false, true);
    vars.CatTable["Cat_AnyPct"]       = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    vars.CatTable["Cat_NGSebulbaPct"] = vars.MakeCat("Run", "MenuLeave", vars.EVENT_SEBULBA_FINAL,   false, true);
    vars.CatTable["Cat_NGAnyPct"]     = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    vars.CatTable["Cat_NGChampion"]   = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    vars.CatTable["Cat_NGActIII"]     = vars.MakeCat("Run", "ActIII",    vars.EVENT_KESTAR_FINAL,    false, true);

    //--- Flow machines (by state-id enum entry count) and the state ids the script uses (Griffin_enums.hpp; DEV_NOTES "Flow state machine").
    vars.FlowMachines = new Dictionary<int, string> { { 37, "Race" }, { 16, "FrontEnd" }, { 9, "Paddock" }, { 4, "PaddockNarrative" } };
    vars.PAD_CAMPAIGN_SETUP = 2;  vars.PAD_PREWORLD = 3;  vars.PAD_INWORLD = 4;   // EPaddockFlowState

    refreshRate = 60;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// init{}: gates, edges and run state. Runs on attach. Nothing here reads memory.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
init
{
    vars.Log = (Action<string>)((msg) => { if (settings["Debug"]) print("[SWGR] " + msg); });

    //--- Gates  (s = current or old)

    // Which flow machine owns the GameState: "None" through a level load, "Unknown" for a count we don't map.
    vars.FlowMachine = (Func<dynamic, string>)((s) =>
    {
        int cnt = (int)s.flowEnumCount;
        var machines = (Dictionary<int, string>)vars.FlowMachines;
        return cnt == 0 ? "None" : (machines.ContainsKey(cnt) ? machines[cnt] : "Unknown");
    });
    // In a menu (front end, paddock, or a paddock cutscene). PaddockNarrative counts as menu so a cutscene can't fire the menu-leave start.
    vars.InMenu = (Func<dynamic, bool>)((s) => { string m = vars.FlowMachine(s); return m == "FrontEnd" || m == "Paddock" || m == "PaddockNarrative"; });

    // Lap values look like a race (v0.4.1, bound raised to <= 100 for Elimination events, BUGS.md #3).
    vars.LapsSane   = (Func<dynamic, bool>)((s) => s.totalLaps > 0 && s.totalLaps <= 100 && s.playerLap >= 0 && s.playerLap <= s.totalLaps + 1);
    // HUD lap == player lap + 1 — only stable away from a crossing (the two can update a tick apart).
    vars.LapsInSync = (Func<dynamic, bool>)((s) => s.hudLap == s.playerLap + 1);
    // Local player in a race: HUD view model present and laps sane. Guards every GameState reading against the menu GameState.
    vars.InRace     = (Func<dynamic, bool>)((s) => s.hudVM != 0 && vars.LapsSane(s));
    // The race clock is running: grid released (grid events) or first crossing made (rolling starts, where bIsRaceStarted may never be set).
    vars.RaceLive   = (Func<dynamic, bool>)((s) => vars.InRace(s) && s.finished == 0 && (s.raceStarted == 1 || s.playerLap >= 1));

    //--- Edges  (o = old, c = current)

    // S1  First start-line crossing (rolling start): playerLap 0 -> 1. Deliberately NOT gated on the HUD VM: it can appear on/after the crossing tick (v0.1.0 field testing).
    vars.FirstCrossingEdge = (Func<dynamic, dynamic, bool>)((o, c) => c.playerLap == 1 && o.playerLap == 0 && c.finished == 0 && vars.LapsSane(c));
    // S2  Grid released: raceStarted 0 -> 1 in race, before the first crossing, counters in sync.
    vars.RaceGoEdge        = (Func<dynamic, dynamic, bool>)((o, c) => vars.InRace(c) && c.raceStarted == 1 && o.raceStarted == 0 && c.playerLap == 0 && vars.LapsInSync(c));
    // S3  Left the menu: the FrontEnd / Paddock machine gave way to Race, or to "None" for the level load. Fires within a poll of the press. Where the game goes next is not checked.
    vars.MenuLeaveEdge     = (Func<dynamic, dynamic, bool>)((o, c) => vars.InMenu(o) && !vars.InMenu(c));
    // S4  Act III "Start Run" after the loadout check: Paddock.CampaignSetup 2 -> Paddock.{PreWorld 3, InWorld 4}. Same machine, no level load. 2->3->4 vs 2->4 TBC; both land here.
    vars.ActIIIStartRunEdge = (Func<dynamic, dynamic, bool>)((o, c) =>
        vars.FlowMachine(o) == "Paddock" && o.flowState == vars.PAD_CAMPAIGN_SETUP
        && vars.FlowMachine(c) == "Paddock" && (c.flowState == vars.PAD_PREWORLD || c.flowState == vars.PAD_INWORLD));

    // Lap completed: playerLap k -> k+1 for 1 <= k < totalLaps. (0 -> 1 is the start crossing; totalLaps -> totalLaps+1 is the finish.)
    vars.LapEdge    = (Func<dynamic, dynamic, bool>)((o, c) => c.playerLap == o.playerLap + 1 && o.playerLap >= 1 && c.playerLap <= c.totalLaps && c.finished == 0);
    // Player crossed the final line: finished 0 -> 1. EventFinishTime lands on the same tick.
    vars.FinishEdge = (Func<dynamic, dynamic, bool>)((o, c) => c.finished != 0 && o.finished == 0);
    // A finish that COUNTS: FinishEdge with a real time, in a live race with a real RaceStartTime, and not the torn-down race's memory replaying.
    // While the next level loads the chain flickers back to the dead race and replays finished = 1 (BUGS.md #6) — once with the dead RaceStartTime,
    // once with RaceStartTime 0 and the HUD VM gone. Drives the IGT bookkeeping, gameTime{}'s finish snap, race splits and every run-length end.
    vars.ValidFinishEdge = (Func<dynamic, dynamic, bool>)((o, c) =>
        vars.FinishEdge(o, c) && c.finishTime >= 0 && vars.InRace(c) && c.raceStartTime > 0
        && (vars.DeadRaceStamp == 0.0 || c.raceStartTime != vars.DeadRaceStamp));

    //--- Run state
    vars.CatId    = null;      // selected category id; vars.Cat is its table row
    vars.Cat      = null;
    vars.Phase    = "Idle";    // Idle -> Running (onStart) -> Done (end condition split). Where the game is comes from the readings, not from here.
    vars.IgtTotal = 0.0;       // sum of finishTime over the run's completed races (Game Time for run-length categories; == finishTime for ILs)
    // The torn-down race's stamps (BUGS.md #2): during teardown the chains flicker back to the dead race's memory and replay its values with the
    // SAME stamps; a real start always brings a new one. Kept across timer resets — they belong to the game's memory, not the run.
    vars.DeadRaceStamp = 0.0;
    vars.DeadLapStamp  = 0.0;

    // First ticked category wins. Returns true when it changed (run state is cleared; the timer is left alone).
    vars.SelectCategory = (Func<bool>)(() =>
    {
        string chosen = null;
        foreach (string id in vars.Categories) { if (settings[id]) { if (chosen == null) chosen = id; else vars.Log("WARNING: more than one category ticked; using " + chosen); } }
        if (chosen == null) chosen = "Cat_TimeTrial";
        if (chosen == vars.CatId) return false;
        vars.CatId = chosen; vars.Cat = vars.CatTable[chosen];
        vars.Phase = "Idle"; vars.IgtTotal = 0.0;
        vars.Log("category: " + chosen + " (" + vars.Cat.Family + ", start " + vars.Cat.Start + ", end '" + vars.Cat.EndEvent + "')");
        return true;
    });
    vars.SelectCategory();
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// update{}: category selection, dead stamps, IGT bookkeeping, Debug output. Runs before every other block on a tick.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
update
{
    vars.SelectCategory();

    // Remember the torn-down race's stamps, only from real non-zero readings (v0.4.1). Every teardown, every category: Scenario transitions go through it too.
    if (old.playerLap >= 1 && current.playerLap == 0 && old.lapStartServerTime != 0) vars.DeadLapStamp  = old.lapStartServerTime;
    if (old.raceStarted == 1 && current.raceStarted == 0 && old.raceStartTime != 0)  vars.DeadRaceStamp = old.raceStartTime;

    // Every finish that counts adds its time. Owns the add: gameTime{} returns the total on the same tick and must not add again.
    // No redo detection: a redone race adds its time too, and the runner skips or undoes its split (REFACTOR.md "Invariants").
    if (vars.ValidFinishEdge(old, current))
    {
        vars.IgtTotal += current.finishTime;
        vars.Log("race finished: " + current.stageName + "  finishTime " + current.finishTime + "  IgtTotal " + vars.IgtTotal);
    }
    else if (vars.FinishEdge(old, current))
        vars.Log("finish ignored: finishTime " + current.finishTime + "  raceStartTime " + current.raceStartTime + "  InRace " + vars.InRace(current)
                 + (current.raceStartTime == vars.DeadRaceStamp ? "  == dead race (replay, BUGS.md #6)" : "  not a live race (replay, BUGS.md #6)"));

    if (settings["Debug"])
    {
        if (current.flowEnumCount != old.flowEnumCount || current.flowState != old.flowState)
            vars.Log("flow " + vars.FlowMachine(old) + "." + old.flowState + " -> " + vars.FlowMachine(current) + "." + current.flowState);
        if (current.raceStarted != old.raceStarted) vars.Log("raceStarted " + old.raceStarted + " -> " + current.raceStarted + "  (raceStartTime " + current.raceStartTime + ")");
        if (current.playerLap   != old.playerLap)   vars.Log("playerLap " + old.playerLap + " -> " + current.playerLap + "  hudLap " + current.hudLap + "  totalLaps " + current.totalLaps
                                                             + "  lapStartServerTime " + old.lapStartServerTime + " -> " + current.lapStartServerTime);
        if (current.finished    != old.finished)    vars.Log("finished " + old.finished + " -> " + current.finished + "  finishTime " + current.finishTime);
        if ((current.hudVM != 0) != (old.hudVM != 0)) vars.Log("hudVM " + (current.hudVM != 0 ? "defined" : "undefined"));
        if (current.stageName != old.stageName)     vars.Log("stageName '" + old.stageName + "' -> '" + current.stageName + "'");
    }
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// isLoading{}: true freezes Game Time.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
isLoading
{
    // IL (v0.4.1): freeze after the finish so the value set in gameTime{} stays exact.
    if (current.finished != 0) return true;
    // Run-length: also freeze whenever the race clock is not running — menus, loads, the grid countdown.
    // Not applied to ILs: in Arcade the HUD VM can appear a tick after the start crossing, and a one-tick freeze there would be a behaviour change.
    return vars.Cat.Family == "Run" && !vars.RaceLive(current);
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// gameTime{}: Game Time = the game's own time. Runs before split{} on a tick, so the finish split records the snapped value.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
gameTime
{
    // Finish tick: snap to EventFinishTime (the game's own start-to-finish stamp difference, so it matches the results screen with none of our
    // polling latency, BUGS.md #1). update{} has already added it to IgtTotal: the total is finishTime for an IL, the run's IGT sum otherwise.
    if (vars.ValidFinishEdge(old, current))
    {
        vars.Log("finish: Game Time -> " + vars.IgtTotal);
        return TimeSpan.FromSeconds(vars.IgtTotal);
    }
    if (current.finished != 0) return null;   // keep the snapped value

    // IL: the HUD's running event time, every tick (Precision: gate deductions already taken off as each gate is passed).
    if (vars.Cat.Family == "IL") return TimeSpan.FromSeconds(current.hudEventTime);

    // Run-length: finished races' total plus the current race's running time while its clock is running.
    if (vars.RaceLive(current)) return TimeSpan.FromSeconds(vars.IgtTotal + current.hudEventTime);
    return TimeSpan.FromSeconds(vars.IgtTotal);
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// start{}: the category's start edge, plus the dead-stamp guard for race-value starts (REFACTOR.md "Catalogue", Starts).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
start
{
    if (vars.Phase != "Idle") return false;   // a run in progress never re-starts; onReset puts Phase back to Idle

    string kind = vars.Cat.Start;
    if (kind == "Crossing")
    {
        if (!vars.FirstCrossingEdge(old, current)) return false;
        if (vars.DeadLapStamp != 0.0 && current.lapStartServerTime == vars.DeadLapStamp) { vars.Log("start rejected: lapStartServerTime " + current.lapStartServerTime + " is the torn-down race's"); return false; }
    }
    else if (kind == "GridGo")
    {
        if (!vars.RaceGoEdge(old, current)) return false;
        if (vars.DeadRaceStamp != 0.0 && current.raceStartTime == vars.DeadRaceStamp) { vars.Log("start rejected: raceStartTime " + current.raceStartTime + " is the torn-down race's"); return false; }
    }
    else if (kind == "MenuLeave") { if (!vars.MenuLeaveEdge(old, current)) return false; }       // fires in a menu: no race-value guard needed
    else if (kind == "ActIII")    { if (!vars.ActIIIStartRunEdge(old, current)) return false; }
    else return false;

    vars.Log("START (" + vars.CatId + ")  " + current.stageName + "  raceStartTime " + current.raceStartTime + "  lapStartServerTime " + current.lapStartServerTime
             + "  flow " + vars.FlowMachine(current) + "." + current.flowState);
    return true;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// split{}: end condition first, then race splits, then lap splits (REFACTOR.md "Catalogue", Ends).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
split
{
    if (!vars.InRace(current)) return false;   // v0.4.1 gate; the finish tick is still in-race for every category

    if (vars.Cat.Family == "IL")
    {
        // E1: the only race's finish (raw v0.4.1 edge).
        if (vars.FinishEdge(old, current)) return settings["FinishSplit"];
    }
    else
    {
        // Once the end condition has fired nothing else splits (a replayed or extra finish after the end must not advance the splits).
        if (vars.Phase == "Done") return false;
        // E3–E5: a valid finish of the named end event. "" never matches (E0: the runner's split count ends the run).
        if (vars.ValidFinishEdge(old, current))
        {
            if (vars.Cat.EndEvent != "" && current.stageName == vars.Cat.EndEvent)
            {
                vars.Phase = "Done";
                vars.Log("END (" + vars.CatId + ")  IgtTotal " + vars.IgtTotal);
                return settings["FinishSplit"];
            }
            // Race / event split: every valid finish that isn't the end. A redone event splits again; the runner skips or undoes it.
            if (vars.Cat.RaceSplits) return settings["RaceSplits"];
        }
    }

    // Lap split: lap k -> k+1 for 1 <= k < totalLaps.
    if (vars.Cat.LapSplits && settings["LapSplits"] && vars.LapEdge(old, current)) return true;

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// reset{}: ILs only, v0.4.1 conditions verbatim. Run-length categories never take a running timer away; the runner resets (REFACTOR.md "Catalogue", Resets).
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
reset
{
    if (vars.Cat.Family != "IL" || !settings["ResetOnLeave"]) return false;

    if (old.hudVM != 0 && current.hudVM == 0)                                       { vars.Log("RESET: HUD VM gone");                              return true; }   // player left the race
    if (old.raceStarted == 1 && current.raceStarted == 0)                           { vars.Log("RESET: raceStarted 1 -> 0");                       return true; }   // race restarted in place
    if (old.playerLap >= 1 && current.playerLap == 0 && current.finished == 0)      { vars.Log("RESET: playerLap " + old.playerLap + " -> 0");     return true; }   // Arcade restarts, where bIsRaceStarted may never be set

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Lifecycle hooks: keep the run state in step with the LiveSplit timer. Fire for script AND manual starts / resets.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
onStart
{
    vars.IgtTotal = 0.0;
    vars.Phase = "Running";
    vars.Log("timer started  (" + vars.CatId + ")  flow " + vars.FlowMachine(current) + "." + current.flowState);
}

onReset
{
    // Clear the run; keep the category and the dead stamps (they belong to memory, not the run).
    vars.IgtTotal = 0.0;
    vars.Phase = "Idle";
    vars.Log("timer reset  (dead stamps kept: race " + vars.DeadRaceStamp + ", lap " + vars.DeadLapStamp + ")");
}
