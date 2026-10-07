"""Bakaláři data read over plain HTTP, against a fake web server.

Covers the session (login, rejected login, expired session, cancel),
the WebForms helpers, and every read: outbox, absence, subjects,
substitutions and timetable weeks.
"""

import json
from datetime import date, timedelta
from urllib.parse import parse_qs

import httpx
import pytest

from tests.fake_bakalari import client, dx_reply, week_content

OUTBOX_PAGE = """<html><body><form id="formbaka" method="post" action="./komens.aspx?l=o">
<input type="hidden" name="__VIEWSTATE" value="state-1">
<input type="hidden" name="ctl00$cphmain$hfListType" id="hfListType" value="odeslane">
<span id="cphmain_obdobiLabel">26.8.2026 - 25.9.2026</span>
</form></body></html>"""


def outbox_listing(ids, other=("777",)):
    """The outbox list callback: excuse rows for ``ids`` plus other messages."""
    rows = "".join(f'<table class="message" data-idmsg="{i}" data-msgtype="OMLUVENKA"></table>'
                   for i in ids)
    rows += "".join(f'<table class="message" data-idmsg="{i}" data-msgtype="OBECNA"></table>'
                    for i in other)
    return dx_reply(f'<div class="komens-messages-wrapper">{rows}</div>')


def _excuse_detail(day_from, day_to=None, hour_from=None, hour_to=None):
    detail = {"Kind": "OMLUVENKA", "DateFrom": day_from, "DateTo": day_to or day_from,
              "TimeFrom": "", "TimeTo": ""}
    if hour_from is not None:
        detail["HourFrom"] = {"Caption": str(hour_from)}
        detail["HourTo"] = {"Caption": str(hour_to or hour_from)}
    return detail


def _outbox_routes(ids, details):
    def detail(request):
        return {"success": True, "error": None,
                "data": details[json.loads(request.content)["idmsg"]]}

    return {("GET", "/next/komens.aspx"): OUTBOX_PAGE,
            ("POST", "/next/komens.aspx"): outbox_listing(ids),
            ("POST", "/Komens/GetMessageDataAsync"): detail}


# -- Session -------------------------------------------------------------------

def test_app_root_drops_page_names():
    from strakalari.core.bakalari_http import app_root

    assert app_root("bakaweb.example.test") == "https://bakaweb.example.test"
    assert app_root("https://x.example.test/login") == "https://x.example.test"
    assert app_root("https://x.example.test/bakaweb/next/komens.aspx") == "https://x.example.test/bakaweb"
    assert app_root("") == ""


def test_form_fields_are_what_a_browser_submits():
    from strakalari.core.bakalari_http import form_fields

    html = ('<form id="other"><input name="x" value="1"></form>'
            '<form id="formbaka"><input name="a" value="1"><input type="submit" name="s">'
            '<input type="checkbox" name="c1"><input type="checkbox" name="c2" checked>'
            '<select name="sel"><option value="p">P</option><option value="q" selected>Q</option>'
            '</select><textarea name="t">text</textarea></form>')
    assert form_fields(html) == [("a", "1"), ("c2", "on"), ("sel", "q"), ("t", "text")]


def test_dx_callback_result_reads_the_result_or_raises():
    from strakalari.core.bakalari_http import dx_callback_result

    assert dx_callback_result(dx_reply('<b>"x"</b>\n')) == '<b>"x"</b>\n'
    assert dx_callback_result("1|/*DX*/({'id':0,'result':'a\\'b\\u0041'})") == "a'bA"
    with pytest.raises(RuntimeError):
        dx_callback_result("0|/*DX*/({'id':0,'error':{'message':'boom'}})")
    with pytest.raises(ValueError):
        dx_callback_result("<html>login</html>")


def test_login_posts_the_form_once_and_reuses_the_session():
    bak, server = client({("POST", "/Teaching/Subjects"): {"data": []}})
    bak.fetch_subject_directory()
    bak.fetch_subject_directory()
    assert server.logins == 1


def test_rejected_login_raises_user_error_with_the_reason():
    from strakalari.core.error_report import UserError

    bak, _ = client(bakalari_password="spatne")
    with pytest.raises(UserError) as exc_info:
        bak.login()
    assert "Nesprávné jméno nebo heslo" in str(exc_info.value)


def test_expired_session_logs_in_again_and_retries_once():
    bak, server = client({("POST", "/Teaching/Subjects"): {"data": [
        {"SubjectName": "Matematika", "TeacherName": "Mgr. Jan Novák"}]}})
    bak.login()
    server.expire_session()
    assert bak.fetch_subject_directory() == {"Matematika": "Mgr. Jan Novák"}
    assert server.logins == 2


