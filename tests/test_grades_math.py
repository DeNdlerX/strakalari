"""core.grades: parsing, scale detection, conversion, predictions, solver."""
import sys
from datetime import date

sys.path.insert(0, ".")

import pytest

from strakalari.core import grades as gr


@pytest.mark.parametrize("text,kind,value", [
    ("1", "small", 1.0),
    ("1-", "grade", 1.5),
    ("5-", "grade", 5.0),
    ("2+", "grade", 2.0),
    ("85", "percent", 85.0),
    ("85 %", "percent", 85.0),
    ("72,5%", "percent", 72.5),
    ("17/20", "percent", 85.0),
    ("0", "percent", 0.0),
])
def test_parse_raw(text, kind, value):
    raw = gr.parse_raw(text)
    assert raw is not None and raw.kind == kind
    assert raw.value == pytest.approx(value)


@pytest.mark.parametrize("text", ["N", "?", "", "X", "A", None, "3/0"])
def test_non_counting_marks(text):
    assert gr.parse_raw(text) is None


def test_points_field_used_when_mark_text_is_not_a_number():
    assert gr.parse_raw("", "9/10").value == pytest.approx(90.0)


def test_valid_mark_text_rejects_out_of_range():
    assert gr.valid_mark_text("100")
    assert not gr.valid_mark_text("101")
    assert not gr.valid_mark_text("120 %")
    assert not gr.valid_mark_text("21/20")
    assert not gr.valid_mark_text("abc")


def test_weights():
    assert gr.parse_weight(None) == 1.0
    assert gr.parse_weight("2,5") == 2.5
    assert gr.parse_weight(-3) == 1.0
    assert gr.parse_weight(0) == 0.0


def test_detect_scale():
    pct = [{"Grade": "53"}, {"Grade": "100"}, {"Grade": "?"}]
    assert gr.detect_scale(pct) == "percent"
    assert gr.detect_scale([{"Grade": "1"}, {"Grade": "2-"}]) == "grade"
    # Mostly grades with one percentage stays a 1–5 subject.
    assert gr.detect_scale([{"Grade": "1"}, {"Grade": "2"}, {"Grade": "85"}]) == "grade"
    # No evidence -> the school-wide fallback.
    assert gr.detect_scale([{"Grade": "N"}], fallback="percent") == "percent"


def test_conversion_uses_bands():
    assert gr.pct_to_grade(90.1) == 1
    assert gr.pct_to_grade(90) == 2  # a boundary is the worse grade's top
    assert gr.pct_to_grade(29) == 5
    assert gr.pct_to_grade(80.5, (95, 80, 60, 40)) == 2


def test_gekom_table_boundaries():
    gekom = (87, 72, 55, 40)
    assert gr.pct_to_grade(100, gekom) == 1
    assert gr.pct_to_grade(87.1, gekom) == 1
    assert gr.pct_to_grade(87, gekom) == 2  # "87 is the first 2"
    assert gr.pct_to_grade(72, gekom) == 3
    assert gr.pct_to_grade(55, gekom) == 4
    assert gr.pct_to_grade(40.5, gekom) == 4
    assert gr.pct_to_grade(40, gekom) == 5
    assert gr.pct_to_grade(0, gekom) == 5
    assert gr.grade_to_pct(1) == pytest.approx(95.0)
    assert gr.grade_to_pct(2) == pytest.approx(82.5)
    assert gr.grade_to_pct(1.5) == pytest.approx((95 + 82.5) / 2)


def test_round_grade_halves_go_down_a_grade():
    assert gr.round_grade(1.49) == 1
    assert gr.round_grade(1.5) == 2


def test_bands_validation():
    assert gr.bands_valid([90, 75, 50, 30])
    assert not gr.bands_valid([90, 90, 50, 30])
    assert not gr.bands_valid([90, 75, 50])
    assert not gr.bands_valid(["a", 75, 50, 30])
    assert not gr.bands_valid("90,75,50,30")
    assert gr.normalize_bands(None) == gr.DEFAULT_BANDS


def test_summary_weighted_average_trend_and_new():
    marks = [
        {"Grade": "1", "Weight": 10, "Date": "05.09.2026"},
        {"Grade": "5", "Weight": 1, "Date": "10.09.2026"},
    ]
    s = gr.summarize("M", marks, today=date(2026, 9, 13))
    assert s.scale == "grade"
    assert s.average == pytest.approx(15 / 11)
    assert s.trend == pytest.approx(15 / 11 - 1)  # the 5 made it worse
    assert s.new_count == 1


