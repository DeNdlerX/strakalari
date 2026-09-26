"""Lunch deadlines see the user's days off after the absence closure."""
from datetime import date



# -- lunch deadlines see days off after the closure --------------------------

def test_unclipped_calendar_keeps_user_days_after_closure():
    from strakalari.core.school_presets import effective_calendar

    cfg = {"sem2_close": "26.04.2027", "user_free_days": ["14.05.2027"]}
    assert date(2027, 5, 14) not in effective_calendar(cfg)[0]
    assert date(2027, 5, 14) in effective_calendar(cfg, clip=False)[0]
