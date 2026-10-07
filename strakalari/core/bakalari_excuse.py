"""Bakaláři excuse form (Komens → Omluvení absence) over plain HTTP.

Sends exactly the postback the web form sends when "Odeslat" is clicked:
the form's own fields from its raw HTML plus the client state its
DevExpress controls add in the browser (dates, lesson pickers, the text
editor). The post is one request, never retried; only the Komens outbox
confirms that it went out.
"""

import json
import re
import time
from datetime import date, datetime, timedelta

from .helpers import format_excuse_template

_FORM_PATH = "/next/komens_zprava.aspx?l=abs"
_HOURS_PATH = "/Komens/ExcuseHours"
_SEND_BUTTON = ("ctl00$cphmain$button_poslat", "Odeslat")
_P = "ctl00$cphmain$"

#: Popup / dropdown / list states as a freshly loaded, untouched form posts them.
_CLOSED = {"windowsState": "0:0:-1:0:0:0:-10000:-10000:1:0:0:0"}
_LIST = {"CustomCallback": ""}
_EDITOR_DEFAULTS = (["../App_Themes/NextBlueTheme/HtmlEditor/styles.css"],
                    "ActiveView|6|DesignCurrentWidth|3|100CurrentHeight|3|300IsPercentWidth|1|1"
                    "ForeColorPalette|0|Ribbon|0|")


def _minutes_text(minutes: int) -> str:
    return f"{minutes // 60}:{minutes % 60:02d}"


def _hour_text(item: dict) -> str:
    """Combo text of one lesson, as the form shows it: ``3 (10:05 - 10:50)``."""
    times = f"({_minutes_text(item['Begin'])} - {_minutes_text(item['End'])})"
    caption = str(item.get("Caption") or "").strip()
    return f"{caption} {times}" if caption else times


def _lesson(items: list, number) -> dict | None:
    for item in items or []:
        if str(item.get("Caption") or "").strip() == str(number).strip():
            return item
    return None


def text_to_html(text: str) -> str:
    """The editor HTML of plain ``text`` (one paragraph per line, escaped
    the way the editor's ``GetHtml`` returns it)."""
    def esc(line: str) -> str:
        for old, new in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
                         ('"', "&quot;"), ("'", "&#39;")):
            line = line.replace(old, new)
        return line or "&nbsp;"

    return "".join(f"<p>{esc(line)}</p>" for line in str(text or "").splitlines() or [""])


def _js_date(moment) -> str:
    """``new Date(…)`` as DevExpress writes it into ``DXMVCEditorsValues``."""
    if isinstance(moment, datetime):
        return (f"new Date({moment.year},{moment.month - 1},{moment.day},{moment.hour},"
                f"{moment.minute},{moment.second},{moment.microsecond // 1000})")
    return f"new Date({moment.year},{moment.month - 1},{moment.day})"


def _date_state(day: date) -> dict:
    # Date editors keep the calendar date as UTC midnight in milliseconds.
    return {"rawValue": str((day - date(1970, 1, 1)).days * 86_400_000), "useMinDateInsteadOfNull": False}


def _calendar_state(day: date) -> dict:
    shown = f"{day:%m/%d/%Y}"
    return {"visibleDate": shown, "initialVisibleDate": shown, "selectedDates": [shown]}


def _page_resources(page_html: str) -> tuple:
    """``(DXScript, DXCss)``: the resources the loaded page holds, as the
    DevExpress client reports them with every post."""
    scripts = []
    for match in re.finditer(r'<script[^>]*src="[^"]*DXR\.axd\?r=([^"&]+)"', page_html):
        scripts.extend(match.group(1).rsplit("-", 1)[0].split(","))
    css = []
    for match in re.finditer(r'<link[^>]*href="([^"]+)"', page_html):
        href = match.group(1).replace("&amp;", "&")
        resource = re.search(r"DXR\.axd\?r=([^&]+)", href)
        css.extend(resource.group(1).rsplit("-", 1)[0].split(",") if resource else [href])
    return ",".join(scripts), ",".join(css)


def _editor_defaults(page_html: str) -> tuple:
    """``(cssFiles, clientState)`` of the text editor's initial state object."""
    match = re.search(r"'uniqueID':'ctl00\$cphmain\$MessageEditor','stateObject':\{'cssFiles':\[([^\]]*)\],"
                      r"'clientState':'([^']*)'", page_html)
    if not match:
        return _EDITOR_DEFAULTS
    return re.findall(r"'([^']*)'", match.group(1)), match.group(2)


