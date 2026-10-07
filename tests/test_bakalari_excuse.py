"""Sending an excuse over HTTP, against a fake Bakaláři.

The post must look like the web form's own "Odeslat" postback, go out at
most once, and count as sent only when Komens → Odeslané shows it. Every
other outcome must say whether it may have gone out (``last_submit_uncertain``).
All names and data are made up.
"""

import json
from datetime import date, datetime
from urllib.parse import parse_qsl

import httpx
import pytest

from tests.fake_bakalari import client, dx_reply

FORM_PAGE = """<html><head>
<link rel="stylesheet" href="../App_Themes/NextBlueTheme/Basicstyl.css?v=1">
<link rel="stylesheet" href="/DXR.axd?r=1_73,1_67-AbCd">
<script src="/DXR.axd?r=1_11,1_12-AbCd" type="text/javascript"></script>
</head><body><form id="formbaka" method="post" action="./komens_zprava.aspx?l=abs">
<input type="hidden" name="__EVENTTARGET" value="">
<input type="hidden" name="__VIEWSTATE" value="vs-1">
<input type="hidden" name="cphmain_cmbMessageType_VI" value="OMLUVENKA">
<input type="text" name="ctl00$cphmain$cmbMessageType" value="Omluvení absence">
<input type="text" name="ctl00$cphmain$cbExcuseWholeDay" value="C">
<input type="text" name="ctl00$cphmain$teachingLesson" value="I">
<input type="text" name="ctl00$cphmain$specificTime" value="I">
<input type="text" name="ctl00$cphmain$excuseFromDate" value="05.10.2026">
<input id="comboExcuseFromPeriod_VI" name="comboExcuseFromPeriod_VI" type="hidden" />
<input type="text" name="ctl00$cphmain$comboExcuseFromPeriod" value="">
<input type="hidden" name="ctl00$cphmain$comboExcuseFromPeriod$DDD$L" value="">
<input type="text" name="ctl00$cphmain$excuseToDate" value="05.10.2026">
<input id="comboExcuseToPeriod_VI" name="comboExcuseToPeriod_VI" type="hidden" />
<input type="text" name="ctl00$cphmain$comboExcuseToPeriod" value="">
<input type="hidden" name="ctl00$cphmain$comboExcuseToPeriod$DDD$L" value="">
<input type="hidden" name="cphmain_cmbRecipientType_VI" value="U">
<input id="cphmain_cmbRecipient_VI" name="cphmain_cmbRecipient_VI" type="hidden" value="UABCD" />
<input type="text" name="ctl00$cphmain$cmbRecipient" value="Novák Jan Mgr.">
<input type="text" name="ctl00$cphmain$cbWithConfirmation" value="I">
<input type="text" name="ctl00$cphmain$cbCcParent" value="I">
<input type="button" name="ctl00$cphmain$button_zrusit" value="Zrušit">
<input type="submit" name="ctl00$cphmain$button_poslat" value="Odeslat" onclick="return sendMessage();" id="button_poslat" />
</form>
<script>ASPx.createControl(ASPxClientHtmlEditor,'cphmain_MessageEditor','MessageEditor',{'callBack':function(arg) { },
'uniqueID':'ctl00$cphmain$MessageEditor','stateObject':{'cssFiles':['../App_Themes/X/styles.css'],'clientState':'ActiveView|6|'}});</script>
</body></html>"""

OUTBOX_PAGE = """<html><body><form id="formbaka" method="post" action="./komens.aspx?l=o">
<input type="hidden" name="__VIEWSTATE" value="state-1">
<input type="hidden" name="ctl00$cphmain$hfListType" id="hfListType" value="odeslane">
<span id="cphmain_obdobiLabel">5.9.2026 - 5.10.2026</span>
</form></body></html>"""

HOURS = {"2026-10-01": [{"Caption": "3", "Begin": 605, "End": 650},
                        {"Caption": "4", "Begin": 660, "End": 705},
                        {"Caption": "6", "Begin": 770, "End": 815}],
         "2026-10-02": [{"Caption": "1", "Begin": 480, "End": 525},
                        {"Caption": "7", "Begin": 820, "End": 865}]}


