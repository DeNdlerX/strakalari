"""Strava ingredient blacklist: edits never overwrite an unreadable file; the shipped template is empty."""
import json

import pytest



# -- blacklist edits never overwrite an unreadable file --------------------

class TestBlacklistEdits:
    @pytest.fixture()
    def bl_state(self, state, tmp_path, monkeypatch):
        path = tmp_path / "strava_blacklist.json"
        monkeypatch.setattr(state, "_blacklist_path", lambda: str(path))
        monkeypatch.setattr(state, "apply_food_filter", lambda prefs: None)
        return state, path

    def test_add_refuses_on_corrupt_file(self, bl_state):
        state, path = bl_state
        original = '["vepřové", "houby", "játra",]'
        path.write_text(original, encoding="utf-8")
        assert state.add_blacklist_word("ryba") is False
        assert path.read_text(encoding="utf-8") == original
        assert state._blacklist_edit_error

    def test_remove_refuses_on_non_list(self, bl_state):
        state, path = bl_state
        path.write_text('{"houby": 1}', encoding="utf-8")
        assert state.remove_blacklist_word("houby") is False
        assert json.loads(path.read_text(encoding="utf-8")) == {"houby": 1}

    def test_add_and_remove_keep_existing_words(self, bl_state):
        state, path = bl_state
        path.write_text('["houby", "játra"]', encoding="utf-8")
        assert state.add_blacklist_word("ryba") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["houby", "játra", "ryba"]
        assert state.remove_blacklist_word("houby") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["játra", "ryba"]

    def test_add_to_missing_file_creates_it(self, bl_state):
        state, path = bl_state
        assert state.add_blacklist_word("ryba") is True
        assert json.loads(path.read_text(encoding="utf-8")) == ["ryba"]


def test_default_blacklist_template_is_empty():
    import json
    import os

    from strakalari.core.helpers import PROJECT_ROOT

    with open(os.path.join(PROJECT_ROOT, "strava_blacklist.example.json"), encoding="utf-8") as f:
        assert json.load(f) == []
