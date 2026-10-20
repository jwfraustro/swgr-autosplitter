"""Fake SWGR process for regression-testing the autosplitter without the game.

Runs under a copy of python.exe renamed SWGR-Win64-Shipping.exe (path in testing/.env, TEST_PYTHON_PATH),
so the unmodified .asl attaches to it. This process *is* the "game": it plants a pointer at
module_base + 0xADFF928 and builds the pointer chains from state{} out of zeroed pages.

BaseSWGRMock holds the universal race transitions (crossing, finish, leave, restart). Each one pauses for
Enter first and prints what LiveSplit should do, so a test case reads as the sequence you watch.
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
    "stageName":          (GS + (0x3F8, 0x10, 0x0), None),        # UTF-16 text, written by Memory.set_stage()
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

# Flow machine ids (FlowMachines / RACE_* in the .asl init{}).
FLOW_FRONTEND, FLOW_RACE = 16, 37
RACE_ROLLING_START, RACE_RACING, RACE_POSTRACE, RACE_PREPARE_TO_LEAVE = 18, 5, 6, 30
MODE_TIME_TRIAL, MODE_PRECISION = 2, 8   # ERaceEventModeType (hudModeType)


def relaunch_as_game(script):
    """Re-run `script` under the renamed interpreter so LiveSplit sees the right process name. Call before anything else."""
    if os.path.basename(sys.executable).lower() == EXE_NAME.lower():
        return
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, ".env")) as f:
        env = dict(line.strip().split("=", 1) for line in f if "=" in line)
    exe = env["TEST_PYTHON_PATH"].strip().strip('"')
    sys.exit(subprocess.call([exe, os.path.abspath(script)] + sys.argv[1:]))


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


class Memory:
    """The fake game's memory. One per process (the root slot can only be reserved once): use memory()."""

    def __init__(self):
        self.base = kernel32.GetModuleHandleW(None)
        self.slot = self.base + ROOT
        alloc(0x10000, at=self.slot & ~0xFFFF)   # reservations are 64 KB-aligned
        print(f"base {self.base:#x}  root slot {self.slot:#x}")

    def addr(self, path):
        """Walk the chain like LiveSplit's DeepPointer; a null link gets a fresh zeroed page."""
        a = self.slot
        for off in path:
            ptr = ctypes.c_uint64.from_address(a)
            if not ptr.value:
                ptr.value = alloc()
            a = ptr.value + off
        return a

    def get(self, name):
        path, ctype = FIELDS[name]
        return ctype.from_address(self.addr(path)).value

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


_memory = None
def memory():
    global _memory
    if _memory is None:
        _memory = Memory()
    return _memory


T0 = time.perf_counter()
def now():
    return 1000.0 + (time.perf_counter() - T0)   # server clock


class BaseSWGRMock:
    """Universal race transitions. Subclasses add `test_*` methods (run in definition order) and category entry steps.

    Every transition takes `expect=` (what LiveSplit should do) and waits for Enter before acting.
    LiveSplit reads each variable separately, so transitions write the edge-triggering field LAST (playerLap,
    finished): a poll between writes sees the old state, never a half-made edge.
    """

    def __init__(self):
        self.mem = memory()
        self.dead_stamp = None   # last LapStartServerTime of the race torn down by leave()
        self._n = 0

    # --- runner ------------------------------------------------------------------------------------------------------

    def tests(self):
        return [n for n in type(self).__dict__ if n.startswith("test_")]

    def run_tests(self, names=None):
        for name in names or self.tests():
            if not name.startswith("test_"):
                name = "test_" + name
            test = getattr(self, name)
            print(f"\n=== {type(self).__name__}.{name}")
            if test.__doc__:
                print("    " + " ".join(test.__doc__.split()))
            input("    reset LiveSplit, then Enter to begin")
            self._n = 0
            test()
            print("    end of test")

    def step(self, desc, expect):
        self._n += 1
        input(f"  [{self._n}] {desc:<36} expect: {expect}")

    # --- transitions -------------------------------------------------------------------------------------------------

    def menu(self, expect="nothing"):
        """Front end: no HUD, no race."""
        self.step("menu", expect)
        self.mem.null(HUD)
        self.mem.set(flowEnumCount=FLOW_FRONTEND, flowState=0, flowRecordCount=1,
                     totalLaps=0, raceStarted=0, playerLap=0, finished=0)

    def enter_arcade_race(self, stage, laps, mode_type, expect="nothing"):
        """Level loaded, rolling start, before the start line. New HUD VM; playerLap 0."""
        self.step(f"load {stage} ({laps} laps)", expect)
        self.mem.set_stage(stage)
        self.mem.set(flowEnumCount=FLOW_RACE, flowState=RACE_ROLLING_START, flowRecordCount=1,
                     totalLaps=laps, raceStarted=0, finished=0, finishTime=-1.0,
                     hudNumLaps=laps, hudLap=1, hudModeType=mode_type, playerLap=0)   # the hud* writes create the HUD VM

    def crossing(self, expect, stamp=None):
        """Cross the line: lap k -> k+1. The first crossing also sets RaceStartTime (Arcade). `stamp` overrides the clock."""
        lap = self.mem.get("playerLap")
        self.step(f"crossing, lap {lap} -> {lap + 1}" + (" (stale stamp)" if stamp is not None else ""), expect)
        stamp = now() if stamp is None else stamp
        if lap == 0:
            self.mem.set(raceStartTime=stamp, flowState=RACE_RACING)
        self.mem.set(lapStartServerTime=stamp, hudLap=lap + 2)
        self.mem.set(playerLap=lap + 1)

    def finish(self, expect="finish split, Game Time = finishTime"):
        """Final crossing: EventFinishTime lands on the same tick as bHasFinishedEvent."""
        self.step("finish", expect)
        stamp = now()
        t = stamp - self.mem.get("raceStartTime")
        self.mem.set(lapStartServerTime=stamp, finishTime=t, playerLap=self.mem.get("totalLaps") + 1,
                     flowState=RACE_POSTRACE)
        self.mem.set(finished=1)
        print(f"      finishTime {t:.3f}")

    def leave(self, expect="reset (HUD VM gone)"):
        """Quit to menu: player state back to lap 0, HUD destroyed. Remembers the last stamp (see dead_stamp)."""
        self.step("leave to menu", expect)
        self.dead_stamp = self.mem.get("lapStartServerTime")
        self.mem.set(playerLap=0, finished=0, flowState=RACE_PREPARE_TO_LEAVE)
        self.mem.null(HUD)
        self.mem.set(flowEnumCount=FLOW_FRONTEND, flowState=0, totalLaps=0, raceStarted=0)

    def restart(self, expect="reset (playerLap -> 0)"):
        """Restart in place: lap counter drops to 0, same HUD."""
        self.step("restart in place", expect)
        self.mem.set(finished=0, finishTime=-1.0, hudLap=1, flowState=RACE_ROLLING_START)
        self.mem.set(playerLap=0)
