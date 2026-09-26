"""Minus grades (e.g. 2-) count in the weighted average."""

import pytest


# -- marks with minus grades count ------------------------------------------

def test_minus_grades_count_in_average():
    from strakalari.core import grades as gr

    assert gr.parse_raw("1-").value == 1.5
    assert gr.parse_raw("2+").value == 2.0
    assert gr.parse_raw("N") is None
    # "5-" can not be worse than the worst grade.
    assert gr.parse_raw("5-").value == 5.0
    assert gr.summarize("M", [{"Grade": "1"}, {"Grade": "2-"}]).average == pytest.approx(1.75)
