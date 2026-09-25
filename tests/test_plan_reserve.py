"""Planning reserve: the planner stops at (limit - reserve), school truth untouched."""

from datetime import date

from strakalari.core.forecast import forecast_all, forecast_subject
from strakalari.core.models import SubjectState


def test_reserve_lowers_plan_limit_not_school_limit():
    state = forecast_subject(10.0, 4, 80, 160, 25.0, reserve_pct=10.0)
    assert state.limit_pct == 25.0
    assert state.plan_limit_pct == 15.0
    assert state.plan_safe_hours_left <= state.safe_hours_left


def test_default_example_25_minus_10_is_15():
    states, _ = forecast_all({"M": 16.0}, {}, today=date(2026, 9, 7), reserve_pct=10.0)
    assert states and states[0].effective_plan_limit == 15.0
    # School status still uses the real limit: 16 % is not critical at 25 %.
    assert states[0].status != "critical"
    # ... but planning already treats it as over the safe limit.
    assert states[0].plan_status == "critical"


def test_zero_reserve_keeps_old_behavior():
    states, _ = forecast_all({"M": 16.0}, {}, today=date(2026, 9, 7), reserve_pct=0.0)
    assert states[0].effective_plan_limit == states[0].limit_pct == 25.0
    assert states[0].plan_status == states[0].status
    assert states[0].effective_plan_safe == states[0].safe_hours_left


def test_handbuilt_states_fall_back_to_school_values():
    legacy = SubjectState(name="M", current_pct=26.0, limit_pct=25.0,
                          safe_hours_left=0)
    assert legacy.effective_plan_limit == 25.0
    assert legacy.effective_plan_safe == 0
    assert legacy.plan_status == "critical"


def test_reserve_validation():
    from strakalari.core.config import validate_config

    assert validate_config({"absence_plan_reserve_pct": 10.0}) == [] or all(
        "reserve" not in p for p in validate_config({"absence_plan_reserve_pct": 10.0}))
    bad = validate_config({"absence_plan_reserve_pct": -1})
    assert any("reserve" in p for p in bad)
    bad2 = validate_config({"absence_plan_reserve_pct": "lots"})
    assert any("reserve" in p for p in bad2)
