import os
import tempfile
import strakalari.core.cache as cache_module
from strakalari.core.cache import load_data_cache, save_data_cache
from strakalari.core.cache import is_cache_stale, describe_cache


class TestCache:
    def test_load_cache_missing_file_returns_empty_dict(self, monkeypatch):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_cache = os.path.join(tmpdir, "cache.json")
            monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)

            data = load_data_cache()
            assert data == {}

    def test_save_and_load_cache(self, monkeypatch):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_cache = os.path.join(tmpdir, "cache.json")
            monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)

            payload = {"absences": {"Matematika": 12.5}, "last_run": "2026-09-05"}
            saved = save_data_cache(payload)
            for k, v in payload.items():
                assert saved.get(k) == v
            assert os.path.exists(temp_cache)

            loaded = load_data_cache()
            for k, v in payload.items():
                assert loaded.get(k) == v

    def test_save_cache_merges_with_existing(self, monkeypatch):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_cache = os.path.join(tmpdir, "cache.json")
            monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)

            save_data_cache({"key1": "val1"})
            save_data_cache({"key2": "val2"})

            loaded = load_data_cache()
            assert loaded.get("key1") == "val1"
            assert loaded.get("key2") == "val2"

    def test_load_corrupted_cache_fallback(self, monkeypatch):
        with tempfile.TemporaryDirectory() as tmpdir:
            temp_cache = os.path.join(tmpdir, "cache.json")
            with open(temp_cache, "w", encoding="utf-8") as f:
                f.write("{invalid_json_format!!")

            monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)
            data = load_data_cache()
            assert data == {}


class TestCacheVersion:
    def test_mismatched_version_ignored(self, tmp_path, monkeypatch):
        import strakalari.core.cache as cache_mod
        f = tmp_path / "dc.json"
        import json
        f.write_text(json.dumps({"_cache_version": 999, "timetable": {"x": 1}}))
        monkeypatch.setattr(cache_mod, "CACHE_FILE", str(f))
        assert cache_mod.load_data_cache() == {}

    def test_current_version_loads(self, tmp_path, monkeypatch):
        import strakalari.core.cache as cache_mod
        f = tmp_path / "dc.json"
        monkeypatch.setattr(cache_mod, "CACHE_FILE", str(f))
        cache_mod.save_data_cache({"timetable": {"x": 1}})
        assert cache_mod.load_data_cache().get("timetable") == {"x": 1}


class TestCacheMeta:
    def test_stale_detection(self):
        assert is_cache_stale({}, ttl_hours=24) is True
        assert is_cache_stale({"last_updated": "01.01.2000 00:00:00"}, ttl_hours=24) is True

    def test_describe_mentions_stale(self):
        label = describe_cache({"last_updated": "01.01.2000 00:00:00"}, ttl_hours=24)
        assert "zastaral" in label


class TestCacheReplace:
    def test_replace_drops_stale_keys(self, monkeypatch, tmp_path):
        temp_cache = str(tmp_path / "cache.json")
        monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)
        save_data_cache({"old": 1, "timetable": {"d": []}})
        saved = save_data_cache({"timetable": {"e": []}}, replace=True)
        assert "old" not in saved
        assert load_data_cache() == saved


def test_corrupt_cache_is_quarantined(monkeypatch, tmp_path):
    temp_cache = str(tmp_path / "data_cache.json")
    with open(temp_cache, "w", encoding="utf-8") as f:
        f.write("{invalid_json_format!!")
    monkeypatch.setattr(cache_module, "CACHE_FILE", temp_cache)

    assert load_data_cache() == {}
    backups = [n for n in os.listdir(str(tmp_path)) if ".corrupt-" in n]
    assert len(backups) == 1
    with open(os.path.join(str(tmp_path), backups[0]), encoding="utf-8") as f:
        assert f.read() == "{invalid_json_format!!"
