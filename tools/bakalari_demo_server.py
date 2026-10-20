"""A fake Bakaláři web server with one demo student, for the Google Play review.

Speaks just enough of the Bakaláři web (the pages and JSON endpoints the app
reads, see docs/BAKALARI_API.md) for Strakaláři to log in and show a timetable,
marks, absence, substitutions and the excuse form. Everything is made up and
always relative to today, so the demo never goes stale. Sent excuses live in
memory only (gone on restart). Standard library only.

Run (plain HTTP on localhost; put nginx with TLS in front of it)::

    python tools/bakalari_demo_server.py --port 8080 --user demo --password demo

then give the reviewers: server ``https://<your host>``, user ``demo``,
password ``demo``.
"""

import argparse
import hmac
import html
import json
import re
import secrets
import threading
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

DAYS_CS = ["pondělí", "úterý", "středa", "čtvrtek", "pátek", "sobota", "neděle"]

# (name, short, teacher, room)
SUBJECTS = {
    "M": ("Matematika", "M", "Mgr. Jana Nováková", "II - (201)"),
    "CJ": ("Český jazyk a literatura", "ČJ", "Mgr. Petr Dvořák", "I - (105)"),
    "AJ": ("Anglický jazyk", "Aj", "Mgr. Eva Svobodová", "III - (310)"),
    "D": ("Dějepis", "D", "PhDr. Karel Černý", "I - (112)"),
    "F": ("Fyzika", "F", "Ing. Martin Procházka", "IV - (401)"),
    "INF": ("Informatika", "Inf", "Mgr. Tomáš Veselý", "PC1 - (022)"),
    "TV": ("Tělesná výchova", "TV", "Mgr. Lenka Horáková", "TEL - tělocvična"),
    "BI": ("Biologie", "Bi", "Mgr. Alena Marešová", "IV - (405)"),
    "CH": ("Chemie", "Ch", "Ing. Jiří Kučera", "IV - (410)"),
    "Z": ("Zeměpis", "Z", "Mgr. Ivana Pokorná", "I - (118)"),
}
CLASS_NAME = "3.A"
GROUP = f"{CLASS_NAME} celá - celá třída"

# period -> (begin, end) in minutes since midnight
BELLS = {1: (480, 525), 2: (535, 580), 3: (600, 645), 4: (655, 700),
         5: (710, 755), 6: (765, 810), 7: (820, 865)}

# Stable timetable: weekday (0 = Monday) -> {period: subject key}
STABLE = {
    0: {1: "M", 2: "CJ", 3: "AJ", 4: "F", 5: "D", 6: "TV"},
    1: {1: "CJ", 2: "INF", 3: "M", 4: "BI", 5: "AJ", 6: "Z"},
    2: {1: "AJ", 2: "M", 3: "F", 4: "CH", 5: "CJ", 6: "D", 7: "TV"},
    3: {1: "BI", 2: "M", 3: "INF", 4: "CJ", 5: "Z", 6: "CH"},
    4: {1: "F", 2: "AJ", 3: "D", 4: "M", 5: "CJ"},
}

THEMES = ["Opakování", "Nové učivo", "Procvičování", "Práce ve skupinách",
          "Čtvrtletní příprava", "Samostatná práce", "Diskuse nad tématem"]

# Weekly changes by week offset from the current week:
# (weekday, period, kind, extra). kinds: Removed, Substitution, RoomChanged
CHANGES = {
    0: [(2, 3, "Removed", None), (3, 2, "Substitution", "Mgr. Radek Beneš"),
        (4, 5, "RoomChanged", "I - (118)")],
    1: [(0, 1, "RoomChanged", "II - (203)"), (1, 4, "Removed", None),
        (3, 3, "Substitution", "Mgr. Radek Beneš")],
}

# subject key -> [(days ago, mark, weight, caption)]
GRADES = {
    "M": [(52, "2", 10, "Písemná práce - funkce"), (31, "1", 5, "Aktivita"), (9, "1", 10, "Test - rovnice")],
    "CJ": [(47, "2", 8, "Diktát"), (25, "3", 10, "Slohová práce"), (6, "2", 5, "Referát")],
    "AJ": [(40, "1", 10, "Unit 2 test"), (18, "1", 5, "Vocabulary quiz"), (3, "2", 10, "Reading")],
    "D": [(35, "2", 10, "Test - 19. století"), (12, "1", 5, "Prezentace")],
    "F": [(44, "3", 10, "Test - kinematika"), (14, "2", 10, "Laboratorní práce"), (2, "2", 5, "Aktivita")],
    "INF": [(28, "1", 10, "Projekt - web"), (5, "1", 5, "Cvičení")],
    "TV": [(30, "1", 3, "Aktivita"), (10, "1", 3, "Aktivita")],
    "BI": [(38, "2", 10, "Test - buňka"), (11, "1", 5, "Referát")],
    "CH": [(33, "3", 10, "Test - soustavy"), (8, "2", 10, "Laboratorní protokol")],
    "Z": [(27, "1", 10, "Test - Evropa"), (7, "2", 5, "Mapa")],
}