def test_cancel_stops_before_any_request():
    bak, server = client()
    bak.cancel_requested = True
    with pytest.raises(InterruptedError):
        bak.fetch_sent_excuses()
    assert server.requests == []


def _raw_client(handler):
    from strakalari.core.bakalari_client import BakalariClient
    from tests.fake_bakalari import CONFIG

    return BakalariClient(dict(CONFIG), transport=httpx.MockTransport(handler))


@pytest.mark.parametrize("error, words", [
    (httpx.ConnectError("[Errno 11001] getaddrinfo failed"), ("bakalari.example.test",)),
    (httpx.RemoteProtocolError("Server disconnected"), ("přerušilo", "interrupted")),
])
def test_network_failures_explain_themselves(error, words):
    from strakalari.core.error_report import UserError

    def down(request):
        error.request = request
        raise error

    with pytest.raises(UserError) as exc_info:
        _raw_client(down).login()
    assert any(w in str(exc_info.value) for w in words)
    assert "s." not in str(exc_info.value).split("(")[0]  # no "within N s" for an instant failure


@pytest.mark.parametrize("reply", [
    httpx.Response(404, text="Not Found"),
    httpx.Response(200, text="<html><body>Školní web</body></html>"),
])
def test_wrong_address_says_so(reply):
    from strakalari.core.error_report import UserError

    with pytest.raises(UserError) as exc_info:
        _raw_client(lambda request: reply).login()
    assert "bakalari.example.test" in str(exc_info.value)


def test_server_error_at_login_is_never_a_login():
    from strakalari.core.error_report import UserError

    bak = _raw_client(lambda request: httpx.Response(503, text="Probíhá údržba"))
    with pytest.raises(UserError) as exc_info:
        bak.login()
    assert "HTTP 503" in str(exc_info.value)
    assert bak.logged_in is False


# -- Komens → Odeslané ------------------------------------------------------------

def test_outbox_reads_every_excuse_detail():
    bak, server = client(_outbox_routes(["501", "502"], {
        "501": _excuse_detail("3.9.2026", hour_from=3),
        "502": _excuse_detail("10.9.2026", hour_from=3)}))
    parsed = bak.fetch_sent_excuses()
    assert parsed is not None, bak.logs
    assert sorted({e["starting_day"] for e in parsed}) == ["03.09.2026", "10.09.2026"]
    assert {e["starting_lesson"] for e in parsed} == {3}
    assert bak.sentExcuses_error == ""
    assert bak.sentExcuses_from.isoformat() == "2026-08-26"
    # Only the excuse rows were opened, with the page's own form state.
    assert len(server.calls("POST", "/Komens/GetMessageDataAsync")) == 2
    [callback] = server.calls("POST", "/next/komens.aspx")
    form = parse_qs(callback.content.decode())
    assert form["__CALLBACKID"] == ["ctl00$cphmain$message_list_content"]
    assert form["__VIEWSTATE"] == ["state-1"]


def test_whole_day_excuse_is_one_entry():
    bak, _ = client(_outbox_routes(["501"], {"501": _excuse_detail("3.9.2026", "4.9.2026")}))
    assert bak.fetch_sent_excuses() == [
        {"type": "pure days", "starting_day": "03.09.2026", "ending_day": "04.09.2026"}]


def test_empty_outbox_is_a_real_empty_list():
    bak, _ = client(_outbox_routes([], {}))
    assert bak.fetch_sent_excuses() == []
    assert bak.sentExcuses_error == ""


def test_another_folder_is_unknown_not_empty():
    routes = _outbox_routes([], {})
    routes[("GET", "/next/komens.aspx")] = OUTBOX_PAGE.replace('value="odeslane"', 'value="prijate"')
    bak, _ = client(routes)
    assert bak.fetch_sent_excuses() is None
    assert bak.sentExcuses_error


def test_outbox_list_not_loading_is_unknown_not_empty():
    routes = _outbox_routes([], {})
    routes[("POST", "/next/komens.aspx")] = dx_reply("<div>Chyba</div>")
    bak, _ = client(routes)
    assert bak.fetch_sent_excuses() is None
    assert bak.sentExcuses_error


# -- Absence overview -----------------------------------------------------------------

_ABSENCE_PAGE = """<html><body><script>
var DatesInformations = ko.mapping.fromJS({"DefaultDateFrom": {"DefaultValue": "2026-09-01T00:00:00+02:00"},
  "DefaultDateTo": {"DefaultValue": "2026-09-15T00:00:00+02:00"}});
</script></body></html>"""

