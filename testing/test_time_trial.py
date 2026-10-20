from swgr_mock import BaseSWGRMock, MODE_TIME_TRIAL


class TestTimeTrial(BaseSWGRMock):
    STAGE = "EVT_ARC_TT_MOCK"
    LAPS = 3

    def enter_time_trial(self, stage=STAGE, expect="nothing"):
        self.enter_arcade_race(stage, self.LAPS, MODE_TIME_TRIAL, expect)

    def test_basic(self):
        """Full run: start on the first crossing, lap splits, finish split at the exact finishTime, reset on leave."""
        self.menu()
        self.enter_time_trial()
        self.crossing("START")
        self.crossing("lap split")
        self.crossing("lap split")
        self.finish()
        self.leave()

    def test_retry(self):
        """Restart in place mid-race resets; the next first crossing starts again."""
        self.menu()
        self.enter_time_trial()
        self.crossing("START")
        self.crossing("lap split")
        self.restart()
        self.crossing("START")

    def test_dead_stamp(self):
        """BUGS.md #2: the new race briefly shows the torn-down race's LapStartServerTime; that crossing must not start."""
        self.menu()
        self.enter_time_trial()
        self.crossing("START")
        self.crossing("lap split")
        self.leave()
        self.enter_time_trial()
        self.crossing("NO start; Debug: 'start rejected'", stamp=self.dead_stamp)