def excuse_postback(page_html: str, *, day_from: date, day_to: date, whole_day: bool,
                    hour_from: dict | None, hour_to: dict | None, text: str,
                    now: datetime | None = None) -> list:
    """``[(name, value)]`` of the "Odeslat" postback for one excuse.

    ``hour_from`` / ``hour_to`` are ``/Komens/ExcuseHours`` items (the
    lesson pickers' values are minutes since midnight: the start lesson's
    begin and the end lesson's end). Whole-day excuses post the pickers as
    the form leaves them (first lesson of the first day, last of the last).
    """
    from .bakalari_http import dx_encode_html, dx_state, form_fields

    now = now or datetime.now()
    fields = form_fields(page_html)
    values = dict(fields)
    recipient = values.get("cphmain_cmbRecipient_VI", "")
    recipient_type = values.get("cphmain_cmbRecipientType_VI", "")
    from_minutes = hour_from["Begin"] if hour_from else None
    to_minutes = hour_to["End"] if hour_to else None
    now_ms = str(int(now.timestamp() * 1000))
    css_files, client_state = _editor_defaults(page_html)
    editor = dx_state({"cssFiles": css_files, "clientState": client_state, "validationState": "",
                       "html": dx_encode_html(text_to_html(text))})

    overrides = {
        f"{_P}cbExcuseWholeDay": "C" if whole_day else "U",
        f"{_P}teachingLesson": "I" if whole_day else "C",
        f"{_P}excuseFromDate": f"{day_from:%d.%m.%Y}",
        f"{_P}excuseToDate": f"{day_to:%d.%m.%Y}",
        "comboExcuseFromPeriod_VI": "" if from_minutes is None else str(from_minutes),
        f"{_P}comboExcuseFromPeriod": _hour_text(hour_from) if hour_from else "",
        f"{_P}comboExcuseFromPeriod$DDD$L": "" if from_minutes is None else str(from_minutes),
        "comboExcuseToPeriod_VI": "" if to_minutes is None else str(to_minutes),
        f"{_P}comboExcuseToPeriod": _hour_text(hour_to) if hour_to else "",
        f"{_P}comboExcuseToPeriod$DDD$L": "" if to_minutes is None else str(to_minutes),
        # The page's script forces "require confirmation" on for excuses
        # and clears the copy / e-mail boxes.
        f"{_P}cbWithConfirmation": "C",
        **{f"{_P}{box}": "U" for box in ("cbMailNotification", "cbCcClassTeacher", "cbCcDirector",
                                         "cbCcParent", "cbCcStudent")},
    }
    fields = [(name, overrides.get(name, value)) for name, value in fields]

    # Client state the DevExpress controls add in the browser.
    validity_end = now + timedelta(days=14)

    def combo(name):
        return [(f"{_P}{name}$DDDState", dx_state(_CLOSED)), (f"{_P}{name}$DDD$L$State", dx_state(_LIST))]

    def date_edit(name, day):
        return [(f"{_P}{name}$DDDState", dx_state(_CLOSED)),
                (f"{_P}{name}$DDD$C", dx_state(_calendar_state(day)))]

    time_state = dx_state({"rawValue": now_ms, "useMinDateInsteadOfNull": False})
    added = [
        *combo("cmbMessageType"),
        (f"{_P}cmbTypeOfRating$State", dx_state({"rawValue": ""})), *combo("cmbTypeOfRating"),
        (f"{_P}excuseFromDate$State", dx_state(_date_state(day_from))),
        *date_edit("excuseFromDate", now.date()), *combo("comboExcuseFromPeriod"),
        (f"{_P}excuseFromTime$State", time_state),
        (f"{_P}excuseToDate$State", dx_state(_date_state(day_to))),
        *date_edit("excuseToDate", now.date()), *combo("comboExcuseToPeriod"),
        (f"{_P}excuseToTime$State", time_state),
        *combo("cmbRecipientType"), *combo("cmbRecipient"),
        (f"{_P}cplRecipientState", dx_state(_CLOSED)),
        (f"{_P}cplRecipient$lbRecipients$State", dx_state(_LIST)),
        (f"{_P}cplRecipient$lbChoosenRecipients$State", dx_state(_LIST)),
        *combo("cplRecipient$cbGroupsSelection"),
        (f"{_P}pcGroupNameState", dx_state(_CLOSED)),
        *combo("cmbPostValidity"),
        (f"{_P}deValidityStart$State", dx_state({"rawValue": now_ms, "useMinDateInsteadOfNull": False})),
        *date_edit("deValidityStart", now.date()),
        (f"{_P}deValidityEnd$State", dx_state({"rawValue": str(int(validity_end.timestamp() * 1000)),
                                               "useMinDateInsteadOfNull": False})),
        *date_edit("deValidityEnd", validity_end.date()),
        (f"{_P}MessageEditor", editor),
        (f"{_P}MessageEditor$TD$T0", dx_state({"selectedItemIndexPath": "", "checkedState": ""})),
        (f"{_P}MessageEditor$SPC$TPCHC0$TC$ctl01$SrchBtnEdit$State", dx_state({"rawValue": ""})),
        (f"{_P}MessageEditor$SPCState", dx_state(
            {"windowsState": ";".join([_CLOSED["windowsState"]] * 2)})),
        (f"{_P}MessageEditor$SPC$ctl39$ResultList$State", dx_state(_LIST)),
        (f"{_P}MessageEditor$DPPState", dx_state(_CLOSED)),
        ("pcAttachments_MessageState", dx_state(_CLOSED)),
        (f"{_P}pcErrorState", dx_state(_CLOSED)),
        (f"{_P}pcWarningState", dx_state(_CLOSED)),
        _SEND_BUTTON,
        ("ctl00$pcConfirmDialogState", dx_state(_CLOSED)),
    ]
    scripts, css = _page_resources(page_html)
    editors = [
        ('"cphmain_cmbMessageType_DDD_L"', '["OMLUVENKA"]'),
        ('"cphmain_cbExcuseWholeDay"', "true" if whole_day else "false"),
        ('"cphmain_teachingLesson"', "null" if whole_day else "true"),
        ('"cphmain_specificTime"', "null"),
        ('"cphmain_cmbTypeOfRating_DDD_L"', "[]"), ('"cphmain_cmbTypeOfRating"', "null"),
        ('"cphmain_RatingScale"', "0"),
        ('"cphmain_excuseFromDate"', _js_date(day_from)),
        ('"comboExcuseFromPeriod_DDD_L"', f"[{from_minutes}]" if from_minutes is not None else "[]"),
        ('"cphmain_excuseFromTime"', _js_date(now)),
        ('"cphmain_excuseToDate"', _js_date(day_to)),
        ('"comboExcuseToPeriod_DDD_L"', f"[{to_minutes}]" if to_minutes is not None else "[]"),
        ('"cphmain_excuseToTime"', _js_date(now)),
        ('"cphmain_cmbRecipientType_DDD_L"', json.dumps([recipient_type])),
        ('"cphmain_cmbRecipient_DDD_L"', json.dumps([recipient], ensure_ascii=False)),
        ('"cphmain_cplRecipient_tbRecipientSearch"', "null"),
        ('"cphmain_cplRecipient_lbRecipients"', "[]"), ('"cphmain_cplRecipient_lbChoosenRecipients"', "[]"),
        ('"cphmain_cplRecipient_cbGroupsSelection_DDD_L"', "[]"), ('"cphmain_cplRecipient_cbGroupsSelection"', "null"),
        ('"cphmain_pcGroupName_tbGroupName"', "null"),
        ('"cmbPostValidity_DDD_L"', '["V"]'), ('"cmbPostValidity"', '"V"'),
        ('"cphmain_deValidityStart"', _js_date(now)), ('"cphmain_deValidityEnd"', _js_date(validity_end)),
        ('"cphmain_cbMailNotification"', "false"), ('"cphmain_cbCcClassTeacher"', "false"),
        ('"cphmain_cbCcDirector"', "false"), ('"cphmain_cbCcParent"', "false"), ('"cphmain_cbCcStudent"', "false"),
        ('"cphmain_tbTitle"', "null"),
        ('"cphmain_MessageEditor_SPC_TPCHC0_ctl01_0_SrchBtnEdit_0"', "null"),
        ('"cphmain_MessageEditor_SPC_ctl39_SrchBtnEdit"', "null"),
        ('"cphmain_MessageEditor_SPC_ctl39_ReplaceTb"', "null"),
        ('"cphmain_MessageEditor_SPC_ctl39_ResultList"', "[]"),
        ('"cphmain_MessageEditor_SPC_ctl39_MatchCase"', "null"),
        ('"comboExcuseFromPeriod"', "null" if from_minutes is None else str(from_minutes)),
        ('"comboExcuseToPeriod"', "null" if to_minutes is None else str(to_minutes)),
        ('"cphmain_cmbRecipient"', json.dumps(recipient, ensure_ascii=False)),
        ('"cphmain_cmbRecipientType"', json.dumps(recipient_type)),
        ('"cphmain_cmbMessageType"', '"OMLUVENKA"'),
        ('"cphmain_cbWithConfirmation"', "true"),
    ]
    added += [("DXScript", scripts), ("DXCss", css),
              ("DXMVCEditorsValues", "{" + ",".join(f"{k}:{v}" for k, v in editors) + "}")]
    return fields + added


