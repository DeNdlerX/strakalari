"""School calendar presets + override model + absence-closure horizons."""

from datetime import date

from strakalari.core import school_presets as sp
from strakalari.core.config import CANONICAL_DEFAULTS, ConfigManager
from strakalari.core.forecast import forecast_all


def test_gekom_preset_expands_all_ranges_and_singles():
    days = sp.preset_days("gekom_2026_2027")
    # 3 podzimni + 12 vanocni + 5 jarni + 5 velikonocni + 5 singles.
    # No summer range: the preset ends at the sem2 absence closure.
    assert len(days) == 30
    assert days[date(2026, 10, 28)] == "Podzimní prázdniny"
    assert days[date(2026, 11, 16)] == "Ředitelské volno"
    assert days[date(2027, 1, 29)] == "Pololetní prázdniny"
    assert days[date(2026, 9, 28)] == "Státní svátek"
    assert date(2027, 7, 15) not in days


def test_gekom_preset_closes():
    assert sp.preset_closes("gekom_2026_2027") == ("25.01.2027", "26.04.2027")
    assert sp.preset_closes("custom") == ("", "")
    assert sp.preset_closes("unknown-id") == ("", "")


def test_effective_calendar_override_model():
    cfg = {
        "school_preset_id": "gekom_2026_2027",
        # Cancel one preset day (force school) and add a custom one.
        "forced_school_days": ["29.01.2027"],
        "user_free_days": [{"date": "15.03.2027", "label": "Zubař"}],
        "holidays": [],
    }
    dates, labels, info = sp.effective_calendar(cfg)
    assert date(2027, 1, 29) not in dates
    assert date(2027, 3, 15) in dates
    assert labels[date(2027, 3, 15)] == "Zubař"
    assert labels[date(2026, 10, 28)] == "Podzimní prázdniny"
    assert info["forced_school"] == 1
    assert info["user_added"] == 1


def test_effective_calendar_custom_preset_only_user_days():
    cfg = {"school_preset_id": "custom", "user_free_days": ["05.05.2027"],
           "forced_school_days": []}
    dates, _, info = sp.effective_calendar(cfg)
    assert dates == {date(2027, 5, 5)}
    assert info["preset_days"] == 0


def test_resolve_close_user_wins_then_preset():
    assert sp.resolve_close("sem1", {"school_preset_id": "gekom_2026_2027"}) == "25.01.2027"
    cfg = {"school_preset_id": "gekom_2026_2027", "sem1_close": "20.01.2027"}
    assert sp.resolve_close("sem1", cfg) == "20.01.2027"
    assert sp.resolve_close("sem1", {"school_preset_id": "custom"}) == ""


def test_no_migration_legacy_holidays_ignored(tmp_path):
    import json

    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(json.dumps(
        {"holidays": ["10.11.2026"], "school_year_end": "30.06.2027"}), encoding="utf-8")
    mgr = ConfigManager(config_path=str(cfg_path))
    data = mgr.load()
    # No migration: legacy keys stay unread, canonical defaults stand.
    assert data["school_preset_id"] == "custom"
    assert data["user_free_days"] == []
    assert data["sem2_close"] == ""


def test_fresh_config_assumes_no_school(tmp_path):
    # A student of another school must never silently get GEKOM holidays.
    mgr = ConfigManager(config_path=str(tmp_path / "missing.json"))
    data = mgr.load()
    assert data["school_preset_id"] == "custom"
    assert data["user_free_days"] == []


def test_canonical_defaults_have_calendar_keys():
    for key in ("school_preset_id", "user_free_days", "forced_school_days",
                "sem1_close", "sem2_close"):
        assert key in CANONICAL_DEFAULTS


def test_forecast_uses_sem1_closure():
    states, days_left = forecast_all(
        {"Matematika": 10.0}, {},
        holidays=sp.effective_calendar({"school_preset_id": "gekom_2026_2027"})[0],
        today=date(2026, 9, 1),
        sem1_close="25.01.2027",
    )
    assert days_left
    assert max(days_left) == date(2027, 1, 25)
    assert states and states[0].name == "Matematika"


def test_forecast_uses_sem2_closure():
    _, days_left = forecast_all(
        {"Matematika": 10.0}, {},
        today=date(2027, 2, 5),
        sem2_close="26.04.2027",
    )
    assert days_left
    assert max(days_left) == date(2027, 4, 26)