class Bakalari:
    """Routes of a school whose outbox gains ``sent_detail`` once the form is posted."""

    def __init__(self, sent_detail=None, post_reply=None):
        self.outbox = {"501": {"Kind": "OMLUVENKA", "DateFrom": "18.9.2026", "DateTo": "18.9.2026",
                               "HourFrom": {"Caption": "6"}, "HourTo": {"Caption": "6"}}}
        self.sent_detail = sent_detail
        self.post_reply = post_reply or httpx.Response(302, headers={"Location": "/next/komens.aspx?l=o"})
        self.posts = []

    def form(self, request):
        self.posts.append(dict(parse_qsl(request.content.decode("utf-8"), keep_blank_values=True)))
        if callable(self.post_reply):
            return self.post_reply(request)
        if self.sent_detail is not None:
            self.outbox = {"601": self.sent_detail, **self.outbox}
        return self.post_reply

    def listing(self, request):
        rows = "".join(f'<table data-idmsg="{i}" data-msgtype="OMLUVENKA"></table>' for i in self.outbox)
        return dx_reply(f'<div class="komens-messages-wrapper">{rows}</div>')

    def detail(self, request):
        return {"success": True, "data": self.outbox[json.loads(request.content)["idmsg"]]}

    def routes(self):
        return {("GET", "/next/komens_zprava.aspx"): FORM_PAGE,
                ("POST", "/next/komens_zprava.aspx"): self.form,
                ("GET", "/Komens/ExcuseHours"): lambda r: {"success": True,
                                                           "data": HOURS.get(r.url.params["date"], [])},
                ("GET", "/next/komens.aspx"): OUTBOX_PAGE,
                ("POST", "/next/komens.aspx"): self.listing,
                ("POST", "/Komens/GetMessageDataAsync"): self.detail}


def _lessons(day, first, last):
    return {"Kind": "OMLUVENKA", "DateFrom": day, "DateTo": day,
            "HourFrom": {"Caption": str(first)}, "HourTo": {"Caption": str(last)}}


def _dx_decode(text: str) -> str:
    """Inverse of ``ASPx.Str.EncodeHtml``."""
    for old, new in (("&gt;", ">"), ("&gtx;", "&gt;"), ("&lt;", "<"), ("&ltx;", "&lt;"),
                     ("&quot;", '"'), ("&quotx;", "&quot;"), ("&amp;", "&"), ("&ampx;", "&amp;")):
        text = text.replace(old, new)
    return text


def _state(post: dict, name: str) -> dict:
    return json.loads(_dx_decode(post[name]))


def _editor_html(post: dict) -> str:
    return _dx_decode(_state(post, "ctl00$cphmain$MessageEditor")["html"])


def test_lesson_excuse_posts_the_form_once_and_is_confirmed_by_the_outbox():
    school = Bakalari(sent_detail=_lessons("1.10.2026", 3, 4))
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=4,
                              custom_text="Omluvte prosím absenci.\nJan") is True
    assert bak.last_submit_uncertain is False
    [post] = school.posts
    assert post["ctl00$cphmain$button_poslat"] == "Odeslat"
    assert post["__VIEWSTATE"] == "vs-1"
    assert (post["ctl00$cphmain$cbExcuseWholeDay"], post["ctl00$cphmain$teachingLesson"]) == ("U", "C")
    assert post["ctl00$cphmain$excuseFromDate"] == post["ctl00$cphmain$excuseToDate"] == "01.10.2026"
    assert post["comboExcuseFromPeriod_VI"] == "605" and post["comboExcuseToPeriod_VI"] == "705"
    assert post["ctl00$cphmain$comboExcuseFromPeriod"] == "3 (10:05 - 10:50)"
    assert post["ctl00$cphmain$comboExcuseToPeriod"] == "4 (11:00 - 11:45)"
    assert post["cphmain_cmbRecipient_VI"] == "UABCD"
    assert post["ctl00$cphmain$cbWithConfirmation"] == "C" and post["ctl00$cphmain$cbCcParent"] == "U"
    assert "ctl00$cphmain$button_zrusit" not in post
    assert _state(post, "ctl00$cphmain$excuseFromDate$State")["rawValue"] == "1790812800000"
    assert _editor_html(post) == "<p>Omluvte prosím absenci.</p><p>Jan</p>"
    assert post["DXScript"] == "1_11,1_12"
    assert '"cphmain_teachingLesson":true' in post["DXMVCEditorsValues"]


def test_whole_day_excuse_posts_the_day_range():
    school = Bakalari(sent_detail={"Kind": "OMLUVENKA", "DateFrom": "1.10.2026", "DateTo": "2.10.2026",
                                   "HourFrom": None, "HourTo": None})
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "02.10.2026", custom_text="Nemoc", is_days=True) is True
    [post] = school.posts
    assert (post["ctl00$cphmain$cbExcuseWholeDay"], post["ctl00$cphmain$teachingLesson"]) == ("C", "I")
    assert post["ctl00$cphmain$excuseToDate"] == "02.10.2026"
    # The pickers as the form leaves them: first lesson of day one, last of the last day.
    assert post["comboExcuseFromPeriod_VI"] == "605" and post["comboExcuseToPeriod_VI"] == "865"


