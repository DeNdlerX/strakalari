"""A refresh that fails to render one week must not delete previously
scraped days (and their pending excuses) via full cache replace —
otherwise an unsent lesson vanishes from pending as if excused,
which dry-run mode (sends nothing) must never cause.
"""
from datetime import date

from strakalari.core.cache import merge_timetable_days


class TestMergeTimetableDays:
    def test_keeps_unscraped_days_and_fresh_wins(self):
        old = {"18.09.2026": [{"subject": "M"}], "19.09.2026": [{"subject": "F"}]}
        fresh = {"19.09.2026": [{"subject": "F2"}], "20.09.2026": []}
        merged = merge_timetable_days(old, fresh, window_start=date(2026, 9, 1))
        assert merged["18.09.2026"] == [{"subject": "M"}]
        assert merged["19.09.2026"] == [{"subject": "F2"}]
        assert merged["20.09.2026"] == []

    def test_present_but_empty_day_overwrites(self):
        old = {"19.09.2026": [{"subject": "F"}]}
        fresh = {"19.09.2026": []}
        merged = merge_timetable_days(old, fresh, window_start=date(2026, 9, 1))
        assert merged["19.09.2026"] == []

    def test_prunes_out_of_window_old_days_keeps_garbage(self):
        old = {
            "10.8.2026 (pondělí)": [{"subject": "old"}],
            "01.09.2026": [{"subject": "boundary"}],
            "not-a-date": [{"subject": "kept"}],
        }
        merged = merge_timetable_days(old, {}, window_start=date(2026, 9, 1))
        assert "10.8.2026 (pondělí)" not in merged
        assert merged["01.09.2026"] == [{"subject": "boundary"}]
        assert merged["not-a-date"] == [{"subject": "kept"}]

    def test_no_window_start_keeps_everything(self):
        old = {"10.8.2026 (pondělí)": []}
        assert merge_timetable_days(old, {}) == old

    def test_empty_inputs(self):
        assert merge_timetable_days(None, None) == {}
        assert merge_timetable_days({}, {"a": []}) == {"a": []}


class TestDryRunNeverMarksExcused:
    def _dry_worker(self, monkeypatch):
        import strakalari.core.automation as auto_mod

        class _DryApp:
            excuse_mode = "dry_run"

            def __init__(self, *a, **k):
                pass

            def excuse_single(self, excuse, custom_text=None):
                return True

            def close(self):
                pass

        monkeypatch.setattr(auto_mod, "Strakalari", _DryApp)

    def _state(self):
        import threading

        from strakalari.flet_ui.state import AppState

        st = AppState.__new__(AppState)
        st._flight_lock = threading.Lock()
        st.sending_excuses = set()
        st.excuse_log = []
        st.demo_mode = False
        st.log_lines = []
        st.log = st.log_lines.append
        st._worker_log = st.log_lines.append
        st._emit = lambda: None
        st.report_error = lambda *a, **k: None
        st._spawn = lambda fn, name=None: fn()
        st.current_step = ""
        return st

    def test_submit_excuse_dry_run_leaves_pending(self, monkeypatch):
        self._dry_worker(monkeypatch)
        st = self._state()
        task = {"key": "2026-09-18|6", "kind": "short", "label": "M 6.h",
                "date": "2026-09-18", "period": 6}
        assert st.submit_excuse(task, page=None, template="text") is True
        assert st.excuse_log == []

    def test_submit_day_excuse_dry_run_leaves_pending(self, monkeypatch):
        self._dry_worker(monkeypatch)
        st = self._state()
        st.excuse_tasks = lambda: [
            {"key": "2026-09-18|6", "label": "a", "date": "2026-09-18", "period": 6},
        ]
        st.timetable = lambda: {}
        assert st.submit_day_excuse("2026-09-18", template="text", page=None) is True
        assert st.excuse_log == []

    def test_excuse_single_dry_run_fills_only(self, tmp_path):
        from strakalari.core.automation import Strakalari

        hist = tmp_path / "already_excused_lessons.json"
        calls = []

        class _FakeBak:
            def fill_excuse_form(self, *a, **k):
                calls.append((a, k))
                return True

            def execute_excuse(self, *a, **k):
                raise AssertionError("dry-run must never submit")

        app = Strakalari.__new__(Strakalari)
        app.excuse_mode = "dry_run"
        app.bakalari_client = _FakeBak()
        app.write_log = lambda *a: None
        excuse = {"type": "days and hours", "starting_day": "18.09.2026",
                  "ending_day": "18.09.2026", "starting_lesson": 6,
                  "ending_lesson": 6}
        assert app.excuse_single(dict(excuse), custom_text="text") is True
        assert len(calls) == 1
        assert not hist.exists()

    def test_excuse_absence_dry_run_sends_nothing(self, tmp_path, monkeypatch):
        from strakalari.core.automation import Strakalari

        hist = tmp_path / "already_excused_lessons.json"

        class _FakeBak:
            timetableData = {}

            def fill_excuse_form(self, *a, **k):
                return True

            def execute_excuse(self, *a, **k):
                raise AssertionError("dry-run must never submit")

        excuse = {"type": "days and hours", "starting_day": "18.09.2026",
                  "ending_day": "18.09.2026", "starting_lesson": 6,
                  "ending_lesson": 6}
        monkeypatch.setattr(Strakalari, "generate_excuses",
                            staticmethod(lambda *a, **k: [dict(excuse)]))
        app = Strakalari.__new__(Strakalari)
        app.excuse_mode = "dry_run"
        app.excuse_delay_days = 2
        app.confirm_excuses = False
        app.on_confirm = None
        app.cancel_requested = False
        app.bakalari_client = _FakeBak()
        app.write_log = lambda *a: None
        app.encoding = "utf-8"
        app.long_absence_excuses = []
        app.short_absence_excuses = []
        app.late_income_excuses = []
        app.default_excuse_selection = "first"
        app.signature = ""
        app._load_history = lambda: ([], str(hist))
        assert app.excuse_pending() == 0
        assert not hist.exists()
