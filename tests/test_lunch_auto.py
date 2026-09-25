from datetime import date

from strakalari.core.lunch_auto import (
    clamp_gemini_interval,
    filter_picks,
    merge_gemini_with_filter,
    should_run_gemini_auto,
)


def _menu():
    return {
        "21.09.2026": {"a&1&x": "Kuřecí steak", "a&2&x": "Vepřová sekaná"},
        "22.09.2026": {"b&1&x": "Smažený sýr", "b&-1&x": "Odhlásit"},
    }


class TestGeminiDue:
    def test_disabled_never_runs(self):
        assert should_run_gemini_auto(False, "", 2, today=date(2026, 9, 21)) is False

    def test_never_ran_is_due(self):
        assert should_run_gemini_auto(True, "", 2, today=date(2026, 9, 21)) is True

    def test_interval_gating(self):
        assert should_run_gemini_auto(True, "2026-09-20", 2, today=date(2026, 9, 21)) is False
        assert should_run_gemini_auto(True, "2026-09-19", 2, today=date(2026, 9, 21)) is True
        assert should_run_gemini_auto(True, "2026-09-21", 2, today=date(2026, 9, 21)) is False

    def test_interval_clamped(self):
        assert clamp_gemini_interval(0) == 1
        assert clamp_gemini_interval(99) == 30
        assert clamp_gemini_interval("x") == 2


class TestFilterPicks:
    def test_first_non_banned_wins(self):
        picks = filter_picks(_menu(), blacklist=["vepř"], today=date(2026, 9, 20))
        assert picks["21.09.2026"] == "a&1&x"

    def test_past_and_cancelled_skipped(self):
        picks = filter_picks(
            _menu(), blacklist=[], cancelled_days=["22.09.2026"],
            today=date(2026, 9, 21),
        )
        assert "22.09.2026" not in picks
        picks2 = filter_picks(_menu(), blacklist=[], today=date(2026, 9, 23))
        assert picks2 == {}

    def test_closed_day_skipped(self):
        picks = filter_picks(_menu(), blacklist=[], is_open=lambda d: False,
                             today=date(2026, 9, 20))
        assert picks == {}


class TestMerge:
    def test_banned_gemini_replaced_by_filter(self):
        merged = merge_gemini_with_filter(
            {"21.09.2026": "a&2&x"}, _menu(), blacklist=["vepř"],
            today=date(2026, 9, 20),
        )
        assert merged["21.09.2026"] == "a&1&x"

    def test_gap_filled(self):
        merged = merge_gemini_with_filter({}, _menu(), blacklist=[],
                                          today=date(2026, 9, 20))
        assert merged["21.09.2026"] == "a&1&x"
        assert merged["22.09.2026"] == "b&1&x"


class TestMergeCanonicalKeys:
    def test_spelling_variants_merge_into_one_key(self):
        from datetime import date
        from strakalari.core.lunch_auto import merge_gemini_with_filter
        food = {"01.10.2026": {"g&1&x": "Kuřecí", "g&2&x": "Vepřové"}}
        merged = merge_gemini_with_filter(
            {"1.10.2026": "g&1&x"}, food, blacklist=[],
            today=date(2026, 9, 24))
        assert list(merged) == ["01.10.2026"]
        assert merged["01.10.2026"] == "g&1&x"

    def test_filter_picks_uses_canonical_keys(self):
        from datetime import date
        from strakalari.core.lunch_auto import filter_picks
        picks = filter_picks(
            {"1.10.2026": {"g&1&x": "Kuřecí"}}, blacklist=[],
            today=date(2026, 9, 24))
        assert list(picks) == ["01.10.2026"]
