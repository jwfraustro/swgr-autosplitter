"""Fake SWGR process for regression-testing the autosplitter without the game.

Runs under a copy of python.exe renamed SWGR-Win64-Shipping.exe (path in testing/.env, TEST_PYTHON_PATH),
so the unmodified .asl attaches to it. This process *is* the "game": it plants a pointer at
module_base + 0xADFF928 and builds the pointer chains from state{} out of zeroed pages, then steps
through a scenario one Enter at a time while you watch LiveSplit (Debug setting on + DebugView).

    python mock_game.py [happy|restart|deadstamp]

Stamps follow the wall clock (server time = 1000 s + elapsed), so live Game Time and the lap-edge
re-sync agree the way they do in the game.
"""

import ctypes
import os
import subprocess
import sys
import time
from ctypes import wintypes

EXE_NAME = "SWGR-Win64-Shipping.exe"
ROOT = 0xADFF928                     # module-relative static: every chain starts here
GS = (0x1B0,)                        # -> GameState (ARacingGameState)
HUD = GS + (0x3D8,)                  # -> HUD view model
FLOW = GS + (0x298, 0x0, 0xC0)       # -> ActiveStateMachines data
PRS = (0x228, 0x38, 0x0, 0x30, 0x2B8, 0x368)   # -> player race state

# Name -> (path after ROOT, ctype). Same chains as state("SWGR-Win64-Shipping") in the .asl; only what the ILs read.
FIELDS = {
    "flowState":          (FLOW + (0x10,),       ctypes.c_int32),
    "flowEnumCount":      (FLOW + (0x8, 0x50),   ctypes.c_int32),
    "flowRecordCount":    (GS + (0x298, 0x0, 0xC8), ctypes.c_int32),
    "raceStarted":        (GS + (0x388,),        ctypes.c_uint8),
    "totalLaps":          (GS + (0x370,),        ctypes.c_int32),
    "raceStartTime":      (GS + (0x378,),        ctypes.c_double),
    "stageName":          (GS + (0x3F8, 0x10, 0x0), None),        # UTF-16 text, written by set_stage()
    "stageNameLen":       (GS + (0x3F8, 0x18),   ctypes.c_int32),
    "hudVM":              (HUD,                  ctypes.c_uint64),
    "hudLap":             (HUD + (0x16C,),       ctypes.c_int32),
    "hudNumLaps":         (HUD + (0x140,),       ctypes.c_int32),
    "hudModeType":        (HUD + (0x0D8,),       ctypes.c_uint8),
    "playerLap":          (PRS + (0xD4,),        ctypes.c_int32),
    "finished":           (PRS + (0xCC,),        ctypes.c_uint8),
    "finishTime":         (PRS + (0xF0,),        ctypes.c_float),
    "lapStartServerTime": (PRS + (0xE8,),        ctypes.c_double),
}

# Relaunch under the renamed interpreter so LiveSplit sees the right process name.
if os.path.basename(sys.executable).lower() != EXE_NAME.lower():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, ".env")) as f:
        env = dict(line.strip().split("=", 1) for line in f if "=" in line)
    exe = env["TEST_PYTHON_PATH"].strip().strip('"')
    sys.exit(subprocess.call([exe, os.path.abspath(__file__)] + sys.argv[1:]))

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.VirtualAlloc.restype = ctypes.c_void_p
kernel32.VirtualAlloc.argtypes = (ctypes.c_void_p, ctypes.c_size_t, wintypes.DWORD, wintypes.DWORD)
kernel32.GetModuleHandleW.restype = ctypes.c_void_p
kernel32.GetModuleHandleW.argtypes = (wintypes.LPCWSTR,)
MEM_COMMIT, MEM_RESERVE, PAGE_READWRITE = 0x1000, 0x2000, 0x04


def alloc(size=0x1000, at=None):
    addr = kernel32.VirtualAlloc(at, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE)
    if not addr or (at is not None and addr != at):
        raise OSError(f"VirtualAlloc({at and hex(at)}) failed: {ctypes.get_last_error()}")
    return addr


class Mock:
    def __init__(self):
        self.base = kernel32.GetModuleHandleW(None)
        slot = self.base + ROOT
        alloc(0x10000, at=slot & ~0xFFFF)   # reservations are 64 KB-aligned
        self.slot = slot
        print(f"base {self.base:#x}  root slot {slot:#x}")

    def addr(self, path):
        """Walk the chain like LiveSplit's DeepPointer; a null link gets a fresh zeroed page."""
        a = self.slot
        for off in path:
            ptr = ctypes.c_uint64.from_address(a)
            if not ptr.value:
                ptr.value = alloc()
            a = ptr.value + off
        return a

    def set(self, **values):
        for name, v in values.items():
            path, ctype = FIELDS[name]
            ctype.from_address(self.addr(path)).value = v

    def null(self, path):
        """Break the chain at `path` (the object went away). The next set() through it builds a new object."""
        a = self.slot
        for off in path:
            ptr = ctypes.c_uint64.from_address(a).value
            if not ptr:
                return   # already broken further up
            a = ptr + off
        ctypes.c_uint64.from_address(a).value = 0   # the pointer slot at the end of `path`

    def set_stage(self, name):
        data = name.encode("utf-16-le") + b"\0\0"
        ctypes.memmove(self.addr(FIELDS["stageName"][0]), data, len(data))
        self.set(stageNameLen=len(name) + 1)