# subject key -> (lessons so far, missed lessons)
ABSENCE = {"M": (60, 3), "CJ": (62, 7), "AJ": (58, 2), "D": (31, 4), "F": (58, 12),
           "INF": (28, 0), "TV": (45, 9), "BI": (29, 2), "CH": (57, 6), "Z": (29, 1)}


# -- Dates -------------------------------------------------------------------


def monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def cz_date(day: date) -> str:
    return f"{day.day}.{day.month}.{day.year}"


def day_label(day: date) -> str:
    return f"{cz_date(day)} ({DAYS_CS[day.weekday()]})"


def school_year_start(today: date) -> date:
    return date(today.year if today.month >= 9 else today.year - 1, 9, 1)


def clock(minutes: int) -> str:
    return f"{minutes // 60}:{minutes % 60:02d}"


def time_label(period: int) -> str:
    begin, end = BELLS[period]
    return f"{clock(begin)} - {clock(end)}"


# -- Timetable ---------------------------------------------------------------


def _change_for(day: date, period: int, today: date):
    offset = (monday_of(day) - monday_of(today)).days // 7
    for weekday, per, kind, extra in CHANGES.get(offset, ()):
        if weekday == day.weekday() and per == period:
            return kind, extra
    return None


def _atom(day: date, period: int, key: str, *, perm: bool, today: date) -> dict:
    name, short, teacher, room = SUBJECTS[key]
    hour_index = period + 2
    if perm:
        ident = f"1        {hour_index:02d}T2{key:<3}{period}"
    else:
        ident = f"1{day:%Y%m%d}{hour_index:02d}T2{key:<3}{period}"
    detail = {
        "type": "atom", "subjecttext": name, "subjectshort": short, "teacher": teacher,
        "room": room, "group": GROUP, "theme": "", "notice": "", "changeinfo": "",
        "homeworks": [], "absencetext": "", "hasAbsent": False,
        "day": day_label(day), "time": f"{period} ({time_label(period)})",
        "IdentCode": ident, "absenceType": "NoAbsent", "changeBadgeChar": "",
        "infoChangeCode": "NoChange", "hourIndex": hour_index,
    }
    if perm:
        return detail
    if day < today:
        detail["theme"] = THEMES[(day.toordinal() + period) % len(THEMES)]
    change = _change_for(day, period, today)
    if change is None:
        return detail
    kind, extra = change
    if kind == "Removed":
        return {"type": "removed", "removedinfo": f"Zrušeno ({short}, {teacher})",
                "day": detail["day"], "time": f"{time_label(period)}",
                "changeBadgeChar": "O", "infoChangeCode": "Removed", "hourIndex": hour_index}
    if kind == "Substitution":
        detail.update(teacher=extra, changeBadgeChar="S", infoChangeCode="Substitution",
                      changeinfo=f"Suplování: {extra} ({teacher.split()[-1]})")
    elif kind == "RoomChanged":
        detail.update(room=extra, changeBadgeChar="M", infoChangeCode="RoomChanged",
                      changeinfo=f"Změna místnosti: {extra.split(' ')[0]} ({room.split(' ')[0]})")
    return detail


def timetable_week(term: str, ref: date, today: date) -> dict:
    """``/Timetable/GetContentData`` content: Monday-Friday of ``ref``'s week."""
    monday = monday_of(ref)
    days = []
    for weekday in range(5):
        day = monday + timedelta(days=weekday)
        hours = []
        for period, key in sorted(STABLE[weekday].items()):
            atom = _atom(day, period, key, perm=term == "perm", today=today)
            hours.append({"Atoms": [{"TooltipDetails": json.dumps(atom, ensure_ascii=False)}]})
        days.append({"Hours": hours, "DayAbbrev": DAYS_CS[weekday][:2], "Date": day.isoformat(),
                     "DayOff": False})
    return {"TimetableDataAvailable": True, "Days": days, "UserType": "Student"}


