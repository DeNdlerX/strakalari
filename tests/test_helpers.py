import os
from datetime import datetime
import pytest
from strakalari.core.helpers import parse_date, decrypt, format_excuse_template
from strakalari.core.helpers import extract_lesson_num
from strakalari.core.helpers import atomic_write_json, decrypt_strict, encrypt
import json


class TestHelpers:
    def test_parse_date_standard(self):
        dt = parse_date("15.09.2026")
        assert dt == datetime(2026, 9, 15)

    def test_parse_date_with_spaces(self):
        dt = parse_date("1. 9. 2026")
        assert dt == datetime(2026, 9, 1)

        dt2 = parse_date(" 15 . 09 . 2026 ")
        assert dt2 == datetime(2026, 9, 15)

    def test_parse_date_with_weekday_parentheses(self):
        dt = parse_date("3.9.2026 (čtvrtek)")
        assert dt == datetime(2026, 9, 3)

        dt2 = parse_date("18. 10. 2026 (Pondělí)")
        assert dt2 == datetime(2026, 10, 18)

    def test_parse_date_with_leading_day_prefix(self):
        dt = parse_date("Pondělí 1. 9. 2026")
        assert dt == datetime(2026, 9, 1)

        dt2 = parse_date("Úterý 15.10.2026")
        assert dt2 == datetime(2026, 10, 15)

        dt3 = parse_date("St 02.09.2026")
        assert dt3 == datetime(2026, 9, 2)

    def test_get_user_data_dir_and_resolve_path(self):
        from strakalari.core.helpers import get_user_data_dir, _resolve_path
        data_dir = get_user_data_dir()
        assert isinstance(data_dir, str)
        assert len(data_dir) > 0
        assert "strakalari" in data_dir.lower()

        abs_path = os.path.abspath("test_file.txt")
        assert _resolve_path(abs_path) == abs_path

    def test_parse_date_iso_and_slash(self):
        dt_iso = parse_date("2026-11-25")
        assert dt_iso == datetime(2026, 11, 25)

        dt_slash = parse_date("25/11/2026")
        assert dt_slash == datetime(2026, 11, 25)

    def test_parse_date_invalid(self):
        with pytest.raises(ValueError):
            parse_date("not-a-date")

    def test_encrypt_decrypt_roundtrip(self):
        secret = "MojeHeslo_123!"
        encrypted = encrypt(secret)
        assert encrypted != secret
        decrypted = decrypt(encrypted)
        assert decrypted == secret

    def test_encrypt_decrypt_unicode_and_spaces(self):
        secret = " Tajné heslo s diakritikou: Příliš žluťoučký kůň 123 "
        encrypted = encrypt(secret)
        decrypted = decrypt(encrypted)
        assert decrypted == secret

    def test_decrypt_malformed_fallback(self):
        # Invalid base64 or corrupted data should return original input rather than crashing
        corrupted = "not_valid_base64_???!!!"
        result = decrypt(corrupted)
        assert result == corrupted

    def test_decrypt_empty(self):
        assert decrypt("") == ""

    def test_format_excuse_template(self):
        tpl = "Dobrý den, omluvte absenci dne {date} na hodině {lessons} z předmětu {subject}."
        formatted = format_excuse_template(
            tpl,
            date_str="15.09.2026",
            lessons_str="2. hodina",
            subject_str="Matematika",
            signature_str="Jan Novák",
        )
        assert "dne 15.09.2026" in formatted
        assert "na hodině 2. hodina" in formatted
        assert "z předmětu Matematika" in formatted
        assert "Jan Novák" in formatted


class TestDateFormatUnion:
    def test_parse_date_accepts_short_year_and_iso_slashes(self):
        from strakalari.core.helpers import parse_date
        assert parse_date("07.09.26").strftime("%d.%m.%Y") == "07.09.2026"
        assert parse_date("2026/09/07").strftime("%d.%m.%Y") == "07.09.2026"

    def test_parse_cz_date_accepts_czech_slashes(self):
        from strakalari.core.models import parse_cz_date
        assert str(parse_cz_date("07/09/2026")) == "2026-09-07"


class TestExamplePath:
    def test_only_suffix_replaced(self):
        from strakalari.core.helpers import example_path_for
        assert example_path_for("/x/my.json.d/f.json") == "/x/my.json.d/f.example.json"
        assert example_path_for("a.json") == "a.example.json"


class TestExtractLessonNum:
    def test_time_only_returns_none(self):
        assert extract_lesson_num("8:00 - 8:45") is None

    def test_bare_number_ok(self):
        assert extract_lesson_num("3") == 3

    def test_classic_shape_ok(self):
        assert extract_lesson_num("3 (10:05 - 10:50)") == 3

    def test_empty_none(self):
        assert extract_lesson_num("") is None


class TestStrictDecrypt:
    def test_roundtrip(self):
        token = encrypt("heslo123")
        assert decrypt_strict(token) == "heslo123"

    def test_garbage_returns_none(self):
        assert decrypt_strict("not_valid_base64_???!!!") is None

    def test_empty(self):
        assert decrypt_strict("") == ""


class TestAtomicWrite:
    def test_writes_valid_json(self, tmp_path):
        p = str(tmp_path / "sub" / "data.json")
        atomic_write_json(p, {"a": [1, 2, 3]})
        with open(p, encoding="utf-8") as f:
            assert json.load(f) == {"a": [1, 2, 3]}

    def test_no_tmp_leftovers(self, tmp_path):
        p = str(tmp_path / "data.json")
        atomic_write_json(p, [1])
        assert [f for f in os.listdir(str(tmp_path)) if f.endswith(".tmp")] == []


class TestFileLock:
    def test_lock_release_reacquire(self, tmp_path):
        from strakalari.core.helpers import try_file_lock, release_file_lock
        lock = str(tmp_path / "x.lock")
        token = try_file_lock(lock)
        assert token is not None
        assert try_file_lock(lock) is None
        release_file_lock(token)
        assert try_file_lock(lock) is not None


def test_decrypt_survives_key_file_oserror(monkeypatch):
    import strakalari.core.helpers as helpers

    def _boom():
        raise OSError("disk unavailable")

    monkeypatch.setattr(helpers, "_get_fernet", _boom)
    assert helpers.decrypt("whatever-unreadable", None) == "whatever-unreadable"
