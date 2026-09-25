"""Blacklist matching: short Czech food words must catch their inflections."""
import pytest

from strakalari.core.matching import is_food_banned


@pytest.mark.parametrize("keyword, meal", [
    ("ryba", "Rybí filé s bramborem"),
    ("ryba", "Smažené ryby"),
    ("ryby", "Rybí prsty"),
    ("sýr", "Smažený sýr"),
    ("sýr", "Sýrová omáčka"),
    ("maso", "Masová směs"),
    ("kuře", "Kuřecí řízek"),
    ("houby", "Houbové rizoto"),
    ("čočka", "Čočková polévka"),
    ("vepřové", "Vepřového guláše"),
])
def test_keyword_bans_inflected_meal(keyword, meal):
    banned, matched = is_food_banned(meal, [keyword])
    assert banned
    assert matched == keyword


@pytest.mark.parametrize("keyword, meal", [
    ("ryb", "Rybíz koláč"),
    ("rybí", "Rybíz koláč"),
    ("ryb", "Rybízový koláč"),
    ("rýže", "Rybí filé"),
    ("sýr", "Rajská omáčka"),
    ("vepřové maso", "Kuřecí maso"),
])
def test_different_words_stay_allowed(keyword, meal):
    assert is_food_banned(meal, [keyword]) == (False, "")


class TestMatchingPrefix:
    def test_rybi_does_not_ban_rybiz(self):
        banned, _ = is_food_banned("Rybíz koláč", ["rybí"])
        assert banned is False

    def test_inflection_still_matches(self):
        banned, kw = is_food_banned("Vepřového guláše", ["vepřové"])
        assert banned is True
        assert kw == "vepřové"


class TestMatching:
    def test_whole_word_not_substring(self):
        banned, _ = is_food_banned("Rybízový koláč", ["ryb"])
        assert banned is False

    def test_diacritics_insensitive(self):
        banned, _ = is_food_banned("Cocka na kyselo", ["čočka"])
        assert banned is True

    def test_inflection_variant(self):
        banned, kw = is_food_banned("Vepřového guláše", ["vepřové"])
        assert banned is True
        assert kw == "vepřové"

    def test_case_insensitive(self):
        banned, _ = is_food_banned("HOUBY smažené", ["houby"])
        assert banned is True