def test_forecast_legacy_year_end_still_applies():
    _, days_left = forecast_all(
        {"Matematika": 10.0}, {},
        today=date(2027, 2, 5),
        school_year_end="26.04.2027",
    )
    assert days_left
    assert max(days_left) == date(2027, 4, 26)


def test_prune_orphan_forced():
    cfg = {"school_preset_id": "gekom_2026_2027",
           "user_free_days": [],
           "forced_school_days": ["01.05.2027", "29.01.2027"]}
    assert sp.prune_orphan_forced(cfg) is True
    assert cfg["forced_school_days"] == ["29.01.2027"]


def _write_user_preset(name, data):
    import json
    import os

    from strakalari.core.helpers import _resolve_path

    folder = _resolve_path(sp.USER_PRESET_DIR)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name), "w", encoding="utf-8") as f:
        json.dump(data, f)


def test_user_preset_file_is_picked_up():
    _write_user_preset("gymxy.json", {
        "id": "gymxy_2026", "title_cs": "Gymnázium XY 2026/2027",
        "sem2_close": "25.06.2027", "lunch_cutoff_time": "13:30",
        "ranges": [["23.12.2026", "01.01.2027", "Vánoce"]],
        "days": [["17.11.2026", "Svátek"]],
    })
    ids = [pid for pid, _ in sp.preset_options("cs")]
    assert "gymxy_2026" in ids and "gekom_2026_2027" in ids
    cfg = {"school_preset_id": "gymxy_2026"}
    dates, _, info = sp.effective_calendar(cfg)
    assert date(2026, 11, 17) in dates and date(2026, 12, 24) in dates
    assert sp.resolve_lunch_cutoff(cfg) == "13:30"


def test_invalid_user_preset_is_ignored(capsys):
    _write_user_preset("bad.json", {"id": "custom", "sem1_close": "never"})
    _write_user_preset("broken.json", "{not json")
    assert [pid for pid, _ in sp.preset_options("cs")] == ["gekom_2026_2027"]
    assert "ignored" in capsys.readouterr().out


def test_user_preset_cannot_replace_shipped_one():
    _write_user_preset("x.json", {"id": "gekom_2026_2027", "title_cs": "Fake",
                                  "days": [["01.03.2027", "x"]]})
    assert sp.get_preset("gekom_2026_2027") is sp.PRESETS["gekom_2026_2027"]


def test_custom_setup_works_without_any_preset():
    cfg = {"school_preset_id": "custom", "user_free_days": ["02.11.2026"]}
    dates, _, info = sp.effective_calendar(cfg)
    assert dates == {date(2026, 11, 2)}
    assert sp.resolve_lunch_cutoff(cfg) == "12:00"
    assert sp.resolve_close("sem2", cfg) == ""


def test_shipped_presets_are_valid():
    for preset in sp.PRESETS.values():
        assert sp.validate_preset(preset) == []


# -- percent -> grade bands ------------------------------------------------------

def test_gekom_ships_its_percent_table():
    assert sp.preset_marks_bands("gekom_2026_2027") == (87.0, 72.0, 55.0, 40.0)
    assert sp.preset_marks_bands("custom") is None


def test_marks_bands_resolution_order():
    from strakalari.core.grades import DEFAULT_BANDS

    gekom = {"school_preset_id": "gekom_2026_2027"}
    assert sp.resolve_marks_bands(gekom) == ((87.0, 72.0, 55.0, 40.0), "preset")
    own = dict(gekom, marks_percent_bands=[95, 80, 60, 40])
    assert sp.resolve_marks_bands(own) == ((95.0, 80.0, 60.0, 40.0), "user")
    broken = dict(gekom, marks_percent_bands=[10, 20, 30, 40])
    assert sp.resolve_marks_bands(broken)[1] == "preset"
    assert sp.resolve_marks_bands({"school_preset_id": "custom"}) == (DEFAULT_BANDS, "default")


def test_preset_bands_validated():
    base = {"id": "x", "title_cs": "X"}
    assert sp.validate_preset(dict(base, marks_percent_bands=[87, 72, 55, 40])) == []
    assert sp.validate_preset(dict(base, marks_percent_bands=[])) == []
    assert sp.validate_preset(dict(base, marks_percent_bands=[40, 55, 72, 87]))
    assert sp.validate_preset(dict(base, marks_percent_bands="87,72"))