def substitution_weeks(date_from: date, date_to: date, today: date) -> list:
    """``/Timetable/substitutions/dates`` data: weeks with changes in range."""
    weeks = []
    day = monday_of(date_from)
    while day <= date_to:
        changes = []
        for weekday in range(5):
            lesson_day = day + timedelta(days=weekday)
            if not date_from <= lesson_day <= date_to:
                continue
            for period, key in sorted(STABLE[weekday].items()):
                change = _change_for(lesson_day, period, today)
                if change is None:
                    continue
                kind, extra = change
                name, short, teacher, room = SUBJECTS[key]
                canceled = kind == "Removed"
                if canceled:
                    description = f"Zrušeno ({short}, {teacher})"
                elif kind == "Substitution":
                    description = f"Suplování: {extra} ({teacher.split()[-1]})"
                else:
                    description = f"Změna místnosti: {extra.split(' ')[0]} ({room.split(' ')[0]})"
                changes.append({
                    "Day": f"{DAYS_CS[weekday]} {cz_date(lesson_day)}",
                    "ChangeType": "Canceled" if canceled else kind,
                    "HourLabel": str(period), "TimeLabel": time_label(period),
                    "Description": description,
                    "BeginTimeLabel": clock(BELLS[period][0]), "EndTimeLabel": clock(BELLS[period][1]),
                    "ChangeDisplayType": "OriginalTeacher", "IsSupervision": False,
                    "ChangeLessonInfo": {
                        "ClassAbbrev": CLASS_NAME, "GroupAbbrev": None, "IsClassGroup": True,
                        "SubjectAbbrev": short, "RoomAbbrev": (extra if kind == "RoomChanged" else room).split(" ")[0],
                    },
                })
        if changes:
            weeks.append({"Title": f"{cz_date(day)} - {cz_date(day + timedelta(days=4))}", "Changes": changes})
        day += timedelta(days=7)
    return weeks


# -- Pages -------------------------------------------------------------------

LOGIN_PAGE = """<!DOCTYPE html>
<html lang="cs"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Bakaláři - demo</title></head><body>
<h1>Bakaláři (demo)</h1>
<p>Ukázkový server pro Strakaláři. Přihlášení: demo / demo.</p>
<form id="formlogin" method="post" action="Login">
<input type="hidden" name="returnUrl" value="">
<input id="username" name="username" type="text" value="">
<input id="password" name="password" type="password">
<button type="submit" name="login" formaction="/Login" formmethod="post" id="loginButton">Přihlásit</button>
</form>{error}</body></html>"""

SHELL = """<!DOCTYPE html>
<html lang="cs"><head><meta charset="utf-8"><title>{title}</title></head><body>
<h1>{title}</h1>{body}</body></html>"""


def shell(title: str, body: str) -> str:
    return SHELL.format(title=html.escape(title), body=body)


def grades_page(today: date) -> str:
    marks = []
    n = 0
    for key, rows in GRADES.items():
        for days_ago, mark, weight, caption in rows:
            n += 1
            given = today - timedelta(days=days_ago)
            blob = {"id": f"{1000 + n}", "nazev": SUBJECTS[key][0], "MarkText": mark, "vaha": int(weight),
                    "udel_datum": cz_date(given), "caption": caption, "poznamkakzobrazeni": "",
                    "strdatum": cz_date(given), "IsNew": False, "MarkTooltip": ""}
            marks.append(blob)
    planned = {"id": "1999", "nazev": SUBJECTS["M"][0], "MarkText": "?", "vaha": 10,
               "udel_datum": cz_date(today + timedelta(days=6)), "caption": "Čtvrtletní písemná práce",
               "strdatum": cz_date(today + timedelta(days=6)), "IsNew": False,
               "MarkTooltip": "plánovaná klasifikace"}
    cells = "".join(
        f"<div class=\"mark\" data-clasif='{json.dumps(m, ensure_ascii=False)}'>{html.escape(m['MarkText'])}</div>"
        for m in marks + [planned])
    return shell("Klasifikace - průběžná (prubzna.aspx)", cells)


def absence_page(today: date) -> str:
    info = {"DefaultDateFrom": {"DefaultValue": f"{school_year_start(today).isoformat()}T00:00:00+02:00"},
            "DefaultDateTo": {"DefaultValue": f"{today.isoformat()}T00:00:00+02:00"}}
    script = f"<script>DatesInformations = ko.mapping.fromJS({json.dumps(info)});</script>"
    return shell("Absence - průběžná", script)