T0 = time.perf_counter()
def now():
    return 1000.0 + (time.perf_counter() - T0)   # server clock


# --- game-like transitions -------------------------------------------------------------------------------------------
# LiveSplit reads each variable separately, so write the edge-triggering field LAST (playerLap, finished):
# a poll between writes then sees the old state, never a half-made edge.

LAPS = 3

def menu(m):
    m.null(HUD)
    m.set(flowEnumCount=16, flowState=0, flowRecordCount=1, totalLaps=0, raceStarted=0, playerLap=0, finished=0)

def enter_time_trial(m):
    """Level loaded, rolling start, before the start line. New HUD VM; playerLap 0."""
    m.set_stage("EVT_ARC_TT_MOCK")
    m.set(flowEnumCount=37, flowState=18, flowRecordCount=1,
          totalLaps=LAPS, raceStarted=0, finished=0, finishTime=-1.0,
          hudNumLaps=LAPS, hudLap=1, hudModeType=2, playerLap=0)   # the hud* writes create the HUD VM (hudVM != 0)

def crossing(m, stamp=None):
    """Cross the line: lap k -> k+1. The first crossing also sets RaceStartTime (Arcade)."""
    stamp = now() if stamp is None else stamp
    lap = FIELDS["playerLap"][1].from_address(m.addr(FIELDS["playerLap"][0])).value
    if lap == 0:
        m.set(raceStartTime=stamp, flowState=5)
    m.set(lapStartServerTime=stamp, hudLap=lap + 2)
    m.set(playerLap=lap + 1)

def finish(m):
    stamp = now()
    race_start = ctypes.c_double.from_address(m.addr(FIELDS["raceStartTime"][0])).value
    m.set(lapStartServerTime=stamp, finishTime=stamp - race_start, playerLap=LAPS + 1, flowState=6)
    m.set(finished=1)
    print(f"    finishTime {stamp - race_start:.3f}")

def leave(m):
    """Quit to menu: player state goes back to lap 0, HUD destroyed. Remembers the last stamp for 'deadstamp'."""
    m.dead_stamp = ctypes.c_double.from_address(m.addr(FIELDS["lapStartServerTime"][0])).value
    m.set(playerLap=0, finished=0, flowState=30)
    menu(m)

def restart(m):
    """Restart in place: lap counter drops to 0, same HUD."""
    m.set(finished=0, finishTime=-1.0, hudLap=1, flowState=18)
    m.set(playerLap=0)


# --- scenarios: (description, expected in LiveSplit, action) ---------------------------------------------------------

SCENARIOS = {
    "happy": [
        ("menu",                     "nothing",                         menu),
        ("load Time Trial",          "nothing",                         enter_time_trial),
        ("cross start line",         "START",                           crossing),
        ("lap 1 -> 2",               "lap split",                       crossing),
        ("lap 2 -> 3",               "lap split",                       crossing),
        ("finish",                   "finish split, Game Time = finishTime", finish),
        ("leave to menu",            "reset (ResetOnLeave)",            leave),
    ],
    "restart": [
        ("load Time Trial",          "nothing",                         enter_time_trial),
        ("cross start line",         "START",                           crossing),
        ("lap 1 -> 2",               "lap split",                       crossing),
        ("restart in place",         "RESET: playerLap 2 -> 0",         restart),
        ("cross start line",         "START",                           crossing),
    ],
    "deadstamp": [   # BUGS.md #2: the new race briefly shows the torn-down race's LapStartServerTime
        ("load Time Trial",          "nothing",                         enter_time_trial),
        ("cross start line",         "START",                           crossing),
        ("lap 1 -> 2",               "lap split",                       crossing),
        ("leave to menu",            "RESET: HUD VM gone (dead lap stamp captured)", leave),
        ("load Time Trial again",    "nothing",                         enter_time_trial),
        ("crossing w/ stale stamp",  "NO start; Debug: 'start rejected'", lambda m: crossing(m, stamp=m.dead_stamp)),
    ],
}


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "happy"
    steps = SCENARIOS[name]
    m = Mock()
    menu(m)
    print(f"scenario '{name}'. Attach LiveSplit now; Enter runs each step.\n")
    for i, (desc, expect, action) in enumerate(steps, 1):
        input(f"[{i}/{len(steps)}] {desc:<24} expect: {expect}")
        action(m)
    input("\ndone. Enter to exit (LiveSplit detaches).")


if __name__ == "__main__":
    main()