def test_lesson_not_in_the_timetable_is_never_posted():
    school = Bakalari()
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=1, end_lesson=1) is False
    assert bak.last_submit_uncertain is False
    assert school.posts == []


def test_unreadable_outbox_before_sending_means_nothing_is_posted():
    school = Bakalari(sent_detail=_lessons("1.10.2026", 3, 3))
    routes = school.routes()
    routes[("POST", "/next/komens.aspx")] = dx_reply("<div>Chyba</div>")
    bak, _ = client(routes)
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3) is False
    assert bak.last_submit_uncertain is False
    assert school.posts == []


def test_post_missing_from_the_outbox_is_uncertain_and_never_repeated():
    school = Bakalari(sent_detail=None)
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3) is False
    assert bak.last_submit_uncertain is True
    assert len(school.posts) == 1


def test_other_excuse_appearing_does_not_confirm_this_one():
    school = Bakalari(sent_detail=_lessons("1.10.2026", 6, 6))
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=4) is False
    assert bak.last_submit_uncertain is True


@pytest.mark.parametrize("error, uncertain", [(httpx.ConnectError, False), (httpx.ReadTimeout, True),
                                             (httpx.RemoteProtocolError, True)])
def test_network_failure_tells_never_sent_from_maybe_sent(error, uncertain):
    def fail(request):
        raise error("network", request=request)

    school = Bakalari(post_reply=fail)
    bak, _ = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3) is False
    assert bak.last_submit_uncertain is uncertain
    assert len(school.posts) == 1


def test_expired_session_on_the_post_is_not_sent_and_not_retried():
    school = Bakalari(post_reply=httpx.Response(302, headers={"Location": "/login"}))
    bak, server = client(school.routes())
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3) is False
    assert bak.last_submit_uncertain is False
    assert len(school.posts) == 1
    assert server.logins == 1


def test_cancel_before_the_post_sends_nothing():
    school = Bakalari(sent_detail=_lessons("1.10.2026", 3, 3))
    bak, _ = client(school.routes())
    bak.cancel_requested = True
    with pytest.raises(InterruptedError):
        bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3)
    assert school.posts == []
    assert bak.last_submit_uncertain is False


def test_dry_run_prepares_the_excuse_without_posting():
    school = Bakalari()
    bak, _ = client(school.routes())
    assert bak.fill_excuse_form("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=4,
                                excuse_type="days and hours") is True
    assert school.posts == []
    assert any("Excuse prepared, not sent" in line and "lessons 3–4" in line for line in bak.logs)


def test_default_text_comes_from_the_templates():
    school = Bakalari(sent_detail=_lessons("1.10.2026", 3, 3))
    bak, _ = client(school.routes(), late_income_excuses=["Pozdní příchod {date}, hodina {lessons}."])
    assert bak.execute_excuse("01.10.2026", "01.10.2026", start_lesson=3, end_lesson=3,
                              excuse_type="income") is True
    assert _editor_html(school.posts[0]).startswith("<p>Pozdní příchod 01.10.2026, hodina 3.</p>")


def test_editor_field_matches_the_browser_byte_for_byte():
    """Captured from the real form: the HTML is encoded twice by DevExpress."""
    from strakalari.core.bakalari_excuse import excuse_postback

    fields = dict(excuse_postback(FORM_PAGE, day_from=date(2026, 10, 1), day_to=date(2026, 10, 1),
                                  whole_day=True, hour_from=None, hour_to=None,
                                  text="a&b \"c\" 'd' <e> čřž\nJan", now=datetime(2026, 10, 5, 22, 14)))
    assert fields["ctl00$cphmain$MessageEditor"] == (
        "{&quot;cssFiles&quot;:[&quot;../App_Themes/X/styles.css&quot;],&quot;clientState&quot;:"
        "&quot;ActiveView|6|&quot;,&quot;validationState&quot;:&quot;&quot;,&quot;html&quot;:&quot;"
        "&amp;lt;p&amp;gt;a&amp;ampx;ampx;b &amp;ampx;quot;c&amp;ampx;quot; &amp;ampx;#39;d&amp;ampx;#39; "
        "&amp;ampx;lt;e&amp;ampx;gt; čřž&amp;lt;/p&amp;gt;&amp;lt;p&amp;gt;Jan&amp;lt;/p&amp;gt;&quot;}")