def absence_rows() -> list:
    return [{"Name": SUBJECTS[key][0], "LessonCount": total, "Count": missed,
             "Percent": round(missed / total, 4)} for key, (total, missed) in ABSENCE.items()]


def subject_rows() -> list:
    return [{"Id": i + 1, "SubjectName": name, "TeacherName": teacher, "Email": "", "Web": "",
             "HomePhone": "", "MobilePhone": "", "SchoolPhone": ""}
            for i, (name, _short, teacher, _room) in enumerate(SUBJECTS.values())]


# -- Komens (excuses) --------------------------------------------------------

RECIPIENT_CODE = "UDEMO1"
RECIPIENT_NAME = "Mgr. Jana Nováková"
MAX_OUTBOX = 200


class Outbox:
    """Sent excuses of the demo account, in memory."""

    def __init__(self, today: date):
        self._lock = threading.Lock()
        self._next = 4_100_001
        self.messages: list = []
        # A couple of old excuses, so the folder is not empty.
        self.add(today - timedelta(days=21), today - timedelta(days=21), None, None,
                 "Omluvte prosím absenci.", sent=today - timedelta(days=20))
        self.add(today - timedelta(days=9), today - timedelta(days=9), (3, "M"), (4, "F"),
                 "Omluvte prosím absenci.", sent=today - timedelta(days=8))

    def add(self, day_from, day_to, hour_from, hour_to, text, sent=None) -> str:
        """``hour_from`` / ``hour_to``: ``(period, subject key)`` or None (whole days)."""
        with self._lock:
            msg_id = str(self._next)
            self._next += 1
            self.messages.append({"id": msg_id, "from": day_from, "to": day_to, "hour_from": hour_from,
                                  "hour_to": hour_to, "text": text,
                                  "sent": datetime.combine(sent or date.today(), datetime.min.time())
                                  if sent else datetime.now()})
            del self.messages[:-MAX_OUTBOX]
            return msg_id

    def list_html(self) -> str:
        with self._lock:
            rows = sorted(self.messages, key=lambda m: m["sent"], reverse=True)
        tables = "".join(
            f'<table data-idmsg="{m["id"]}" data-sortdate="0:{m["sent"]:%Y-%m-%dT%H:%M:%S}" '
            f'data-msgtype="OMLUVENKA" data-read="true"><tr><td>Omluvenka {cz_date(m["from"])}</td></tr></table>'
            for m in rows)
        return f'<div class="komens-messages-wrapper">{tables}</div>'

    def detail(self, msg_id: str):
        with self._lock:
            found = next((m for m in self.messages if m["id"] == msg_id), None)
        if found is None:
            return None

        def hour(spec):
            if not spec:
                return None
            period, _key = spec
            begin, end = BELLS[period]
            return {"Caption": str(period), "Begin": f"{begin // 60:02d}:{begin % 60:02d}:00",
                    "End": f"{end // 60:02d}:{end % 60:02d}:00", "BeginTime": clock(begin),
                    "EndTime": clock(end), "BeginTimeValue": begin, "EndTimeValue": end,
                    "Start": begin, "Duration": end - begin, "HourIndex": period + 2}

        hour_from, hour_to = hour(found["hour_from"]), hour(found["hour_to"])
        return {"Id": found["id"], "Kind": "OMLUVENKA", "Title": "Omluvenka", "MessageText": found["text"],
                "Cas": found["sent"].strftime("%d.%m.%Y %H:%M"), "DateFrom": cz_date(found["from"]),
                "DateTo": cz_date(found["to"]), "HourFrom": hour_from, "HourTo": hour_to,
                "TimeFrom": hour_from["BeginTime"] if hour_from else "",
                "TimeTo": hour_to["EndTime"] if hour_to else ""}


def outbox_page() -> str:
    return shell("Komens - odeslané", f"""<form id="formbaka" method="post" action="komens.aspx?l=o">
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="demo">
<input type="hidden" name="ctl00$cphmain$hfListType" id="hfListType" value="odeslane">
<span id="cphmain_obdobiLabel">{cz_date(date.today() - timedelta(days=30))} - {cz_date(date.today())}</span>
</form>""")


