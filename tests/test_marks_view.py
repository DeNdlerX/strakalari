"""Marks tab: empty state, subject cards, detail panel and the predictor."""
import sys

sys.path.insert(0, ".")

from strakalari.flet_ui.strings import S
from strakalari.flet_ui.views import marks


def _texts(control):
    out = []
    seen = set()

    def visit(node):
        if node is None or id(node) in seen:
            return
        seen.add(id(node))
        val = getattr(node, "value", None)
        if isinstance(val, str):
            out.append(val)
        for attr in ("content", "label"):
            child = getattr(node, attr, None)
            if child is not None and not isinstance(child, str):
                visit(child)
        for child in getattr(node, "controls", None) or []:
            visit(child)

    visit(control)
    return out


GRADES = {
    "Matematika": [
        {"Grade": "2", "Weight": 10, "Date": "05.09.2026"},
        {"Grade": "1", "Weight": 10, "Date": "12.09.2026", "Caption": "Rovnice"},
    ],
    "Fyzika": [
        {"Grade": "3", "Weight": 5, "Date": "06.09.2026"},
    ],
}


def _state(state, grades=GRADES):
    state.data = {"grades": grades}
    state.demo_mode = False
    return state


def test_empty_builds(state):
    state.demo_mode = False
    view = marks.build(state, None)
    assert view is not None
    assert S("no_data") in _texts(view)


def test_subject_cards_show_average_and_final_grade(state):
    texts = _texts(marks.build(_state(state), None))
    assert "Matematika" in texts and "Fyzika" in texts
    assert "1.50" in texts  # Matematika (1 + 2) / 2
    assert "3.00" in texts  # Fyzika
    # Overall = mean of subject averages (how report cards average).
    assert "2.25" in texts
    # Overview panel until a subject is picked.
    assert S("marks_recent").upper() in texts


def test_detail_panel_lists_marks_newest_first_with_topic(state):
    _state(state)
    state.select_marks_subject("Matematika")
    texts = _texts(marks.build(state, None))
    assert S("marks_predictor").upper() in texts
    assert "Rovnice" in texts
    newest = [i for i, t in enumerate(texts) if "12. 9. 2026" in t]
    oldest = [i for i, t in enumerate(texts) if "5. 9. 2026" in t]
    assert newest and oldest and min(newest) < min(oldest)


def test_percent_subjects_autodetected(state):
    _state(state, {"Chemie": [{"Grade": "53", "Weight": 5, "Date": "10.09.2026"},
                              {"Grade": "100", "Weight": 1, "Date": "15.09.2026"}]})
    texts = _texts(marks.build(state, None))
    assert "60.8 %" in texts
    assert "53 %" in texts  # bare percentages get their sign


def test_prediction_changes_average_and_shows_banner(state):
    _state(state)
    assert state.predict_add("Fyzika", "1", 5)
    texts = _texts(marks.build(state, None))
    assert "2.00" in texts  # (3 + 1) / 2
    assert S("marks_prediction_on").format(n=1) in texts


def test_non_numeric_grade_does_not_break_average(state):
    _state(state, {"Chemie": [{"Grade": "N", "Weight": 5, "Date": "01.09.2026"},
                              {"Grade": "2", "Weight": 5, "Date": "02.09.2026"}]})
    assert "2.00" in _texts(marks.build(state, None))


def test_planned_mark_listed_not_counted(state):
    _state(state, {"FG": [
        {"Grade": "?", "Weight": 2, "Date": "13.9.2026", "Planned": True,
         "TestDate": "15.1.2027", "Caption": "pololetní test"},
        {"Grade": "1", "Weight": 1, "Date": "10.09.2026"},
    ]})
    texts = _texts(marks.build(state, None))
    assert S("marks_planned").upper() in texts
    assert "1.00" in texts


def test_predictor_state_add_edit_remove_restore(state):
    _state(state)
    assert not state.predict_add("Fyzika", "abc", 1)
    assert not state.predict_add("Fyzika", "1", 0)
    assert state.predict_add("Fyzika", "2", "2,5")
    assert state.marks_predictions["Fyzika"]["added"] == [{"Grade": "2", "Weight": 2.5}]

    assert state.predict_edit("Fyzika", "add:0", "1", 5)
    assert state.marks_predictions["Fyzika"]["added"] == [{"Grade": "1", "Weight": 5.0}]

    key = next(r.key for s in state.marks_summaries() if s.name == "Fyzika"
               for r in s.rows if r.state == "real")
    state.predict_remove("Fyzika", key)
    fyz = next(s for s in state.marks_summaries() if s.name == "Fyzika")
    assert fyz.average == 3.0 and fyz.predicted == 1.0

    state.predict_restore("Fyzika", key)
    state.predict_remove("Fyzika", "add:0")
    assert "Fyzika" not in state.marks_predictions  # nothing left -> dropped

    state.predict_add("Fyzika", "1", 1)
    state.predict_reset()
    assert state.marks_predictions == {}


def test_scale_preferences(state):
    saved = {}
    state.save = lambda updates: saved.update(updates) or True
    assert state.set_marks_scale("percent")
    assert saved == {"marks_scale": "percent", "marks_subject_scales": {}}
    assert not state.set_marks_scale("bogus")
    state.set_subject_scale("Fyzika", "grade")
    assert saved["marks_subject_scales"] == {"Fyzika": "grade"}
    assert not state.set_marks_bands([90, 95, 50, 30])
    assert state.set_marks_bands(["85", 70, 50, 30])
    assert saved["marks_percent_bands"] == [85.0, 70.0, 50.0, 30.0]
    assert state.set_marks_bands(None)
    assert saved["marks_percent_bands"] == []


def test_selecting_the_open_subject_closes_it(state):
    _state(state)
    state.select_marks_subject("Fyzika")
    assert state.marks_selected == "Fyzika"
    state.select_marks_subject("Fyzika")
    assert state.marks_selected is None


def test_saving_an_unchanged_mark_is_not_an_edit(state):
    _state(state)
    key = next(r.key for s in state.marks_summaries() if s.name == "Fyzika" for r in s.rows)
    assert state.predict_edit("Fyzika", key, "3", "5")
    assert "Fyzika" not in state.marks_predictions
    assert state.predict_edit("Fyzika", key, "2", "5")
    assert state.marks_predictions["Fyzika"]["edits"][key] == {"Grade": "2", "Weight": 5.0}


def test_preset_bands_drive_conversion_and_are_labelled(state):
    state.config.data["school_preset_id"] = "gekom_2026_2027"
    assert state.marks_bands_source() == ((87.0, 72.0, 55.0, 40.0), "preset")
    # 88 % is a 1 at GEKOM (would be a 2 with the default 90 %); 87 % a 2.
    _state(state, {"Chemie": [{"Grade": "88", "Weight": 1, "Date": "01.09.2026"}]})
    texts = _texts(marks.build(state, None))
    assert S("marks_bands_src_preset").format(school="GEKOM 2026/2027") in texts
    assert "1: 100–87 · 2: 87–72 · 3: 72–55 · 4: 55–40 · 5: 40–0 %" in texts
    chem = state.marks_summaries()[0]
    from strakalari.core import grades as gr
    assert gr.final_grade(chem.average, chem.scale, state.marks_bands()) == 1
    assert gr.final_grade(87.0, "percent", state.marks_bands()) == 2
