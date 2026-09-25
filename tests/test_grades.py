"""Grades (průběžná klasifikace) extractor + BakalariClient wiring.

Covers the port of the friend's Selenium ``get_grades`` snippet to the
Playwright client: ``data-clasif`` parsing, per-subject grouping, date
sorting, and the ``#c-p-bn`` cookies dismissal.
"""
import sys

sys.path.insert(0, ".")

from strakalari.core.extractors.bakalari import extract_grades
from strakalari.core.bakalari_client import BakalariClient


def _mark(subject, grade, weight, date):
    import html as _html
    import json as _json

    blob = _json.dumps(
        {"nazev": subject, "MarkText": grade, "vaha": weight, "udel_datum": date},
        ensure_ascii=False,
    )
    return f'<div data-clasif="{_html.escape(blob, quote=True)}"></div>'


class TestExtractGrades:
    def test_empty_and_none_input(self):
        assert extract_grades("") == {}
        assert extract_grades(None) == {}

    def test_groups_by_subject(self):
        html = _mark("Matematika", "1", 10, "5.9.2026") + _mark("Fyzika", "2", 5, "6.9.2026")
        data = extract_grades(html)
        assert set(data) == {"Matematika", "Fyzika"}
        assert data["Matematika"] == [{"Grade": "1", "Weight": 10, "Date": "5.9.2026"}]
        assert data["Fyzika"] == [{"Grade": "2", "Weight": 5, "Date": "6.9.2026"}]

    def test_sorts_each_subject_by_date(self):
        # Page groups by subject but leaves dates unordered — output must
        # be oldest-first per subject.
        html = (
            _mark("Matematika", "3", 10, "12.09.2026")
            + _mark("Matematika", "1", 10, "05.09.2026")
            + _mark("Matematika", "2", 5, "08.09.2026")
        )
        dates = [m["Date"] for m in extract_grades(html)["Matematika"]]
        assert dates == ["05.09.2026", "08.09.2026", "12.09.2026"]

    def test_skips_malformed_and_incomplete(self):
        html = (
            '<div data-clasif="{not json}"></div>'
            + '<div data-clasif="{&quot;MarkText&quot;: &quot;1&quot;}"></div>'
            + '<div data-clasif="{&quot;nazev&quot;: &quot;Chemie&quot;}"></div>'
            + _mark("Biologie", "1", 8, "1.9.2026")
        )
        data = extract_grades(html)
        assert data == {"Biologie": [{"Grade": "1", "Weight": 8, "Date": "1.9.2026"}]}

    def test_unparseable_dates_sort_last(self):
        html = _mark("Dějepis", "2", 5, "???") + _mark("Dějepis", "1", 5, "1.9.2026")
        dates = [m["Date"] for m in extract_grades(html)["Dějepis"]]
        assert dates == ["1.9.2026", "???"]

    def test_optional_details_kept_when_present(self):
        import html as _html2
        import json as _json2

        blob = _json2.dumps(
            {"nazev": "Finanční gramotnost", "MarkText": "?", "vaha": 2,
             "udel_datum": "13.9.2026", "strdatum": "15.1.2027", "id": "BNXS=6=2=V",
             "caption": "pololetní test", "poznamkakzobrazeni": "", "IsNew": True,
             "PointsText": "", "MarkTooltip": "plánovaná klasifikace"},
            ensure_ascii=False,
        )
        html = f'<div data-clasif="{_html2.escape(blob, quote=True)}"></div>'
        mark = extract_grades(html)["Finanční gramotnost"][0]
        assert mark == {
            "Grade": "?", "Weight": 2, "Date": "13.9.2026", "Id": "BNXS=6=2=V",
            "Caption": "pololetní test", "TestDate": "15.1.2027", "New": True,
            "Planned": True,
        }

    def test_nested_braces_and_brace_in_string(self):
        import html as _html2
        import json as _json2

        blob = _json2.dumps(
            {"nazev": "Matematika", "MarkText": "1", "vaha": 10,
             "udel_datum": "5.9.2026", "extra": {"note": "a}b"}},
            ensure_ascii=False,
        )
        html = f'<div data-clasif="{_html2.escape(blob, quote=True)}"></div>'
        data = extract_grades(html)
        assert data["Matematika"] == [{"Grade": "1", "Weight": 10, "Date": "5.9.2026"}]