def excuse_form_page() -> str:
    return shell("Komens - omluvení absence", f"""<form id="formbaka" method="post" action="komens_zprava.aspx?l=abs">
<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="demo">
<input type="hidden" id="cphmain_cmbRecipientType_VI" name="cphmain_cmbRecipientType_VI" value="U">
<input type="hidden" id="cphmain_cmbRecipient_VI" name="cphmain_cmbRecipient_VI" value="{RECIPIENT_CODE}">
<input type="text" name="ctl00$cphmain$cmbRecipient" value="{html.escape(RECIPIENT_NAME)}">
<input type="hidden" name="ctl00$cphmain$cbExcuseWholeDay" value="I">
<input type="hidden" name="ctl00$cphmain$teachingLesson" value="I">
<input type="text" name="ctl00$cphmain$excuseFromDate" value="">
<input type="text" name="ctl00$cphmain$excuseToDate" value="">
<input type="hidden" name="comboExcuseFromPeriod_VI" value="">
<input type="hidden" name="comboExcuseToPeriod_VI" value="">
<input type="submit" name="ctl00$cphmain$button_poslat" value="Odeslat" id="button_poslat">
</form>""")


def excuse_hours(day: date) -> list:
    if day.weekday() > 4:
        return []
    return [{"Caption": str(p), "Begin": BELLS[p][0], "End": BELLS[p][1]} for p in sorted(STABLE[day.weekday()])]


def parse_cz(value: str):
    try:
        return datetime.strptime(value.strip(), "%d.%m.%Y").date()
    except ValueError:
        return None


# -- HTTP --------------------------------------------------------------------

MAX_BODY = 1_000_000


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, user: str, password: str):
        super().__init__(address, Handler)
        self.user, self.password = user, password
        self.sessions: set = set()
        self.outbox = Outbox(date.today())


