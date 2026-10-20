"""Step through autosplitter test cases while watching LiveSplit (Debug setting on + DebugView).

    python run.py                          every case, every test
    python run.py time_trial               one case
    python run.py time_trial retry basic   chosen tests, in that order
"""

import sys

from swgr_mock import relaunch_as_game

relaunch_as_game(__file__)

from test_time_trial import TestTimeTrial

CASES = {
    "time_trial": TestTimeTrial,
}


if __name__ == "__main__":
    args = sys.argv[1:]
    cases = [args.pop(0)] if args else list(CASES)
    for case in cases:
        CASES[case]().run_tests(args or None)
    input("\ndone. Enter to exit (LiveSplit detaches).")
