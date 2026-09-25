"""Single-day Do date: wait-first, read-only-as-fallback, retype only on mismatch.

Regrese k měření 23. 9.: `Datum Do zapsáno za 31,5 s` — čtení spálilo plný
strop na polopřenačteném formuláři (postback po Enteru v Od) a vrátilo
starou hodnotu, pak další čekání spálilo druhý strop. Nové pořadí: klik
(blur Od = commit kopie) → čekání na kopii → čtení jen jako fallback.
"""
from unittest.mock import MagicMock


class _El:
    def __init__(self, rec, value="18.09.2026"):
        self._rec = rec
        self._value = value

    def wait_for(self, state="visible", timeout=None):
        return True

    def click(self, timeout=None, **kwargs):
        self._rec.append("click")
        return True

    def fill(self, value):
        self._rec.append(("fill", value))
        return True

    def press_sequentially(self, value, delay=None):
        self._rec.append(("keys", value))
        return True

    def press(self, key):
        self._rec.append(("press", key))
        return True

    def input_value(self, timeout=None):
        self._rec.append("read")
        if isinstance(self._value, list):
            return self._value.pop(0) if self._value else ""
        return self._value

    def scroll_into_view_if_needed(self, timeout=None):
        return True

    def is_visible(self):
        return True

    def count(self):
        return 0


class _Loc:
    def __init__(self, rec, value="18.09.2026"):
        self.first = _El(rec, value)

    def all(self):
        return [self.first]

    def click(self, timeout=None, **kwargs):
        return self.first.click(timeout=timeout, **kwargs)

    def wait_for(self, state="visible", timeout=None):
        return self.first.wait_for(state=state, timeout=timeout)


class _Page:
    def __init__(self, rec, wait_ok=True, value="18.09.2026"):
        self._rec = rec
        self._wait_ok = wait_ok
        self._value = value
        self.keyboard = MagicMock()

    def locator(self, selector, *args, **kwargs):
        return _Loc(self._rec, self._value)

    def wait_for_function(self, js, timeout=None):
        ok = self._wait_ok
        if isinstance(ok, dict):
            # {"excuseToDate": False} = selhává jen čekání na Do.
            for key, val in ok.items():
                if key in str(js):
                    ok = val
                    break
            else:
                ok = True
        if not ok:
            raise Exception("Timeout exceeded")
        return True


def _client(rec, wait_ok=True, value="18.09.2026"):
    from strakalari.core.bakalari_client import BakalariClient

    bm = MagicMock()
    client = BakalariClient(
        bm,
        {"bakalari_url": "https://bakaweb.gekom.cz",
         "element_wait_s": 2, "page_load_timeout_s": 5,
         "week_switch_delay_s": 0.1},
        logger=lambda m: None,
    )
    client.page = _Page(rec, wait_ok=wait_ok, value=value)
    client.login = lambda: True
    client._select_lesson_safely = lambda period, which=0: True
    return client


def _run(client):
    return client.fill_excuse_form(
        "18.09.2026", "18.09.2026",
        start_lesson=6, end_lesson=6,
        custom_text="Omluvte prosím absenci.",
        is_days=False, excuse_type="days and hours",
    )


class TestSingleDayDo:
    def test_fast_copy_needs_no_read_no_retype(self):
        rec: list = []
        assert _run(_client(rec, wait_ok=True)) is True
        assert "read" not in rec

    def test_no_retype_when_copy_lands(self):
        rec: list = []
        assert _run(_client(rec, wait_ok=True)) is True
        fills = [c for c in rec if isinstance(c, tuple) and c[0] == "fill"]
        # Jediné mazání je Od pole před psaním, Do se nepřepisuje.
        assert len(fills) == 1

    def test_missed_wait_falls_back_to_read(self):
        rec: list = []
        logged: list = []
        client = _client(rec, wait_ok={"excuseToDate": False}, value="18.09.2026")
        client.log = logged.append
        assert _run(client) is True
        assert "read" in rec
        fills = [c for c in rec if isinstance(c, tuple) and c[0] == "fill"]
        assert len(fills) == 1  # stále žádný přepis Do
        assert any("confirmed by reading" in m for m in logged)

    def test_proven_mismatch_retypes(self):
        rec: list = []
        logged: list = []
        client = _client(rec, wait_ok={"excuseToDate": False}, value="17.09.2026")
        client.log = logged.append
        # Finální wait taky selže → abort bez odeslání, ale Do se přepsalo.
        assert _run(client) is False
        fills = [c for c in rec if isinstance(c, tuple) and c[0] == "fill"]
        assert len(fills) == 2  # Od + přepis Do
        assert any("not accepted" in m for m in logged)

    def test_empty_read_rereads_before_retype(self):
        rec: list = []
        logged: list = []
        client = _client(rec, wait_ok={"excuseToDate": False},
                         value=["", "18.09.2026"])
        client.log = logged.append
        assert _run(client) is True
        assert rec.count("read") == 2
        fills = [c for c in rec if isinstance(c, tuple) and c[0] == "fill"]
        assert len(fills) == 1  # jen Od, Do se nepřepisovalo
        assert any("confirmed by reading" in m for m in logged)

    def test_date_probe_trims_like_python(self):
        seen = {}
        page = MagicMock()

        def _wff(js, timeout=None):
            seen["js"] = js
            return True

        page.wait_for_function.side_effect = _wff
        client = _client([], wait_ok=True)
        client.page = page
        assert client._wait_for_date_value(
            "#cphmain_excuseToDate_I", "18.09.2026", timeout_ms=500) is True
        # Koncové mezery (kopie ze serveru) se musí ořezat stejně jako
        # v _norm_date_str, jinak probe nikdy neprojde.
        assert "trim()" in seen["js"]
