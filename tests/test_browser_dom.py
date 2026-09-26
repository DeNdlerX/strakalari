"""Scraper and excuse-form code against a real browser DOM.

The unit tests elsewhere mock Playwright; these drive the real
``BakalariClient`` code paths (module clicks, waits, row-by-row outbox
reads, the submit and the editor probe) in headless Chromium against a
small fake Bakaláři page. They catch what mocks cannot: selectors that
match nothing, waits that never resolve, JS probes that throw.

Skipped when no Playwright browser is installed (CI installs one).
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock

import pytest

_FIXTURES = Path(__file__).parent / "fixtures"

#: Short budgets: every wait here either resolves in milliseconds or is
#: meant to time out.
_FAST = {
    "bakalari_url": "https://bakalari.example.test",
    "element_wait_s": 1.5,
    "page_load_timeout_s": 1.5,
    "week_switch_delay_s": 0,
}


@pytest.fixture(scope="module")
def browser():
    sync_api = pytest.importorskip("playwright.sync_api")
    pw = sync_api.sync_playwright().start()
    try:
        b = pw.chromium.launch(headless=True)
    except Exception as exc:  # noqa: BLE001 - no browser installed here
        pw.stop()
        pytest.skip(f"no Playwright Chromium available: {type(exc).__name__}")
    yield b
    b.close()
    pw.stop()


@pytest.fixture()
def page(browser):
    ctx = browser.new_context()
    pg = ctx.new_page()
    yield pg
    ctx.close()


def _client(page, **config):
    from strakalari.core.bakalari_client import BakalariClient

    bm = MagicMock()
    bm.page = page
    logs: list[str] = []
    client = BakalariClient(bm, {**_FAST, **config}, logger=logs.append)
    client.login = lambda: True
    client.logs = logs
    return client


# -- a tiny fake Bakaláři ------------------------------------------------------

_SHELL = """
<style>i { display:inline-block; width:40px; height:20px; border:1px solid #000 }</style>
<i class="ico32-modul-vyuka" onclick="show('vyuka')">V</i>
<i class="ico32-modul-komens" onclick="show('komens')">K</i>
<i class="ico32-modul-komensOdeslane" onclick="show('outbox')">O</i>
<i class="ico32-modul-omluvenky" onclick="show('absence')">A</i>
<div id="content"></div>
<script>
  window.PAGES = {};
  window.DETAILS = {};
  // Module entries render asynchronously, like the AJAX-driven site.
  function show(name) {
    setTimeout(function () {
      document.getElementById('content').innerHTML = window.PAGES[name] || '';
    }, 60);
  }
  function openMsg(id) {
    setTimeout(function () {
      document.getElementById('detail_holder').innerHTML = window.DETAILS[id] || '';
    }, 60);
  }
</script>
"""


def _detail(msg_id: str, day: str = "3.9.2026") -> str:
    html = (_FIXTURES / "komens_sent_detail_hours.html").read_text(encoding="utf-8")
    return html.replace("38389", msg_id).replace("3.9.2026 </span>", f"{day} </span>")


def _outbox(ids: list[str]) -> str:
    rows = "".join(
        f'<div data-msgtype="OMLUVENKA" data-idmsg="{i}" onclick="openMsg(\'{i}\')" '
        f'style="height:20px;border:1px solid #999">excuse {i}</div>' for i in ids)
    return ('<span id="cphmain_obdobiLabel">26.8.2026 - 25.9.2026</span>'
            f'{rows}<div id="detail_holder"></div>')


def _absence_grid() -> str:
    def row(subject, total, missed, pct):
        return ("<tr>"
                f'<td aria-colindex="1">{subject}</td>'
                f'<td aria-colindex="2">{total}</td>'
                f'<td aria-colindex="3">{missed}</td>'
                f'<td aria-colindex="4">{pct}</td>'
                '<td aria-colindex="5"></td><td aria-colindex="6"></td></tr>')
    return "<table>" + row("Matematika", "8", "2", "25,0 %") + row("Fyzika", "6", "0", "0,00 %") + "</table>"


def _site(page, pages: dict, details: dict | None = None) -> None:
    page.set_content(_SHELL)
    page.evaluate("([p, d]) => { window.PAGES = p; window.DETAILS = d; }", [pages, details or {}])


# -- Komens → Odeslané ------------------------------------------------------------

class TestSentExcusesDom:
    def test_reads_every_row_detail(self, page):
        _site(page, {"outbox": _outbox(["501", "502"])},
              {"501": _detail("501", "3.9.2026"), "502": _detail("502", "10.9.2026")})
        client = _client(page)
        parsed = client.fetch_sent_excuses()
        assert parsed is not None, client.logs
        days = sorted({e["starting_day"] for e in parsed})
        assert days == ["03.09.2026", "10.09.2026"]
        assert {e["starting_lesson"] for e in parsed} == {3}
        assert client.sentExcuses_error == ""
        assert client.sentExcuses_from.isoformat() == "2026-08-26"

    def test_empty_outbox_is_a_real_empty_list(self, page):
        _site(page, {"outbox": _outbox([])})
        client = _client(page)
        assert client.fetch_sent_excuses() == []

    def test_missing_module_is_unknown_not_empty(self, page):
        page.set_content("<p>login page</p>")
        client = _client(page)
        assert client.fetch_sent_excuses() is None
        assert client.sentExcuses_error


# -- Absence overview -----------------------------------------------------------------

class TestAbsenceDom:
    def test_parses_grid_after_async_render(self, page):
        _site(page, {"absence": _absence_grid()})
        client = _client(page)
        client.obtain_absence_info()
        assert client.absence_error == ""
        assert client.absencePercentages.get("Matematika") == pytest.approx(25.0)
        assert "Fyzika" in client.absencePercentages

    def test_grid_never_loading_is_flagged(self, page):
        _site(page, {"absence": "<p>Načítání…</p>"})
        client = _client(page)
        client.obtain_absence_info()
        assert client.absencePercentages == {}
        assert client.absence_error


# -- Excuse submit ----------------------------------------------------------------

def _form(on_click: str) -> str:
    return (f'<form onsubmit="return false"><button id="button_poslat" type="button" '
            f'onclick="{on_click}">Odeslat</button></form><div id="msg"></div>')


class TestSubmitDom:
    def test_form_detaching_is_confirmed(self, page):
        page.set_content(_form("setTimeout(() => this.remove(), 80)"))
        client = _client(page)
        assert client._verify_submission() is True
        assert client.last_submit_uncertain is False

    def test_form_staying_open_is_uncertain(self, page):
        page.set_content(_form(""))
        client = _client(page)
        assert client._verify_submission() is False
        assert client.last_submit_uncertain is True

    def test_validation_error_is_certainly_not_sent(self, page):
        page.set_content(_form(
            "document.getElementById('msg').innerHTML="
            "'<div class=&quot;alert-danger&quot;>Chybí text</div>'"))
        client = _client(page)
        assert client._verify_submission() is False
        assert client.last_submit_uncertain is False

    def test_missing_button_is_certainly_not_sent(self, page):
        page.set_content("<p>no form</p>")
        client = _client(page)
        assert client._verify_submission() is False
        assert client.last_submit_uncertain is False


# -- Excuse text editor probe --------------------------------------------------------

_TEXT = "Omluvte prosím absenci dne 18.09.2026."


def _fake_devexpress(html_value: str) -> str:
    return ("<script>window.ASPxClientControl = { GetControlCollection: function () {"
            " return { Get: function (id) { return id === 'cphmain_MessageEditor'"
            f" ? {{ GetHtml: function () {{ return {json.dumps(html_value)}; }} }} : null; }} }}; }} }};"
            "</script>")


def _iframe(text: str) -> str:
    return (f'<iframe id="cphmain_MessageEditor_DesignIFrame" '
            f'srcdoc="<body><p>{text}</p></body>"></iframe>')


class TestEditorProbeDom:
    def test_editor_model_holding_the_text_passes(self, page):
        page.set_content(_fake_devexpress(f"<p>{_TEXT}</p>"))
        assert _client(page)._wait_for_editor_sync(_TEXT, timeout_ms=800) is True

    def test_editor_model_wins_over_what_the_iframe_shows(self, page):
        # The design surface shows the text, the model does not have it:
        # the form would submit empty, so the probe must fail.
        page.set_content(_fake_devexpress("") + _iframe(_TEXT))
        page.wait_for_timeout(100)
        assert _client(page)._wait_for_editor_sync(_TEXT, timeout_ms=500) is False

    def test_without_the_api_the_editor_iframe_is_read(self, page):
        page.set_content(_iframe(_TEXT))
        assert _client(page)._wait_for_editor_sync(_TEXT, timeout_ms=1500) is True

    def test_text_elsewhere_on_the_page_does_not_count(self, page):
        page.set_content(_iframe("") + f"<p>{_TEXT}</p>")
        assert _client(page)._wait_for_editor_sync(_TEXT, timeout_ms=500) is False