_ABSENCE_ROWS = [
    {"Name": "Matematika", "LessonCount": 8, "Count": 2, "Percent": 0.25},
    {"Name": "Fyzika", "LessonCount": 6, "Count": 0, "Percent": 0},
    {"Name": "Celkem", "LessonCount": 14, "Count": 2, "Percent": 0.14},
]


@pytest.mark.parametrize("reply", [{"data": _ABSENCE_ROWS, "totalCount": 3}, _ABSENCE_ROWS])
def test_absence_parses_the_subject_rows(reply):
    bak, server = client({("GET", "/Absence/Continuous"): _ABSENCE_PAGE,
                          ("GET", "/Absence/Continuous/GetAbsenceBySubjects"): reply})
    bak.obtain_absence_info()
    assert bak.absence_error == ""
    assert bak.absencePercentages == {"Matematika": 25.0, "Fyzika": 0.0}
    assert bak.absenceDetails["Matematika"]["missed_hours"] == 2
    [request] = server.calls("GET", "/Absence/Continuous/GetAbsenceBySubjects")
    assert request.url.params["dateFrom"] == "2026-09-01T00:00:00+02:00"


def test_absence_reply_without_rows_is_flagged():
    bak, _ = client({("GET", "/Absence/Continuous"): _ABSENCE_PAGE,
                     ("GET", "/Absence/Continuous/GetAbsenceBySubjects"): {"unexpected": 1}})
    bak.obtain_absence_info()
    assert bak.absencePercentages == {}
    assert bak.absence_error


# -- Substitutions -----------------------------------------------------------------------

def test_substitutions_are_parsed_from_the_week_reply():
    reply = {"success": True, "data": [{"Changes": [{
        "Day": "pondělí 7.9.2026", "HourLabel": "3. hod", "TimeLabel": "9:50 - 10:35",
        "ChangeType": "Canceled", "Description": "Odpadá",
        "ChangeLessonInfo": {"ClassAbbrev": "4.A", "IsClassGroup": True,
                             "SubjectAbbrev": "M", "RoomAbbrev": "104"}}]}]}
    bak, server = client({("POST", "/Timetable/substitutions/dates"): reply})
    assert bak.fetch_substitutions() == [{
        "day": "7.9.2026", "period": 3, "time": "9:50 - 10:35", "badge": "O",
        "info": "4.A | M | 104", "subject_short": "M", "description": "Odpadá"}]
    [request] = server.calls("POST", "/Timetable/substitutions/dates")
    assert set(parse_qs(request.content.decode())) == {"dateFrom", "dateTo"}


def test_failed_substitutions_are_unknown():
    bak, _ = client({("POST", "/Timetable/substitutions/dates"): {"success": False, "error": "x"}})
    assert bak.fetch_substitutions() is None
    assert bak.substitutions_error


# -- Timetable weeks ---------------------------------------------------------------------

def _lesson(day: date) -> dict:
    return {"day": f"{day.day}.{day.month}.{day.year}", "teacher": "Novák",
            "subjecttext": "Matematika", "time": "1 (8:00 - 8:45)"}


def test_each_week_is_requested_by_its_monday():
    def content(request):
        return week_content([_lesson(date.fromisoformat(json.loads(request.content)["date"]))])

    bak, server = client({("POST", "/Timetable/GetContentData"): content},
                         go_back_weeks=2, go_forward_weeks=1)
    bak.fetch_timetable_weeks()
    today = date.today()
    monday = today - timedelta(days=today.weekday())
    asked = [json.loads(r.content) for r in server.calls("POST", "/Timetable/GetContentData")]
    assert [a["date"] for a in asked] == [
        (monday + timedelta(weeks=off)).isoformat() for off in (1, 0, -1)]
    assert {a["term"] for a in asked} == {"cal"}
    assert len(bak.timetable_sources) == 3
    assert monday in bak.timetable_loaded_weeks


def test_dropped_connection_is_retried_once_for_reads():
    state = {"drops": 1}

    def subjects(request):
        if state["drops"]:
            state["drops"] -= 1
            raise httpx.RemoteProtocolError("Server disconnected without sending a response.",
                                            request=request)
        return {"data": [{"SubjectName": "Matematika", "TeacherName": "Mgr. Jan Novák"}]}

    bak, _ = client({("POST", "/Teaching/Subjects"): subjects})
    assert bak.fetch_subject_directory() == {"Matematika": "Mgr. Jan Novák"}


def test_still_valid_session_needs_no_new_login():
    bak, server = client()
    bak.login()
    bak.session.logged_in = False  # e.g. a new run with the same cookies
    bak.login()
    assert server.logins == 1
    assert bak.logged_in is True