class _Btn:
    def __init__(self, page, selector):
        self._page = page
        self._selector = selector

    @property
    def first(self):
        return self

    def wait_for(self, state=None, timeout=None):
        if state == "visible" and self._selector == "#c-p-bn" and not self._page.banner_visible:
            raise Exception("timeout")
        return True

    def click(self, timeout=None, force=False):
        if self._selector == "#c-p-bn":
            self._page.banner_visible = False
            self._page.dismissed.append(self._selector)
            return True
        self._page.clicked.append(self._selector)
        return True

    def evaluate(self, js):
        if self._selector == "#c-p-bn":
            self._page.banner_visible = False
        return True

    def count(self):
        if self._selector == "#c-p-bn":
            return 1
        return 1

    def is_visible(self):
        if self._selector == "#c-p-bn":
            return self._page.banner_visible
        return True


class _CookiesPage:
    def __init__(self, banner_visible=True):
        self.banner_visible = banner_visible
        self.dismissed = []
        self.clicked = []

    def locator(self, selector):
        return _Btn(self, selector)


class _CookiesBM:
    def __init__(self, page):
        self.page = page

    def random_sleep(self, s):
        pass


def _client(page):
    return BakalariClient(
        _CookiesBM(page),
        {"bakalari_url": "https://example.bakalari.cz", "element_wait_s": 2},
        logger=lambda m: None,
    )


def test_dismiss_cookies_clicks_banner():
    page = _CookiesPage(banner_visible=True)
    assert _client(page)._dismiss_cookies() is True
    assert page.dismissed == ["#c-p-bn"]
    assert page.banner_visible is False


def test_dismiss_cookies_no_banner_is_noop():
    page = _CookiesPage(banner_visible=False)
    assert _client(page)._dismiss_cookies() is True
    assert page.dismissed == []


def test_dismiss_cookies_never_raises_without_browser():
    client = BakalariClient(
        type("BM", (), {"page": None})(),
        {"bakalari_url": "https://example.bakalari.cz"},
        logger=lambda m: None,
    )
    assert client._dismiss_cookies() is True


class _GradesLoc:
    def __init__(self, page, selector):
        self._page = page
        self._selector = selector

    @property
    def first(self):
        return self

    def wait_for(self, state=None, timeout=None):
        if self._selector == "#username":
            raise Exception("no login form")
        return True

    def click(self, timeout=None, force=False):
        self._page.clicked.append(self._selector)
        return True

    def press_sequentially(self, value, delay=10):
        pass

    def evaluate(self, js):
        return True

    def count(self):
        if self._selector == "#c-p-bn":
            return 0
        return 1

    def is_visible(self):
        return self._selector != "#c-p-bn"


class _GradesPage:
    url = "https://example.bakalari.cz"

    def __init__(self, html):
        self._html = html
        self.clicked = []

    def goto(self, url, timeout=None, wait_until=None):
        pass

    def locator(self, selector):
        return _GradesLoc(self, selector)

    def wait_for_function(self, js, timeout=None):
        return True

    def wait_for_timeout(self, ms):
        pass

    def content(self):
        return self._html


class _GradesBM:
    def __init__(self, page):
        self.page = page

    def random_sleep(self, s):
        pass


def test_get_grades_navigates_parses_and_sorts():
    html = (
        _mark("Matematika", "3", 10, "12.09.2026")
        + _mark("Matematika", "1", 10, "05.09.2026")
        + _mark("Fyzika", "2", 5, "06.09.2026")
    )
    page = _GradesPage(html)
    client = BakalariClient(
        _GradesBM(page),
        {"bakalari_url": "https://example.bakalari.cz",
         "bakalari_username": "user", "bakalari_password": "pw",
         "element_wait_s": 2},
        logger=lambda m: None,
    )
    data = client.get_grades()
    assert [m["Date"] for m in data["Matematika"]] == ["05.09.2026", "12.09.2026"]
    assert data["Fyzika"] == [{"Grade": "2", "Weight": 5, "Date": "06.09.2026"}]
    assert client.grades == data
    assert client.grades_error == ""
    assert ".ico32-modul-klasifikace" in page.clicked
    assert ".ico32-modul-klasifikacePrubezna" in page.clicked


def test_get_grades_failure_keeps_error_without_raising():
    class _BrokenPage(_GradesPage):
        def content(self):
            raise RuntimeError("network down")

    client = BakalariClient(
        _GradesBM(_BrokenPage("")),
        {"bakalari_url": "https://example.bakalari.cz",
         "bakalari_username": "user", "bakalari_password": "pw",
         "element_wait_s": 2},
        logger=lambda m: None,
    )
    assert client.get_grades() == {}
    assert "RuntimeError" in client.grades_error
