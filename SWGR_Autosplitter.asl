//=====================================================================================================================================================================================================
// Star Wars: Galactic Racer — LiveSplit autosplitter
// Version: 0.4.1 (IL / single race only — Arcade vs Race start modes; Game Time from the game's own lap/finish stamps)
//
// See NOTES.md for where each value comes from and how it was verified.
//=====================================================================================================================================================================================================
state("SWGR-Win64-Shipping")
{

    // Release build offset for GWorld: 0xADFF928 -- add a state for me later.
    // BUILD: CL386500 V38591600 -- 0x0AE0C968


    // ARacingGameState (GWorld -> GameState)
    byte   raceStarted : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x388;   // bIsRaceStarted: 0 -> 1 when the race goes (countdown over)
    int    totalLaps   : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x370;   // LapCount: laps in this event
    double raceStartTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x378; // RaceStartTime (server time): base for lap-split Game Time

    // URaceEventVM (HUD view model, GameState +0x3D8). Pointer is 0 / chain breaks once the player leaves the race.
    long   hudVM       : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8;
    int    hudLap      : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x1B0, 0x3D8, 0x16C; // CurrentLapNumber as shown on HUD: starts at 1

    // UPlayerRaceEventComponent (GWorld -> OwningGameInstance -> LocalPlayers[0] -> PlayerController -> PlayerState -> RaceEventComponent)
    int    playerLap   : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xD4; // 0 until first line crossing; LapCount+1 after the finish, CurrentLapNumber
    byte   finished    : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xCC; // bHasFinishedEvent: 0 -> 1 on the final crossing
    float  finishTime  : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xF0; // EventFinishTime: -1 until the finish, then the results-screen time (drives Game Time)
    double lapStartServerTime : "SWGR-Win64-Shipping.exe", 0x0AE0C968, 0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368, 0xE8; // LapStartServerTime: server time of the last line crossing (lap-split Game Time)
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
startup
{
    // Mode — pick one. Decides the start trigger; splits and resets are shared.
    settings.Add("ModeWrapper", true, "Mode Selector: Pick One");
        settings.SetToolTip("ModeWrapper", "Select only one mode. Having both on will start the timer at the wrong time.");
    settings.Add("Arcade", true, "Arcade Mode", "ModeWrapper");
        settings.SetToolTip("Arcade", "For single-player Arcade time trials (rolling start). Starts the timer when you first cross the start line, which is when you get control.");
    settings.Add("Race", false, "Race Mode", "ModeWrapper");
        settings.SetToolTip("Race", "For races with a starting grid. Starts the timer when the countdown ends and racers are released.");

    // Splits
    settings.Add("LapSplits", true, "Split on each lap");
        settings.SetToolTip("LapSplits", "Splits every time a lap is completed, except the last one (the finish split covers that). Use LapCount splits in total.");
    settings.Add("FinishSplit", true, "Split on race finish");
        settings.SetToolTip("FinishSplit", "Splits when the player crosses the finish line on the final lap.");

    // Reset
    settings.Add("ResetOnLeave", true, "Reset on restart / leaving the race");
        settings.SetToolTip("ResetOnLeave", "Resets the timer when the race is restarted or the player quits out. Does nothing after a finished run.");

    // Debug
    settings.Add("Debug", false, "Debug output");
        settings.SetToolTip("Debug", "Prints value changes to the debug log (view with DebugView / DbgView).");

    refreshRate = 60;
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
init
{
    // True when the readings look like a live race for the local player: HUD view model is defined and
    // the lap values are sane. Guards against reading the same offsets from a non-race GameState.
    vars.InRace = (Func<dynamic, bool>)((s) =>
        s.hudVM != 0
        && s.totalLaps > 0 && s.totalLaps < 100
        && s.playerLap >= 0 && s.playerLap <= s.totalLaps + 1
    );
    // Stronger check from testing: in a race (before the finish), HUD lap == player lap + 1.
    // Only used at the start, where both are stable; around a line crossing they may update a tick apart.
    vars.LapsInSync = (Func<dynamic, bool>)((s) => s.hudLap == s.playerLap + 1);

    // Weaker check that doesn't need the HUD. In Arcade the HUD view model appears on/just after the
    // start-line crossing, so gating the Arcade start on InRace loses the 0 -> 1 edge some of the time.
    vars.LapsSane = (Func<dynamic, bool>)((s) =>
        s.totalLaps > 0 && s.totalLaps < 100
        && s.playerLap >= 0 && s.playerLap <= s.totalLaps + 1
    );

    // Timestamps of the race that was just torn down (restart / exit). During the transition the pointer
    // chains flicker between 0 and the dead race's memory, which replays its values (playerLap 0 -> 1,
    // raceStarted 0 -> 1) with the SAME timestamps. A real start always brings a new timestamp. See BUGS.md #2.
    vars.DeadLapStamp = 0.0;
    vars.DeadRaceStart = 0.0;
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
update
{
    // Remember the torn-down race's timestamps (only from real, non-zero readings).
    if (old.playerLap >= 1 && current.playerLap == 0 && old.lapStartServerTime != 0)
        vars.DeadLapStamp = old.lapStartServerTime;
    if (old.raceStarted == 1 && current.raceStarted == 0 && old.raceStartTime != 0)
        vars.DeadRaceStart = old.raceStartTime;

    if (settings["Debug"])
    {
        if (current.raceStarted != old.raceStarted) print("[SWGR] raceStarted " + old.raceStarted + " -> " + current.raceStarted + "  (startTime " + current.raceStartTime + ")");
        if (current.playerLap   != old.playerLap)   print("[SWGR] playerLap "   + old.playerLap   + " -> " + current.playerLap + "  hudLap " + current.hudLap + "  totalLaps " + current.totalLaps);
        if (current.playerLap   != old.playerLap)   print("[SWGR]   lapStartServerTime " + old.lapStartServerTime + " -> " + current.lapStartServerTime + "  (lap time " + (current.lapStartServerTime - old.lapStartServerTime) + ")");
        if (current.finished    != old.finished)    print("[SWGR] finished "    + old.finished    + " -> " + current.finished  + "  finishTime " + current.finishTime);
        if ((current.hudVM != 0) != (old.hudVM != 0)) print("[SWGR] hudVM " + (current.hudVM != 0 ? "defined" : "undefined"));
    }
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
isLoading
{
    // Freeze Game Time once the race is finished, so the value set in gameTime{} stays exact
    // (otherwise real time keeps ticking on between gameTime{} and split{}).
    return current.finished != 0;
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
gameTime
{
    // Game Time runs with real time during the race, then snaps to EventFinishTime on the finish tick
    // (gameTime{} runs before split{}, so the finish split records it). EventFinishTime is the difference
    // of the game's LapStartServerTime stamps at the start and finish crossings, so it matches the results
    // screen and carries none of the up-to-one-poll latency on our start and finish edges (see BUGS.md #1).
    if (current.finished != 0 && old.finished == 0 && current.finishTime >= 0)
    {
        if (settings["Debug"]) print("[SWGR] finish: finishTime " + current.finishTime + "  stamp - raceStartTime " + (current.lapStartServerTime - current.raceStartTime));
        return TimeSpan.FromSeconds(current.finishTime);
    }

    // Lap crossings (lap n -> n+1, before the finish): the game stamps LapStartServerTime at the crossing,
    // so stamp - RaceStartTime is the exact elapsed race time (RaceStartTime = first-crossing stamp in Arcade,
    // countdown end in Race). Setting it re-syncs the live Game Time and makes the lap split exact. Only on a
    // tick where the stamp actually moved, and only if it's within 0.5 s of the running Game Time (garbage guard).
    if (current.playerLap == old.playerLap + 1 && old.playerLap >= 1 && current.finished == 0
        && current.lapStartServerTime != old.lapStartServerTime)
    {
        double lapElapsed = current.lapStartServerTime - current.raceStartTime;
        double running = timer.CurrentTime.GameTime.HasValue ? timer.CurrentTime.GameTime.Value.TotalSeconds : -1;
        if (settings["Debug"]) print("[SWGR] lap edge: stamp - raceStartTime " + lapElapsed + "  running Game Time " + running + "  correction " + (lapElapsed - running));
        if (lapElapsed > 0 && Math.Abs(lapElapsed - running) < 0.5)
            return TimeSpan.FromSeconds(lapElapsed);
    }
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
start
{
    // Arcade: rolling start — the player gets control on the first start-line crossing (playerLap 0 -> 1).
    // Deliberately not gated on the HUD view model or bIsRaceStarted (see NOTES.md, v0.1.0 field testing).
    if (settings["Arcade"])
    {
        if (!(current.playerLap == 1 && old.playerLap == 0 && current.finished == 0 && vars.LapsSane(current))) return false;
        if (current.lapStartServerTime == vars.DeadLapStamp)
        {
            if (settings["Debug"]) print("[SWGR] start rejected: lapStartServerTime " + current.lapStartServerTime + " is the torn-down race's");
            return false;
        }
        return true;
    }

    // Race: countdown over, racers released from the grid.
    if (settings["Race"])
    {
        if (!(vars.InRace(current)
            && current.raceStarted == 1 && old.raceStarted == 0
            && current.playerLap == 0 && vars.LapsInSync(current))) return false;
        if (current.raceStartTime == vars.DeadRaceStart)
        {
            if (settings["Debug"]) print("[SWGR] start rejected: raceStartTime " + current.raceStartTime + " is the torn-down race's");
            return false;
        }
        return true;
    }

    return false;
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
split
{
    if (!vars.InRace(current)) return false;

    // Race finish: bHasFinishedEvent flips on the final crossing (playerLap also goes to totalLaps + 1 that frame).
    if (current.finished == 1 && old.finished == 0)
        return settings["FinishSplit"];

    // Lap splits: lap n -> n+1 for 1 <= n < totalLaps. 0 -> 1 is the start-line crossing, and
    // totalLaps -> totalLaps+1 is the finish, which the finish split handles.
    if (settings["LapSplits"]
        && current.playerLap == old.playerLap + 1
        && old.playerLap >= 1
        && current.playerLap <= current.totalLaps
        && current.finished == 0)
        return true;

    return false;
}
//-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
reset
{
    if (!settings["ResetOnLeave"]) return false;

    // Player left the race (HUD view model goes away).
    if (old.hudVM != 0 && current.hudVM == 0) return true;

    // Race restarted in place: race-started flag drops back to 0.
    if (old.raceStarted == 1 && current.raceStarted == 0) return true;

    // Player lap drops back to 0 mid-run (verified on leaving the race; covers Arcade restarts, where
    // bIsRaceStarted may never be set).
    if (old.playerLap >= 1 && current.playerLap == 0 && current.finished == 0) return true;

    return false;
}
