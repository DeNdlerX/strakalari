"""Grades (průběžná klasifikace) extractor + BakalariClient wiring.

Covers the port of the friend's Selenium ``get_grades`` snippet:
``data-clasif`` parsing, per-subject grouping, date sorting, the grades
page fetched over HTTP.
"""
import sys

sys.path.insert(0, ".")

from strakalari.core.extractors.bakalari import extract_grades


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


def _grades_page(marks_html: str) -> str:
    return ('<html><body><form id="formbaka" method="post" action="./prubzna.aspx">'
            f"{marks_html}</form></body></html>")


def test_get_grades_fetches_parses_and_sorts():
    from tests.fake_bakalari import client as fake_client

    html = (
        _mark("Matematika", "3", 10, "12.09.2026")
        + _mark("Matematika", "1", 10, "05.09.2026")
        + _mark("Fyzika", "2", 5, "06.09.2026")
    )
    client, server = fake_client({("GET", "/next/prubzna.aspx"): _grades_page(html)})
    data = client.get_grades()
    assert [m["Date"] for m in data["Matematika"]] == ["05.09.2026", "12.09.2026"]
    assert data["Fyzika"] == [{"Grade": "2", "Weight": 5, "Date": "06.09.2026"}]
    assert client.grades == data
    assert client.grades_error == ""
    assert len(server.calls("GET", "/next/prubzna.aspx")) == 1


def test_get_grades_failure_keeps_error_without_raising():
    import httpx

    from tests.fake_bakalari import client as fake_client

    client, _ = fake_client({("GET", "/next/prubzna.aspx"): httpx.Response(500)})
    assert client.get_grades() == {}
    assert "HTTP 500" in client.grades_error


def test_get_grades_empty_other_page_is_an_error_not_no_marks():
    from tests.fake_bakalari import client as fake_client

    client, _ = fake_client({("GET", "/next/prubzna.aspx"): "<html>Chyba serveru</html>"})
    assert client.get_grades() == {}
    assert client.grades_error