def _same_day(value, day: date) -> bool:
    from .models import parse_cz_date

    return parse_cz_date(str(value or "").strip()) == day


class ExcuseFormMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def _excuse_text(self, day_start, day_end, start_lesson, end_lesson, is_days, excuse_type) -> str:
        def _first_text(templates, default):
            # Skip blank templates: they would submit an empty excuse.
            for candidate in templates or []:
                if str(candidate or "").strip():
                    return candidate
            return default

        if is_days:
            date_range = f"{day_start} – {day_end}" if day_start != day_end else day_start
            return format_excuse_template(_first_text(self.long_absence_excuses, "Omluvte prosím absenci."),
                                          date_str=date_range, signature_str=self.signature)
        lessons_range = f"{start_lesson}. – {end_lesson}." if start_lesson != end_lesson else str(start_lesson)
        if (excuse_type or "").lower() == "income":
            templates = self.late_income_excuses or ["Omluvte prosím pozdní příchod."]
        elif (excuse_type or "").lower() == "soon":
            templates = self.left_soon_excuses or ["Omluvte prosím předčasný odchod."]
        else:
            templates = self.short_absence_excuses or ["Omluvte prosím absenci."]
        return format_excuse_template(_first_text(templates, "Omluvte prosím absenci."), date_str=day_start,
                                      lessons_str=lessons_range, signature_str=self.signature)

    def _excuse_hours(self, session, day: date) -> list:
        """The student's lessons on ``day`` as the form offers them (``Caption``, ``Begin``, ``End``)."""
        items = session.json("GET", _HOURS_PATH, params={"date": day.isoformat()})
        return [i for i in items or [] if isinstance(i, dict) and "Begin" in i and "End" in i]

    def _prepare_excuse(self, day_start, day_end, start_lesson, end_lesson, custom_text, is_days, excuse_type):
        """``(fields, summary)`` of the postback, or None when the excuse
        cannot be filled in (nothing is sent then)."""
        from .models import parse_cz_date

        day_from, day_to = parse_cz_date(day_start), parse_cz_date(day_end)
        if day_from is None or day_to is None or day_to < day_from:
            self.log(f"Warning: excuse dates not understood ({day_start} – {day_end}), not sending.")
            return None
        whole_day = bool(is_days) or start_lesson is None or end_lesson is None
        from .bakalari_http import form_fields

        session = self._session()
        page = session.get_html(_FORM_PATH)
        if _SEND_BUTTON[0] not in page:
            raise RuntimeError("the excuse form did not load (format changed?)")
        if not dict(form_fields(page)).get("cphmain_cmbRecipient_VI", "").strip():
            raise RuntimeError("the excuse form has no recipient preselected")
        hours_from = self._excuse_hours(session, day_from)
        hours_to = hours_from if day_to == day_from else self._excuse_hours(session, day_to)
        if whole_day:
            hour_from = hours_from[0] if hours_from else None
            hour_to = hours_to[-1] if hours_to else None
            what = f"{day_from:%d.%m.%Y}" + ("" if day_to == day_from else f" – {day_to:%d.%m.%Y}") + ", whole days"
        else:
            hour_from, hour_to = _lesson(hours_from, start_lesson), _lesson(hours_to, end_lesson)
            missing = [str(n) for n, h in ((start_lesson, hour_from), (end_lesson, hour_to)) if h is None]
            if missing:
                self.log(f"Warning: lesson {', '.join(missing)} is not in your timetable on the excuse form "
                         f"for {day_start}, not sending.")
                return None
            what = (f"{day_from:%d.%m.%Y}" + ("" if day_to == day_from else f" – {day_to:%d.%m.%Y}")
                    + f", lessons {start_lesson}–{end_lesson} ({_minutes_text(hour_from['Begin'])}"
                    f"–{_minutes_text(hour_to['End'])})")
        text = custom_text or self._excuse_text(day_start, day_end, start_lesson, end_lesson,
                                                whole_day, excuse_type)
        if not str(text or "").strip():
            self.log("Warning: empty excuse text, not sending.")
            return None
        fields = excuse_postback(page, day_from=day_from, day_to=day_to, whole_day=whole_day,
                                 hour_from=hour_from, hour_to=hour_to, text=text)
        recipient = dict(fields).get("ctl00$cphmain$cmbRecipient", "")
        return fields, f"{what}, to {recipient}: {' '.join(str(text).split())[:120]}"

    def fill_excuse_form(self, day_start, day_end, start_lesson=None, end_lesson=None, custom_text=None,
                         is_days=False, excuse_type: str = None) -> bool:
        """Prepares the excuse exactly as it would be sent, without sending it
        (``dry_run``). True when it could be prepared."""
        self._raise_if_cancelled()
        prepared = self._prepare_excuse(day_start, day_end, start_lesson, end_lesson,
                                        custom_text, is_days, excuse_type)
        if prepared is None:
            return False
        self.log(f"Excuse prepared, not sent: {prepared[1]}")
        return True

    def _confirmed_in_outbox(self, session, before: set, day_from: date, day_to: date,
                             start_lesson, end_lesson, whole_day: bool) -> bool:
        """True when a new excuse for exactly these days (and lessons) is in Komens → Odeslané."""
        _, ids = self._outbox_excuse_ids(session, 500)
        for msg_id in ids:
            if msg_id in before:
                continue
            detail = self._outbox_detail(session, msg_id) or {}
            if not (_same_day(detail.get("DateFrom"), day_from) and _same_day(detail.get("DateTo"), day_to)):
                continue
            if whole_day:
                return True
            captions = [str((detail.get(k) or {}).get("Caption") or "").strip() for k in ("HourFrom", "HourTo")]
            if captions == [str(start_lesson).strip(), str(end_lesson).strip()]:
                return True
        return False

    def execute_excuse(self, day_start, day_end, start_lesson=None, end_lesson=None, custom_text=None,
                       is_days=False, excuse_type: str = None) -> bool:
        """Sends one excuse. True only when Komens → Odeslané shows it.

        False has two meanings, told apart by ``last_submit_uncertain``:
        False there = certainly not sent (not prepared, outbox unreadable
        before sending, the post never left, or the session had expired);
        True = the post went out but the outbox does not show it. The
        caller must then never re-send until the outbox settles it.
        """
        import httpx

        from .error_report import UserError
        from .models import parse_cz_date

        self.last_submit_uncertain = False
        self._raise_if_cancelled()
        prepared = self._prepare_excuse(day_start, day_end, start_lesson, end_lesson,
                                        custom_text, is_days, excuse_type)
        if prepared is None:
            return False
        fields, summary = prepared
        session = self._session()
        try:
            _, before = self._outbox_excuse_ids(session, 500)
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Excuse not sent: Komens → Odeslané is unreadable, so the send could not be "
                     f"verified ({type(e).__name__}: {e}).")
            return False

        from .bakalari_http import form_body

        self.log(f"Sending excuse: {summary}")
        started = time.monotonic()
        try:
            resp = session.send_once("POST", _FORM_PATH, **form_body(fields))
        except InterruptedError:
            # Raised by the cancel check before anything was sent.
            raise
        except UserError as e:
            never_left = isinstance(e.__cause__, (httpx.ConnectError, httpx.ConnectTimeout))
            self.last_submit_uncertain = not never_left
            self.log(f"Excuse post failed ({type(e.__cause__).__name__}): "
                     + ("nothing was sent." if never_left else "it may or may not have been sent; "
                        "NOT treating it as sent, and NOT sending it again."))
            return False
        location = resp.headers.get("location", "")
        if resp.is_redirect and "/login" in location.lower():
            self.logged_in = session.logged_in = False
            self.log("Excuse not sent: the Bakaláři session had expired (the post landed on the login page).")
            return False
        self.log(f"Excuse posted (HTTP {resp.status_code}{' → ' + location if location else ''}, "
                 f"{time.monotonic() - started:.1f} s), checking Komens → Odeslané…")

        self.last_submit_uncertain = True
        whole_day = bool(is_days) or start_lesson is None or end_lesson is None
        try:
            confirmed = self._confirmed_in_outbox(session, set(before), parse_cz_date(day_start),
                                                  parse_cz_date(day_end), start_lesson, end_lesson, whole_day)
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: could not check Komens → Odeslané after the post ({type(e).__name__}: {e}) — "
                     "the excuse may or may not have been sent; NOT sending it again.")
            return False
        if confirmed:
            self.last_submit_uncertain = False
            self.log("Excuse sent: it is in Komens → Odeslané.")
            return True
        self.log("Warning: the excuse is not in Komens → Odeslané after the post — it may or may not "
                 "have been sent; NOT treating it as sent, and NOT sending it again.")
        return False