def test_forced_percent_converts_a_pure_grade_subject():
    s = gr.summarize("M", [{"Grade": "1"}, {"Grade": "2"}], scale_pref="percent")
    assert s.scale == "percent" and s.forced
    assert s.average == pytest.approx((95 + 82.5) / 2)


def test_bare_small_numbers_are_percent_on_a_percent_subject():
    s = gr.summarize("M", [{"Grade": "80"}, {"Grade": "4"}])
    assert s.scale == "percent"
    assert s.average == pytest.approx(42.0)


def test_forced_grade_converts_percentages():
    s = gr.summarize("M", [{"Grade": "95"}, {"Grade": "60"}], scale_pref="grade")
    assert s.average == pytest.approx(2.0)  # 1 and 3


def test_prediction_ops_leave_real_average_alone():
    marks = [{"Grade": "1", "Weight": 1, "Date": "1.9.2026"},
             {"Grade": "3", "Weight": 1, "Date": "2.9.2026"}]
    keys = gr.mark_keys(marks)
    ops = {"added": [{"Grade": "1", "Weight": 2}],
           "edits": {keys[1]: {"Grade": "2", "Weight": 1}},
           "removed": [keys[0]]}
    s = gr.summarize("M", marks, ops=ops)
    assert s.average == pytest.approx(2.0)
    assert s.predicting
    assert s.predicted == pytest.approx((2 * 1 + 1 * 2) / 3)
    assert [r.state for r in s.rows] == ["removed", "edited", "added"]


def test_mark_keys_distinguish_identical_marks():
    same = {"Grade": "1", "Weight": 1, "Date": "1.9.2026"}
    keys = gr.mark_keys([same, dict(same), {"Id": "X", **same}])
    assert len(set(keys)) == 3
    assert keys[2] == "id:X"


def test_planned_marks_do_not_count():
    s = gr.summarize("M", [{"Grade": "?", "Planned": True, "Weight": 5},
                           {"Grade": "2", "Weight": 1}])
    assert s.average == pytest.approx(2.0)
    assert len(s.planned) == 1


def _rows(marks, scale="auto"):
    return gr.summarize("M", marks, scale_pref=scale)


def test_needed_grade():
    s = _rows([{"Grade": "1", "Weight": 1}, {"Grade": "2", "Weight": 1}])
    need = gr.needed_for(s.rows, s.scale, 1, 1)
    assert need.status == "need" and need.value == 1.0  # (1+2+1)/3 = 1.33
    assert gr.needed_for(s.rows, s.scale, 3, 1).status == "any"


def test_needed_many_best_marks():
    s = _rows([{"Grade": "3", "Weight": 10}])
    need = gr.needed_for(s.rows, s.scale, 1, 1)
    assert need.status == "impossible"
    # (30 + n) / (10 + n) < 1.5  ->  n > 30
    assert need.count == 31


def test_needed_percent():
    s = _rows([{"Grade": "70", "Weight": 1}])
    need = gr.needed_for(s.rows, s.scale, 2, 1)
    # (70 + 80) / 2 = 75 is exactly the top of a 3, so a 2 needs 81.
    assert need.status == "need" and need.value == 81.0
    assert gr.needed_for(s.rows, s.scale, 3, 1).value == 31.0  # > 50
    assert gr.needed_for(s.rows, s.scale, 4, 1).status == "any"  # 35 % > 30


def test_needed_with_no_marks():
    s = _rows([], "grade")
    # A lone 2- averages 2.5, which rounds to a 3.
    assert gr.needed_for(s.rows, "grade", 2, 1).value == 2.0


def test_default_weight_is_most_common():
    s = _rows([{"Grade": "1", "Weight": 3}, {"Grade": "1", "Weight": 3},
               {"Grade": "1", "Weight": 10}])
    assert gr.default_weight(s) == 3


def test_format_value():
    assert gr.format_value(1.5, "grade") == "1.50"
    assert gr.format_value(84.0, "percent") == "84 %"
    assert gr.format_value(84.25, "percent") == "84.2 %"
    assert gr.format_value(None, "grade") == "—"
    assert gr.format_grade_step(2.5) == "2-"