class Handler(BaseHTTPRequestHandler):
    server_version = "BakalariDemo"
    protocol_version = "HTTP/1.1"

    # -- plumbing

    def log_message(self, fmt, *args):  # one short line per request
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def _send(self, status: int, body, content_type: str, headers: dict | None = None) -> None:
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def html(self, text: str, status: int = 200, headers: dict | None = None) -> None:
        self._send(status, text, "text/html; charset=utf-8", headers)

    def json_reply(self, data) -> None:
        self._send(200, json.dumps({"success": True, "error": None, "data": data}, ensure_ascii=False),
                   "application/json; charset=utf-8")

    def redirect(self, location: str, headers: dict | None = None) -> None:
        self._send(302, "", "text/plain", {"Location": location, **(headers or {})})

    def body(self) -> bytes:
        try:
            length = min(int(self.headers.get("Content-Length") or 0), MAX_BODY)
        except ValueError:
            length = 0
        return self.rfile.read(length) if length else b""

    def form(self) -> dict:
        return parse_qs(self.body().decode("utf-8", "replace"), keep_blank_values=True)

    def cookie_token(self) -> str:
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == "BakaAuth":
                return value
        return ""

    def logged_in(self) -> bool:
        return self.cookie_token() in self.server.sessions

    # -- routing

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlsplit(self.path)
        path, query = url.path.rstrip("/") or "/", parse_qs(url.query)
        lower = path.lower()
        if lower == "/":
            return self.redirect("/dashboard" if self.logged_in() else "/login")
        if lower == "/login":
            if self.logged_in():
                return self.redirect("/dashboard")
            return self.html(LOGIN_PAGE.format(error=""))
        if not self.logged_in():
            return self.redirect("/login")
        today = date.today()
        if lower == "/dashboard":
            return self.html(shell("Přehled", "<p>Demo student, " + CLASS_NAME + "</p>"))
        if lower == "/next/prubzna.aspx":
            return self.html(grades_page(today))
        if lower == "/absence/continuous":
            return self.html(absence_page(today))
        if lower == "/absence/continuous/getabsencebysubjects":
            return self.json_reply(absence_rows())
        if lower == "/next/komens.aspx":
            return self.html(outbox_page())
        if lower == "/next/komens_zprava.aspx":
            return self.html(excuse_form_page())
        if lower == "/komens/excusehours":
            day = parse_cz((query.get("date") or [""])[0]) or _iso_date((query.get("date") or [""])[0])
            return self.json_reply(excuse_hours(day) if day else [])
        return self.redirect("/dashboard?e=" + "Po%C5%BEadovan%C3%A1%20str%C3%A1nka%20nebyla%20nalezena")

    def do_POST(self):
        url = urlsplit(self.path)
        lower = (url.path.rstrip("/") or "/").lower()
        if lower == "/login":
            return self.login()
        if not self.logged_in():
            self.body()
            return self.redirect("/login")
        today = date.today()
        if lower == "/timetable/getcontentdata":
            payload = _json_body(self.body())
            ref = _iso_date(str(payload.get("date") or "")) or today
            term = "perm" if payload.get("term") == "perm" else "cal"
            return self.json_reply(timetable_week(term, ref, today))
        if lower == "/teaching/subjects":
            self.body()
            return self.json_reply(subject_rows())
        if lower == "/timetable/substitutions/dates":
            fields = self.form()
            start = _utc_to_local_date((fields.get("dateFrom") or [""])[0]) or monday_of(today)
            end = _utc_to_local_date((fields.get("dateTo") or [""])[0]) or today + timedelta(days=14)
            return self.json_reply(substitution_weeks(start, end, today))
        if lower == "/next/komens.aspx":
            self.body()
            result = self.server.outbox.list_html()
            return self._send(200, "0|/*DX*/({'id':0,'result':" + json.dumps(result) + "})",
                              "text/plain; charset=utf-8")
        if lower == "/komens/getmessagedataasync":
            detail = self.server.outbox.detail(str(_json_body(self.body()).get("idmsg") or ""))
            if detail is None:
                return self._send(200, json.dumps({"success": False, "error": "Zpráva nenalezena", "data": None}),
                                  "application/json; charset=utf-8")
            return self.json_reply(detail)
        if lower == "/next/komens_zprava.aspx":
            return self.send_excuse()
        self.body()
        return self.redirect("/dashboard")

    def login(self):
        fields = self.form()
        user = (fields.get("username") or [""])[0]
        password = (fields.get("password") or [""])[0]
        ok = (hmac.compare_digest(user.encode(), self.server.user.encode())
              and hmac.compare_digest(password.encode(), self.server.password.encode()))
        if not ok:
            error = '<div class="login-error">Nesprávné jméno nebo heslo</div>'
            return self.html(LOGIN_PAGE.format(error=error))
        token = secrets.token_hex(16)
        self.server.sessions.add(token)
        if len(self.server.sessions) > 500:  # a demo, not a bank: keep memory bounded
            self.server.sessions.pop()
        self.redirect("/dashboard", {"Set-Cookie": f"BakaAuth={token}; Path=/; HttpOnly; SameSite=Lax"})

    def send_excuse(self):
        """The excuse form's postback: store the excuse in the outbox."""
        fields = {k: v[0] for k, v in self.form().items() if v}
        day_from = parse_cz(fields.get("ctl00$cphmain$excuseFromDate", ""))
        day_to = parse_cz(fields.get("ctl00$cphmain$excuseToDate", ""))
        if day_from is None or day_to is None or day_to < day_from:
            return self.html(excuse_form_page(), 200)
        whole_day = fields.get("ctl00$cphmain$cbExcuseWholeDay") == "C"
        hour_from = hour_to = None
        if not whole_day:
            hour_from = _period_at(day_from, fields.get("comboExcuseFromPeriod_VI", ""), "begin")
            hour_to = _period_at(day_to, fields.get("comboExcuseToPeriod_VI", ""), "end")
            if hour_from is None or hour_to is None:
                return self.html(excuse_form_page(), 200)
        text = re.sub(r"<[^>]+>", " ", html.unescape(html.unescape(fields.get("ctl00$cphmain$MessageEditor", ""))))
        self.server.outbox.add(day_from, day_to, hour_from, hour_to, " ".join(text.split())[:500] or "Omluvenka")
        self.redirect("/next/komens.aspx?l=o")


def _json_body(raw: bytes) -> dict:
    try:
        value = json.loads(raw.decode("utf-8") or "{}")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def _iso_date(text: str):
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def _utc_to_local_date(text: str):
    """``2026-10-04T22:00:00.000Z`` -> the local day (rounded to the nearest midnight)."""
    try:
        moment = datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return (moment + timedelta(hours=12)).date()


def _period_at(day: date, minutes: str, edge: str):
    """``(period, subject key)`` of the lesson on ``day`` that begins/ends at ``minutes``."""
    if day.weekday() > 4 or not minutes.strip().isdigit():
        return None
    index = 0 if edge == "begin" else 1
    for period, key in STABLE[day.weekday()].items():
        if BELLS[period][index] == int(minutes):
            return period, key
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--user", default="demo")
    parser.add_argument("--password", default="demo")
    args = parser.parse_args()
    server = Server((args.host, args.port), args.user, args.password)
    print(f"Bakaláři demo on http://{args.host}:{args.port}  login: {args.user} / {args.password}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
