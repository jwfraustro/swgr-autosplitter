//=====================================================================================================================================================================================================
// Star Wars: Galactic Racer — LiveSplit autosplitter
// Version: 0.5.0  — Time Trial, Precision Driving and Scenarios tested in LiveSplit (2026-10-22)
//=====================================================================================================================================================================================================


//=====================================================================================================================================================================================================
// READINGS
//=====================================================================================================================================================================================================
state("SWGR-Win64-Shipping")
{
    //--- Flow state machine  (GameState -> AActor.BlueprintCreatedComponents[0] = UGameFlowStateMachineComponent -> ActiveStateMachines[0]).
    //    Both read 0 through a level load (GameState destroyed)
    int    flowState        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x10;        // CurrentStateId — id in the machine's own enum
    int    flowEnumCount    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x298, 0x0, 0xC0, 0x8, 0x50;   // StateMachineStateIdEnum->Names.Num

    //--- ARacingGameState  (GWorld -> GameState). Only an ARacingGameState in a race; garbage otherwise, hence the InRace gate.
    byte   raceStarted      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x388;   // bIsRaceStarted: 0 -> 1 when the grid is released (countdown over).
    int    totalLaps        : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x370;   // LapCount: laps in this event. Elimination (campaign) events read 100
    double raceStartTime    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x378;   // RaceStartTime (server time): -1 before the start;

    //--- URaceEventVM  (HUD view model: GameState + 0x3D8). Pointer is 0 / chain breaks once the player leaves the race.
    long   hudVM            : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8;          // presence == HUD exists
    int    hudLap           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x16C;   // CurrentLapNumber as shown on HUD: starts at 1
    double hudEventTime     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x188;   // CurrentEventTime: running event IGT

    //--- UPlayerRaceEventComponent  (GWorld -> OwningGameInstance -> LocalPlayers[0] -> PlayerController -> PlayerState -> RaceEventComponent)
    int    playerLap          : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD4; // CurrentLapNumber: 0 until first crossing; LapCount+1 after the finish; 0 after leaving
    byte   finished           : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCC; // bHasFinishedEvent: 0 -> 1 on the final crossing.
    float  finishTime         : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF0; // EventFinishTime: -1 until the finish, then the results-screen time
    double lapStartServerTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xE8; // LapStartServerTime: stamp at each crossing

    //--- Event identity  (GameState + 0x3F8 EventRecipe.EventStages -> FRaceEventInstance[0].InternalName, UTF-16).
    //    Arcade "EVT_ARC_TT_CAR_WHP_A_FWD"; campaign "DAL_SHORT_06_TeamRace_Dry".
    string128 stageName     : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3F8, 0x10, 0x0;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// startup{}: settings and the category table. Runs once when the script loads.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
startup
{
    //--- Categories
    // IL's
    settings.Add("Category", true, "Category — pick ONE");
        settings.SetToolTip("Category", "Select exactly one. The category decides the start trigger, the end condition, what counts as a split and when the timer resets.");
    settings.Add("Cat_TimeTrial",    true,  "Arcade — Time Trial",        "Category");
        settings.SetToolTip("Cat_TimeTrial",    "Single Arcade time trial (rolling start). Starts on the first start-line crossing; ends on the final-lap finish. Game Time = in-game time.");
    settings.Add("Cat_Precision",    false, "Arcade — Precision Driving", "Category");
        settings.SetToolTip("Cat_Precision",    "Single Precision Driving event. As Time Trial; Game Time already includes the 1.5 s gate deductions.");
    // settings.Add("Cat_Podracing",    false, "Arcade — Podracing",         "Category");
    //     settings.SetToolTip("Cat_Podracing",    "Single podracer race (grid start). Starts when the countdown ends; ends on the final-lap finish.");

    // Run-length categories: several races in one run. Never auto-reset. Game Time = sum of the races' in-game times.
    settings.Add("Cat_Scenarios",    false, "Arcade Scenarios",           "Category");
        settings.SetToolTip("Cat_Scenarios",    "5 races in sequence. IGT: Game Time runs only during a live race (countdowns, loads and menus between races are not counted). Never auto-resets.");
    // settings.Add("Cat_ArcadePct",    false, "Arcade%",                    "Category");
    //     settings.SetToolTip("Cat_ArcadePct",    "All events in order. RTA. Starts when you leave the menu; splits on every finish (a redone event splits again — skip or undo the split yourself); ends on The Experiment's finish. Never auto-resets.");
    // settings.Add("Cat_SebulbaPct",   false, "Sebulba%",                   "Category");
    //     settings.SetToolTip("Cat_SebulbaPct",   "Fresh save. RTA. Starts when you leave the menu ('Start New Campaign'); ends on the final-lap finish vs Sebulba (last race of Act I).");
    // settings.Add("Cat_AnyPct",       false, "Any%",                       "Category");
    //     settings.SetToolTip("Cat_AnyPct",       "Fresh save. RTA. Starts when you leave the menu ('Start New Campaign'); ends on the final-lap finish vs Kestar's Podracer (last race of Act III).");
    // settings.Add("Cat_NGSebulbaPct", false, "NG+ Sebulba%",               "Category");
    //     settings.SetToolTip("Cat_NGSebulbaPct", "RTA. Starts when you leave the menu (campaign-reset 'Accept'); ends vs Sebulba.");
    // settings.Add("Cat_NGAnyPct",     false, "NG+ Any%",                   "Category");
    //     settings.SetToolTip("Cat_NGAnyPct",     "RTA. Starts when you leave the menu (campaign-reset 'Accept'); ends vs Kestar's Podracer.");
    // settings.Add("Cat_NGChampion",   false, "NG+ Champion%",              "Category");
    //     settings.SetToolTip("Cat_NGChampion",   "As NG+ Any% on Champion difficulty (not checked by the script).");
    // settings.Add("Cat_NGActIII",     false, "NG+ Act III",                "Category");
    //     settings.SetToolTip("Cat_NGActIII",     "RTA. Starts on 'Start Run' at the Act III loadout check (paddock CampaignSetup -> InWorld); ends vs Kestar's Podracer.");

    //--- Splits
    settings.Add("LapSplits",   true,  "Split on each lap");
        settings.SetToolTip("LapSplits",   "Splits on every completed lap except the last (the finish / race split covers that).");
    settings.Add("RaceSplits",  true,  "Split on each race / event (run-length categories)");
        settings.SetToolTip("RaceSplits",  "Splits on every race or event finish while the run is not over. A redone event splits again: skip or undo the split yourself.");
    settings.Add("FinishSplit", true,  "Split on the run's final finish");
        settings.SetToolTip("FinishSplit", "Splits when the category's end condition is met.");

    //--- Reset
    settings.Add("ResetOnLeave", true, "Reset on restart / leaving the race (single-race categories only)");
        settings.SetToolTip("ResetOnLeave", "Reset when the race is restarted or quit before the finish. IL's only.");

    //--- Debug
    settings.Add("Debug", false, "Debug output");
        settings.SetToolTip("Debug", "Prints value changes to the debug log (DbgView).");

    //--- End events (FRaceEventInstance.InternalName). "" never matches, so an unfilled name can never end a run.
    vars.EVENT_THE_EXPERIMENT = "EVT_ARC_TT_CAR_WHP_A_FWD";    // The Experiment — Arcade% end
    vars.EVENT_SEBULBA_FINAL  = "";                            // the Sebulba race, last race of Act I
    vars.EVENT_KESTAR_FINAL   = "";                            // the Kestar's Podracer race, last race of Act III

    //--- Category table. First ticked category in this order wins.
    //    Family   "IL"  single race: start on a race edge, end on its finish, reset on leave if ResetOnLeave.
    //             "Run" several races: never auto-reset, Game Time frozen outside a live race, split on every finish, end on EndEvent.
    //    Start    "Crossing" first start-line crossing (S1) | "GridGo" grid released (S2) | "MenuLeave" left the menu (S3) | "ActIII" Act III Start Run (S4)
    //    EndEvent Run family only: event name that ends the run, "" = never (the runner's split count ends it). IL always ends on the finish.
    vars.Categories = new List<string> {
        "Cat_TimeTrial", "Cat_Precision", /*"Cat_Podracing",*/ "Cat_Scenarios",
        // "Cat_ArcadePct", "Cat_SebulbaPct", "Cat_AnyPct", "Cat_NGSebulbaPct", "Cat_NGAnyPct", "Cat_NGChampion", "Cat_NGActIII"
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
    // vars.CatTable["Cat_ArcadePct"]    = vars.MakeCat("Run", "MenuLeave", vars.EVENT_THE_EXPERIMENT,  false, true);
    // vars.CatTable["Cat_SebulbaPct"]   = vars.MakeCat("Run", "MenuLeave", vars.EVENT_SEBULBA_FINAL,   false, true);
    // vars.CatTable["Cat_AnyPct"]       = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    // vars.CatTable["Cat_NGSebulbaPct"] = vars.MakeCat("Run", "MenuLeave", vars.EVENT_SEBULBA_FINAL,   false, true);
    // vars.CatTable["Cat_NGAnyPct"]     = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    // vars.CatTable["Cat_NGChampion"]   = vars.MakeCat("Run", "MenuLeave", vars.EVENT_KESTAR_FINAL,    false, true);
    // vars.CatTable["Cat_NGActIII"]     = vars.MakeCat("Run", "ActIII",    vars.EVENT_KESTAR_FINAL,    false, true);

    //--- Flow machines (by state-id enum entry count) and the state ids the script uses (Griffin_enums.hpp; DEV_NOTES "Flow state machine").
    vars.FlowMachines = new Dictionary<int, string> { { 37, "Race" }, { 16, "FrontEnd" }, { 9, "Paddock" }, { 4, "PaddockNarrative" } };
    vars.PAD_CAMPAIGN_SETUP = 2;  vars.PAD_PREWORLD = 3;  vars.PAD_INWORLD = 4;   // EPaddockFlowState

    refreshRate = 60;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// init{}: gates, edges and run state.
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

    // Lap values look like a race
    vars.LapsSane   = (Func<dynamic, bool>)((s) =>
    {
        // Total laps has to be sensible, 100 is for elimination races
        return s.totalLaps > 0 && s.totalLaps <= 100
        // and the player's current lap has to be reasonable
        && s.playerLap >= 0 && s.playerLap <= s.totalLaps + 1;
    });

    vars.LapsInSync = (Func<dynamic, bool>)((s) => s.hudLap == s.playerLap + 1); // HUD lap == player lap + 1
    vars.InRace     = (Func<dynamic, bool>)((s) => s.hudVM != 0 && vars.LapsSane(s)); // Local player in a race: HUD view model present and laps sane.

    // The race clock is running: grid released (grid events) or first crossing made (rolling starts)
    vars.RaceLive   = (Func<dynamic, bool>)((s) => vars.InRace(s) && s.finished == 0 && (s.raceStarted == 1 || s.playerLap >= 1));

    //--- Edges  (o = old, c = current)

    // S1  First start-line crossing (rolling start): playerLap 0 -> 1
    vars.FirstCrossingEdge = (Func<dynamic, dynamic, bool>)((o, c) => c.playerLap == 1 && o.playerLap == 0 && c.finished == 0 && vars.LapsSane(c));
    // S2  Grid released: raceStarted 0 -> 1 in race, before the first crossing, counters in sync.
    vars.RaceGoEdge        = (Func<dynamic, dynamic, bool>)((o, c) => vars.InRace(c) && c.raceStarted == 1 && o.raceStarted == 0 && c.playerLap == 0 && vars.LapsInSync(c));
    // S3  Left the menu: the FrontEnd / Paddock machine gave way to Race, or to "None" for the level load.
    vars.MenuLeaveEdge     = (Func<dynamic, dynamic, bool>)((o, c) => vars.InMenu(o) && !vars.InMenu(c));
    // S4  Act III "Start Run" after the loadout check: Paddock.CampaignSetup 2 -> anything else
    vars.ActIIIStartRunEdge = (Func<dynamic, dynamic, bool>)((o, c) =>
        vars.FlowMachine(o) == "Paddock" && o.flowState == vars.PAD_CAMPAIGN_SETUP
        && vars.FlowMachine(c) == "Paddock" && (c.flowState == vars.PAD_PREWORLD || c.flowState == vars.PAD_INWORLD));

    // Lap completed: playerLap k -> k+1 for 1 <= k < totalLaps. (0 -> 1 is the start crossing; totalLaps -> totalLaps+1 is the finish.)
    vars.LapEdge    = (Func<dynamic, dynamic, bool>)((o, c) => c.playerLap == o.playerLap + 1 && o.playerLap >= 1 && c.playerLap <= c.totalLaps && c.finished == 0);
    vars.FinishEdge = (Func<dynamic, dynamic, bool>)((o, c) => c.finished != 0 && o.finished == 0); // Player crossed the final line: finished 0 -> 1

    // A finish that COUNTS: FinishEdge with a real time, in a live race with a real RaceStartTime, and not the torn-down race's memory replaying.
    // While the next level loads the chain flickers back to the dead race and replays finished = 1 (BUGS.md #6) — once with the dead RaceStartTime,
    // once with RaceStartTime 0 and the HUD VM gone.
    vars.ValidFinishEdge = (Func<dynamic, dynamic, bool>)((o, c) =>
        vars.FinishEdge(o, c) && c.finishTime >= 0 && vars.InRace(c) && c.raceStartTime > 0
        && (vars.DeadRaceStamp == 0.0 || c.raceStartTime != vars.DeadRaceStamp));

    //--- Run state
    vars.CatId    = null;      // selected category id; vars.Cat is its table row
    vars.Cat      = null;
    vars.Phase    = "Idle";    // Idle -> Running (onStart) -> Done (end condition split). Where the game is comes from the readings, not from here.
    vars.IgtTotal = 0.0;       // sum of finishTime over the run's completed races (Game Time for run-length categories; == finishTime for ILs)

    // The torn-down race's stamps (BUGS.md #2) so we don't retrigger splits for races that have already ended.
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
// update{}: category selection, dead stamps, IGT bookkeeping, Debug output.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
update
{
    vars.SelectCategory();

    // Remember the torn-down race's stamps so we don't retrigger splits for races that have already ended.
    if (old.playerLap >= 1 && current.playerLap == 0 && old.lapStartServerTime != 0) vars.DeadLapStamp  = old.lapStartServerTime;
    if (old.raceStarted == 1 && current.raceStarted == 0 && old.raceStartTime != 0)  vars.DeadRaceStamp = old.raceStartTime;

    // If it was a valid finish, add its time to the IGT total.
    if (vars.ValidFinishEdge(old, current))
    {
        vars.IgtTotal += current.finishTime;
        vars.Log("race finished: " + current.stageName + "  finishTime " + current.finishTime + "  IgtTotal " + vars.IgtTotal);
    }

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
    // Freeze after the finish so the value set in gameTime{} stays exact.
    if (current.finished != 0) return true;

    // Run-length: also freeze whenever the race clock is not running — menus, loads, the grid countdown.
    return vars.Cat.Family == "Run" && !vars.RaceLive(current);
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// gameTime{}: What the IGT should be at any particular time.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
gameTime
{
    // If this is a valid finish, snap to the IGT total so we don't get polling jitter.
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
// start{}: the category's start edge, plus the dead-stamp guard for race-value starts.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
start
{
    if (vars.Phase != "Idle") return false;   // a run in progress never re-starts; onReset puts Phase back to Idle

    string kind = vars.Cat.Start;

    // Rolling-starts, like Time Trial and Precision Driving.
    if (kind == "Crossing")
    {
        if (!vars.FirstCrossingEdge(old, current)) return false;

        // We detected a start that matches the dead lap stamp, which means it's from a torn-down race.
        if (vars.DeadLapStamp != 0.0 && current.lapStartServerTime == vars.DeadLapStamp)
        {
            vars.Log("start rejected: lapStartServerTime " + current.lapStartServerTime + " is the torn-down race's");
            return false; }
    }

    // Grid-go starts, like standard races.
    else if (kind == "GridGo")
    {
        if (!vars.RaceGoEdge(old, current)) return false;
        if (vars.DeadRaceStamp != 0.0 && current.raceStartTime == vars.DeadRaceStamp) { vars.Log("start rejected: raceStartTime " + current.raceStartTime + " is the torn-down race's"); return false; }
    }

    // Menu-leave and Act 3 starts, which are triggered by leaving the menu or starting Act 3.
    else if (kind == "MenuLeave") { if (!vars.MenuLeaveEdge(old, current)) return false; }
    else if (kind == "ActIII")    { if (!vars.ActIIIStartRunEdge(old, current)) return false; }
    else return false;

    vars.Log("START (" + vars.CatId + ")  " + current.stageName + "  raceStartTime " + current.raceStartTime + "  lapStartServerTime " + current.lapStartServerTime
             + "  flow " + vars.FlowMachine(current) + "." + current.flowState);
    return true;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// split{}: end condition first, then race splits, then lap splits.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
split
{
    if (!vars.InRace(current)) return false;

    // End condition: if the race is already done, no further splits should occur.
    // In IL, there's only one race at all
    if (vars.Cat.Family == "IL")
    {
        if (vars.FinishEdge(old, current)) return settings["FinishSplit"];
    }
    else
    {
        // for run-length categories, the end condition is tracked by the phase variable.
        if (vars.Phase == "Done") return false;
        // E3–E5: a valid finish of the named end event.
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
// reset{}: ILs only, where people are going to be trying over and over.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
reset
{
    if (vars.Cat.Family != "IL" || !settings["ResetOnLeave"]) return false;

    // player left the race
    if (old.hudVM != 0 && current.hudVM == 0)
        {
            vars.Log("RESET: HUD VM gone");
            return true;
        }
    // or they restarted
    if (old.raceStarted == 1 && current.raceStarted == 0)
        {
            vars.Log("RESET: raceStarted 1 -> 0");
            return true;
        }
    // Arcade restarts, where bIsRaceStarted may never be set
    if (old.playerLap >= 1 && current.playerLap == 0 && current.finished == 0)
        {
            vars.Log("RESET: playerLap " + old.playerLap + " -> 0");
            return true;
        }

    return false;
}

//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
// Lifecycle hooks: keep the run state in step with the LiveSplit timer.
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
onStart
{
    vars.IgtTotal = 0.0;
    vars.Phase = "Running";
    vars.Log("timer started  (" + vars.CatId + ")  flow " + vars.FlowMachine(current) + "." + current.flowState);
}

onReset
{
    // Clear the run; keep the category and the dead stamps
    vars.IgtTotal = 0.0;
    vars.Phase = "Idle";
    vars.Log("timer reset  (dead stamps kept: race " + vars.DeadRaceStamp + ", lap " + vars.DeadLapStamp + ")");
}
