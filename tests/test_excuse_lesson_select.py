"""Regression: koncová hodina po ArrowUp resetu musí kliknout viditelný řádek.

Log z 22. 9.: start-lesson 6 (bez resetu) prošla, end-lesson 6 (13x ArrowUp
reset na začátek) selhala — cílová řádka existovala v DOM, ale Playwright
hlásil `element is not visible` po celých 30 s. DevExpress renderuje skryté
kopie řádků (zavřený popup, šablony), takže `.first` může trefit věčně
neviditelnou kopii, které žádný scroll nepomůže. Oprava: vybrat první
*viditelnou* shodu, při žádné viditelné popup jednou znovu otevřít.
"""
from unittest.mock import MagicMock


class _Row:
    """Fake DevExpress řádky: click selže, dokud se nescrolluje do pohledu."""

    def __init__(self, visible=True):
        self._visible = visible
        self.scrolled = False
        self.clicks = 0

    def is_visible(self):
        return self._visible

    def scroll_into_view_if_needed(self, timeout=None):
        self.scrolled = True
        return True

    def wait_for(self, state="visible", timeout=None):
        return True

    def click(self, timeout=None, **kwargs):
        self.clicks += 1
        if not self._visible:
            raise Exception(
                "element is not visible "
                '(resolved to <td id="comboExcuseToPeriod_DDD_L_LBI4T0">…</td>)'
            )
        if not self.scrolled:
            raise Exception("element is not visible (outside viewport)")
        return True


class _RowsLocator:
    def __init__(self, rows):
        self._rows = rows

    @property
    def first(self):
        return self._rows[0]

    def nth(self, index):
        return self._rows[index]

    def all(self):
        return list(self._rows)

    def wait_for(self, state="visible", timeout=None):
        return True


class _FakePage:
    def __init__(self, rows, combo_clicks=None, combo_value=""):
        self._rows = rows
        self.keyboard = MagicMock()
        self.combo_clicks = combo_clicks if combo_clicks is not None else []
        self.combo_value = combo_value

    def locator(self, selector, *args, **kwargs):
        if "comboExcuse" in selector and "//td" not in selector and "xpath" not in selector:
            outer = self

            class _Combo:
                def click(self, timeout=None, **kw):
                    outer.combo_clicks.append(selector)
                    return True

                def wait_for(self, state="visible", timeout=None):
                    return True

                def input_value(self, timeout=None):
                    val = outer.combo_value
                    if isinstance(val, list):
                        return val.pop(0) if val else ""
                    return val

            class _ComboLoc:
                first = _Combo()

            return _ComboLoc()
        return _RowsLocator(self._rows)


def _client_with_fake_page(rows, combo_clicks=None, combo_value=""):
    from strakalari.core.bakalari_client import BakalariClient

    bm = MagicMock()
    client = BakalariClient(bm, {}, logger=lambda m: None)
    client.page = _FakePage(rows, combo_clicks=combo_clicks, combo_value=combo_value)
    return client


class TestEndLessonVisibleRow:
    def test_end_lesson_6_after_reset_clicks(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=True)]
        client = _client_with_fake_page(rows)
        assert client._select_lesson_safely(6, 1) is True
        assert rows[0].scrolled is True
        assert rows[0].clicks == 1

    def test_start_lesson_6_still_works(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=True)]
        client = _client_with_fake_page(rows)
        assert client._select_lesson_safely(6, 0) is True

    def test_hidden_first_match_clicks_visible_later_match(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        hidden = _Row(visible=False)
        visible = _Row(visible=True)
        client = _client_with_fake_page([hidden, visible])
        assert client._select_lesson_safely(6, 1) is True
        assert hidden.clicks == 0
        assert visible.clicks == 1
        assert visible.scrolled is True

    def test_closed_popup_reopens_before_giving_up(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        combo_clicks: list = []
        rows = [_Row(visible=False)]
        client = _client_with_fake_page(rows, combo_clicks=combo_clicks)

        # Popup se po znovuotevření ukáže: druhý průchod vidí řádek.
        calls = {"n": 0}
        orig = client._visible_option_index

        def _flaky(xpath):
            calls["n"] += 1
            if calls["n"] >= 2:
                rows[0]._visible = True
            return orig(xpath)

        client._visible_option_index = _flaky
        assert client._select_lesson_safely(6, 1) is True
        assert len(combo_clicks) == 2  # otevření + znovuotevření
        assert rows[0].clicks == 1

    def test_no_visible_row_aborts_without_click(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=False)]
        logged: list = []
        client = _client_with_fake_page(rows)
        client.log = logged.append
        assert client._select_lesson_safely(6, 1) is False
        assert rows[0].clicks == 0
        assert any("not selected" in m for m in logged)

    def test_wrong_committed_value_retries_then_succeeds(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=True)]
        # První click combo neprošlo (stále ukazuje 1), druhý už ano (6).
        client = _client_with_fake_page(rows, combo_value=["1", "6"])
        assert client._select_lesson_safely(6, 1) is True
        assert rows[0].clicks == 2

    def test_wrong_committed_value_twice_aborts(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=True)]
        logged: list = []
        client = _client_with_fake_page(rows, combo_value="1")
        client.log = logged.append
        assert client._select_lesson_safely(6, 1) is False
        assert any("not selected" in m for m in logged)

    def test_unreadable_combo_display_does_not_block(self, monkeypatch):
        import strakalari.core.bakalari_excuse as bc_mod

        monkeypatch.setattr(bc_mod.time, "sleep", lambda s: None)
        rows = [_Row(visible=True)]

        client = _client_with_fake_page(rows)

        def _boom(selector):
            raise Exception("no such input on this frontend")

        orig_locator = client.page.locator

        def _locator(selector, *a, **k):
            if selector.endswith("_I"):
                return _boom(selector)
            return orig_locator(selector, *a, **k)

        client.page.locator = _locator
        assert client._select_lesson_safely(6, 1) is True
        assert rows[0].clicks == 1


class TestLessonCommittedMatchesHourOnly:
    """Regrese: číslo hodiny se páruje jen jako číslo hodiny (náběh
    labelu), ne jako libovolné číslo z časového rozsahu.

    Display "6. hodina 8:00-8:45" + hledaná hodina 8 dřív vracel True
    (8 je v časech), ačkoliv je vybraná špatná hodina.
    """

    def _committed(self, combo_value, period):
        rows = [_Row(visible=True)]
        client = _client_with_fake_page(rows, combo_value=combo_value)
        return client._lesson_committed("comboExcuseFromPeriod", period)

    def test_clock_numbers_do_not_match(self):
        assert self._committed("6. hodina 8:00-8:45", 8) is False

    def test_leading_hour_number_matches(self):
        assert self._committed("6. hodina 8:00-8:45", 6) is True

    def test_plain_number_still_matches(self):
        assert self._committed("6", 6) is True
        assert self._committed("1", 6) is False

    def test_unreadable_display_does_not_block(self):
        assert self._committed("", 6) is True
        assert self._committed("nečitelný popis", 6) is True
