import re
import html
import json

from typing import Union


# Sent-excuse detail (Komens -> Odeslané). The real page renders the
# range across ~800 chars of nested markup, with the clock time between
# a date and its lesson ("Od: 3.9.2026 10:05 (3. hod.)"), so the parser
# works on the *visible text* of the excuse block, not on raw HTML.
_EXCUSE_ANCHORS = (
    "komens-message-detail-excuse-wrapper",  # the Od/Do row itself
    "komens-message-detail-header",          # older layouts / fallback
)
_TAG_RE = re.compile(r"<[^>]+>")
_DATE_TXT = r"(\d{1,2}\s*\.\s*\d{1,2}\s*\.\s*\d{4})"
_TIME_TXT = r"(\d{1,2}:\d{2})"
# The lesson must follow its date directly (only the clock time may sit
# between): a looser match let "(3. hod.)" come from the message body,
# turning a whole-day excuse into a bogus hour range.
_HOUR_TXT = r"\(\s*(\d+)\s*\.\s*hod\.?\s*\)"
_SENT_EXCUSE_TEXT_RE = re.compile(
    r"Od\s*:\s*" + _DATE_TXT + r"\s*(?:" + _TIME_TXT + r")?\s*(?:" + _HOUR_TXT + r")?"
    r"\s*Do\s*:\s*" + _DATE_TXT + r"\s*(?:" + _TIME_TXT + r")?\s*(?:" + _HOUR_TXT + r")?",
    re.I,
)


def _html_to_text(fragment: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(_TAG_RE.sub(" ", fragment)))


def _find_excuse_range(html_string: str):
    """Text-regex match of the first rendered excuse block, or None.

    The page also carries the jsrender template (``{{:DateFrom}}``) with
    the same testids; its text never holds a date, so it never matches.
    """
    for anchor in _EXCUSE_ANCHORS:
        start = html_string.find(anchor)
        while start != -1:
            end = html_string.find("</tr>", start) if "wrapper" in anchor else -1
            if end == -1:
                end = start + 10000
            match = _SENT_EXCUSE_TEXT_RE.search(_html_to_text(html_string[start:end]))
            if match is not None:
                return match
            start = html_string.find(anchor, start + len(anchor))
    return None


def _zero_pad_day(date_str: str) -> str:
    """Normalizes ``D.M.YYYY`` to zero-padded ``DD.MM.YYYY``.

    Tolerates surrounding whitespace and trailing dots (the web renders
    e.g. ``"24. 9. 2026."``); raises ValueError when unparseable (the
    caller treats that as "no entry", never a crash).
    """
    parts = [p.strip() for p in str(date_str).strip().rstrip(".").split(".")]
    parts = [p for p in parts if p]
    if len(parts) != 3:
        raise ValueError(f"Unparseable date: {date_str!r}")
    day, month, year = parts
    return f"{day.zfill(2)}.{month.zfill(2)}.{year}"


def _parse_sent_excuse_html(html_string: str) -> list:
    """Parses one Komens detail page source into 0-3 history entries.

    Hour-based excuses yield three entries (``income`` + ``soon`` +
    ``days and hours``), mirroring the legacy ``check_webpage_for_excuses``
    behavior so web-side excuses dedupe against all locally generated
    shapes (late arrivals, early leaves and short absences share one
    single-lesson web format). Never raises on unparseable input —
    returns [] instead.
    """
    if not html_string:
        return []
    match = _find_excuse_range(html_string)
    if match is None:
        return []
    try:
        start_day = _zero_pad_day(match.group(1))
        end_day = _zero_pad_day(match.group(4))
    except (AttributeError, ValueError):
        return []
    has_time = bool(match.group(2) or match.group(5))
    start_lesson_raw = match.group(3)
    end_lesson_raw = match.group(6)
    if not start_lesson_raw or not end_lesson_raw:
        if has_time:
            # Clock times without lesson numbers: the covered lessons are
            # unknown. Recording a whole day would silently swallow real
            # absences, so learn nothing instead.
            return []
        return [{
            "type": "pure days",
            "starting_day": start_day,
            "ending_day": end_day,
        }]
    start_lesson = int(start_lesson_raw)
    end_lesson = int(end_lesson_raw)
    base = {
        "starting_day": start_day,
        "ending_day": end_day,
        "starting_lesson": start_lesson,
        "ending_lesson": end_lesson,
    }
    return [
        {"type": "income", **base},
        {"type": "soon", **base},
        {"type": "days and hours", **base},
    ]


def extract_sent_excuses(html_sources: Union[str, list, tuple, None]) -> list:
    """Extracts already-sent excuses from Komens detail page sources.

    Accepts a single HTML string or a list of them (one per excuse, as
    collected by clicking each ``[data-msgtype=\"OMLUVENKA\"]`` row).
    Returns deduplicated history-shaped dicts. Never raises.
    """
    if not html_sources:
        return []
    if isinstance(html_sources, str):
        html_sources = [html_sources]
    merged: list = []
    try:
        sources = list(html_sources)
    except TypeError:
        return []
    for source in sources:
        if not source:
            continue
        try:
            entries = _parse_sent_excuse_html(source)
        except Exception:
            continue
        for entry in entries:
            if entry not in merged:
                merged.append(entry)
    return merged


def extract_absence_percentages(html_string: str) -> dict:
    """
    Extracts absence percentages per subject from Bakalari absence overview HTML.
    Returns a dict mapping subject name (str) -> percentage (float).
    """
    result_dict = {}
    if not html_string:
        return result_dict

    # Regex to find all <tr>...</tr> blocks
    # re.DOTALL ensures the dot (.) matches newlines if the HTML is spread across multiple lines
    tr_pattern = re.compile(r'<tr[^>]*>(.*?)</tr>', re.IGNORECASE | re.DOTALL)

    # Regex to find <td> elements with specific aria-colindex values.
    # It accounts for optional quotes around the number and other potential attributes before the closing '>'.
    td1_pattern = re.compile(r'<td[^>]*?aria-colindex\s*=\s*[\'"]?1[\'"]?(?:\s[^>]*)?>(.*?)</td>', re.IGNORECASE | re.DOTALL)
    td4_pattern = re.compile(r'<td[^>]*?aria-colindex\s*=\s*[\'"]?4[\'"]?(?:\s[^>]*)?>(.*?)</td>', re.IGNORECASE | re.DOTALL)

    # Helper function to clean up the extracted HTML content inside the <td>
    def clean_text(raw_text):
        # Remove any nested HTML tags (e.g., <span>, <div> inside the <td>)
        text_no_tags = re.sub(r"<[^>]+>", "", raw_text)
        # Unescape HTML entities (e.g., &amp; -> &)
        unescaped_text = html.unescape(text_no_tags)
        # Normalize whitespace (replace newlines/tabs/non-breaking spaces/multiple spaces with a single space)
        normalized_text = re.sub(r"[\s\xa0]+", " ", unescaped_text)
        return normalized_text.strip()

    def _first_num(cell_text):
        """First percentage number in a cell ("12,5 %" -> 12.5)."""
        m = re.search(r"(\d+(?:[.,]\d+)?)", str(cell_text))
        if not m:
            raise ValueError(f"No percentage in {cell_text!r}")
        return float(m.group(1).replace(",", "."))

    def _store(key, value):
        # A subject listed twice (e.g. per-term rows): keep the cell with
        # the worst percentage so warnings never under-report. Unparseable
        # cells are dropped — otherwise a garbage first-seen row would
        # poison the subject and block a later good row.
        try:
            new_num = _first_num(value)
        except ValueError:
            return
        if key in result_dict:
            try:
                old_num = _first_num(result_dict[key])
            except ValueError:
                old_num = None
            if old_num is not None and new_num <= old_num:
                return
        result_dict[key] = value

    # Iterate over all <tr> blocks found in the HTML string
    for tr_content in tr_pattern.findall(html_string):
        match1 = td1_pattern.search(tr_content)
        match4 = td4_pattern.search(tr_content)

        # If both a colindex="1" and colindex="4" td exist in this row
        if match1 and match4:
            key = clean_text(match1.group(1))
            value = clean_text(match4.group(1))

            # Sanity check: value must contain '%' and not be a summary row (Zameškanost / Celkem / Součet / Průměr, incl. undiacriticized and Souhrn variants)
            summary_words = ("zameškanost", "zameskanost", "celkem", "součet", "soucet", "souhrn", "průměr", "prumer")
            val_low = value.lower()
            key_low = key.lower()
            is_summary = any(sw in val_low or sw in key_low for sw in summary_words)
            if '%' in value and not is_summary:
                _store(key, value)
        else:
            # Fallback: extract from general <td> cells when aria-colindex is omitted
            all_tds = re.findall(r'<td[^>]*>(.*?)</td>', tr_content, re.IGNORECASE | re.DOTALL)
            if len(all_tds) >= 2:
                pct_td = next((td for td in all_tds[1:] if '%' in td), None)
                if pct_td:
                    key = clean_text(all_tds[0])
                    value = clean_text(pct_td)
                    summary_words = ("zameškanost", "zameskanost", "celkem", "součet", "soucet", "souhrn", "průměr", "prumer")
                    val_low = value.lower()
                    key_low = key.lower()
                    is_summary = any(sw in val_low or sw in key_low for sw in summary_words)
                    if '%' in value and not is_summary and key:
                        _store(key, value)

    parsed_percentages = {}
    for key, value in result_dict.items():
        # Safely extract numeric portion (e.g. "12,5 %", "12.5%", " 0 % ")
        match = re.search(r"(\d+(?:[.,]\d+)?)", str(value))
        if match:
            parsed_percentages[key] = float(match.group(1).replace(",", "."))

    return parsed_percentages


_GRADES_RE = re.compile(
    r'data-clasif\s*=\s*(["\'])(\{[^}]*?MarkText[^}]*?\})\1',
    re.DOTALL | re.IGNORECASE,
)

_ATTR_OPEN_RE = re.compile(r'data-clasif\s*=\s*(["\'])', re.IGNORECASE)


def _iter_grade_blobs(source: str):
    """Yields ``data-clasif`` JSON blobs with balanced-brace scanning.

    The old ``[^}]*`` regex broke on nested objects (``{"a": {"b": 1},
    ...}``) or a ``}`` inside a string value. This scanner counts braces
    while respecting quoted strings (both quote styles, backslash
    escapes), so nested/escaped content parses. Yields raw blob strings.
    """
    n = len(source)
    for m in _ATTR_OPEN_RE.finditer(source):
        i = m.end()
        while i < n and source[i].isspace():
            i += 1
        if i >= n or source[i] != "{":
            continue
        depth = 0
        in_str = None
        esc = False
        j = i
        closed = False
        while j < n:
            ch = source[j]
            if in_str is not None:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == in_str:
                    in_str = None
            else:
                if ch == '"' or ch == "'":
                    in_str = ch
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        closed = True
                        break
            j += 1
        if closed:
            yield source[i:j + 1]


def _grade_date_key(date_str):
    """Sort key for ``udel_datum`` values (Czech ``D.M.YYYY`` or ISO).

    Unparseable/missing dates sort after real ones, ordered by their raw
    string so the order stays deterministic. Never raises.
    """
    try:
        from ..helpers import parse_date

        return (0, parse_date(str(date_str)))
    except Exception:
        return (1, str(date_str or ""))


def _grade_extras(grade: dict, entry: dict) -> dict:
    """Optional mark details, only the ones the page actually filled in.

    ``caption`` is the topic ("pololetní test"), ``strdatum`` the day the
    test was (or is planned to be) written, ``PointsText`` a points mark,
    ``MarkTooltip`` "plánovaná klasifikace" flags an announced mark ("?").
    Empty values are left out so plain marks keep their three keys.
    """
    extras: dict = {}

    def _text(key: str) -> str:
        value = grade.get(key)
        return str(value).strip() if value is not None else ""

    if _text("id"):
        extras["Id"] = _text("id")
    if _text("caption"):
        extras["Caption"] = _text("caption")
    note = " · ".join(t for t in (_text("poznamkakzobrazeni"), _text("VerbalEvaluation")) if t)
    if note:
        extras["Note"] = note
    test_day = _text("strdatum")
    if test_day and test_day != str(entry.get("Date") or "").strip():
        extras["TestDate"] = test_day
    if _text("PointsText"):
        extras["Points"] = _text("PointsText")
    if grade.get("IsNew") is True:
        extras["New"] = True
    tooltip = _text("MarkTooltip").lower()
    if entry.get("Grade") == "?" or "plánovan" in tooltip:
        extras["Planned"] = True
    return extras


def extract_grades(html_string: str) -> dict:
    """Extracts průběžná klasifikace marks from the Bakalari grades page.

    Parses the ``data-clasif`` JSON blobs (``nazev`` / ``MarkText`` /
    ``vaha`` / ``udel_datum``) and groups them per subject::

        {"Matematika": [{"Grade": "1", "Weight": 10, "Date": "5.9.2026"}, ...]}

    Optional details (Id, Caption, Note, TestDate, Points, New, Planned)
    are added per mark only when the page provides them.

    Every subject list is sorted by date (oldest first); the raw page
    groups by subject but leaves dates unordered. Never raises —
    returns {} on empty or unparseable input.
    """
    result_dict: dict = {}
    if not html_string:
        return result_dict
    try:
        source = html.unescape(str(html_string))
    except Exception:
        return result_dict
    blobs = list(_iter_grade_blobs(source))
    if not blobs:
        # Fallback: the legacy regex for markups the scanner misses.
        blobs = [m.group(2) for m in _GRADES_RE.finditer(source)]
    for blob in blobs:
        try:
            grade = json.loads(blob)
        except (ValueError, TypeError):
            continue
        if not isinstance(grade, dict):
            continue
        subject = grade.get("nazev")
        score = grade.get("MarkText")
        if subject is None or score is None:
            continue
        subject = str(subject).strip()
        if not subject:
            continue
        entry = {
            "Grade": str(score).strip(),
            "Weight": grade.get("vaha"),
            "Date": grade.get("udel_datum"),
        }
        entry.update(_grade_extras(grade, entry))
        result_dict.setdefault(subject, []).append(entry)
    for marks in result_dict.values():
        try:
            marks.sort(key=lambda e: _grade_date_key((e or {}).get("Date")))
        except Exception:
            continue
    return result_dict


def _clean_span_text(raw_html: str) -> str:
    """Strips tags/entities from a small HTML fragment, one line."""
    try:
        text = re.sub(r"<[^>]+>", " ", str(raw_html or ""))
        text = html.unescape(text)
        return re.sub(r"[\s\xa0]+", " ", text).strip()
    except Exception:
        return ""


def _substitution_field(entry_html: str, testid: str) -> str:
    """Rendered text of one data-testid span inside a feed entry."""
    try:
        match = re.search(
            r"data-testid" + r"\s*=\s*" + chr(34) + re.escape(testid) + chr(34)
            + r"[^>]*>(.*?)</",
            entry_html, re.DOTALL | re.IGNORECASE)
        if not match:
            return ""
        return _clean_span_text(match.group(1))
    except Exception:
        return ""


def parse_substitutions(html_string: str) -> list:
    """Parses the substitution feed into change entries.

    Each item holds day (D.M.YYYY), period, time, badge (M = room move,
    O = cancelled, S = substitution, A = absence, N = added), info (the
    lesson tag), subject_short and description. Day headers own the
    entries that follow them. Never raises: [] on empty input.
    """
    if not html_string:
        return []
    try:
        source = str(html_string)
    except Exception:
        return []
    markers: list = []
    try:
        for match in re.finditer(
                r"data-testid" + r"\s*=\s*" + chr(34) + "substitutions-day-header"
                + chr(34) + r"[^>]*>(.*?)</",
                source, re.DOTALL | re.IGNORECASE):
            markers.append((match.start(), "day", match.group(1)))
        for match in re.finditer(
                r"data-testid" + r"\s*=\s*" + chr(34) + "substitutions-entry"
                + chr(34),
                source, re.IGNORECASE):
            markers.append((match.start(), "entry", ""))
    except Exception:
        return []
    markers.sort(key=lambda item: item[0])
    entries: list = []
    current_day = ""
    for pos, kind, payload in markers:
        if kind == "day":
            day_match = re.search(
                r"(\d{1,2}\.\d{1,2}\.\d{4})", _clean_span_text(payload))
            current_day = day_match.group(1) if day_match else ""
            continue
        if not current_day:
            continue
        end = len(source)
        for later_pos, _, _ in markers:
            if later_pos > pos:
                end = later_pos
                break
        entry_html = source[pos:end]
        badge = _substitution_field(entry_html, "substitutions-badge")
        period_raw = _substitution_field(entry_html, "substitutions-hour-label")
        try:
            # Decorated labels ("3. hodina", "3. hod") carry the number
            # with text around it — parse the first number, not just a
            # bare integer, or the period is lost (None).
            match = re.search(r"\d+", period_raw or "")
            period = int(match.group(0)) if match else None
        except (TypeError, ValueError):
            period = None
        info = _substitution_field(entry_html, "substitutions-lesson-info")
        subject_short = ""
        try:
            parts = [p.strip() for p in info.split("|")]
            if len(parts) >= 2 and parts[1]:
                subject_short = parts[1]
        except Exception:
            subject_short = ""
        entries.append({
            "day": current_day,
            "period": period,
            "time": _substitution_field(entry_html, "substitutions-time-label"),
            "badge": badge,
            "info": info,
            "subject_short": subject_short,
            "description": _substitution_field(
                entry_html, "substitutions-lesson-description"),
        })
    return entries


def _absence_num(text: str) -> float | None:
    """First number in a cell (12,5 % -> 12.5), None when absent."""
    try:
        match = re.search(r"(\d+(?:[.,]\d+)?)", str(text or ""))
        return float(match.group(1).replace(",", ".")) if match else None
    except (TypeError, ValueError):
        return None


def _badge_visible(cell_html: str, kind: str) -> bool:
    """True when a bk-badge span of ``kind`` is rendered (not display:none).

    Both verdict badges live in the cell at all times; Bakalari hides
    the inactive one with an inline display:none, so text presence
    alone cannot tell whether the school actually flagged the subject.
    """
    try:
        for match in re.finditer(
                r"<span[^>]*class=[\"'][^\"']*bk-badge[^\"']*[\"'][^>]*>(.*?)</span>",
                cell_html or "", re.DOTALL | re.IGNORECASE):
            label = _clean_span_text(match.group(1)).lower()
            if kind not in label:
                continue
            tag = match.group(0).split(">")[0].lower().replace(" ", "")
            if "display:none" not in tag:
                return True
        return False
    except Exception:
        return False


def extract_absence_details(html_string: str) -> dict:
    """Extracts the full absence overview per subject.

    Returns {subject: {percent, total_hours, missed_hours, approaching,
    unclassifiable}}. total_hours/missed_hours are elapsed (already
    taught) hours, never planned totals. approaching/unclassifiable
    mirror the schools verdict badges, which are display:none-gated:
    hidden at 0 percent means no flag. Never raises.
    """
    details: dict = {}
    if not html_string:
        return details
    try:
        source = str(html_string)
    except Exception:
        return details
    try:
        rows = re.findall(r"<tr[^>]*>(.*?)</tr>", source, re.IGNORECASE | re.DOTALL)
    except Exception:
        return {}
    for row in rows:
        try:
            cells = re.findall(r"(<td[^>]*>)(.*?)</td>", row, re.IGNORECASE | re.DOTALL)
            by_index: dict = {}
            raws: dict = {}
            for tag, body in cells:
                col = re.search(r"aria-colindex\s*=\s*['\"]?(\d+)", tag)
                if col:
                    by_index[col.group(1)] = _clean_span_text(body)
                    raws[col.group(1)] = body
            if "1" not in by_index or "4" not in by_index:
                continue
            subject = (by_index.get("1") or "").strip()
            pct_cell = by_index.get("4") or ""
            if "%" not in pct_cell or not subject:
                continue
            lowered = subject.lower()
            if any(word in lowered for word in ("zameškanost", "zameskanost", "celkem", "součet", "soucet", "souhrn", "průměr", "prumer")):
                continue
            pct = _absence_num(pct_cell)
            if pct is None:
                continue
            details[subject] = {
                "percent": pct,
                "total_hours": _absence_num(by_index.get("2")),
                "missed_hours": _absence_num(by_index.get("3")),
                "approaching": _badge_visible(raws.get("5", ""), "blíží se limitu"),
                "unclassifiable": _badge_visible(raws.get("5", ""), "nelze klasifikovat"),
            }
        except Exception:
            continue
    return details


def parse_subject_directory(html_string: str) -> dict:
    """Parses the subject directory into {subject: teacher}.

    Two-column rows (subject, teacher full name); header and empty rows
    are skipped. Subject names need whitespace normalization by the
    caller (the absence table uses non-breaking spaces). Never raises.
    """
    directory: dict = {}
    if not html_string:
        return directory
    try:
        source = str(html_string)
    except Exception:
        return directory
    try:
        rows = re.findall(r"<tr[^>]*>(.*?)</tr>", source, re.IGNORECASE | re.DOTALL)
    except Exception:
        return {}
    for row in rows:
        try:
            cells = [_clean_span_text(body) for body in
                     re.findall(r"<td[^>]*>(.*?)</td>", row, re.IGNORECASE | re.DOTALL)]
            if len(cells) < 2:
                continue
            subject, teacher = cells[0].strip(), cells[1].strip()
            if not subject:
                continue
            if subject.lower() in ("předmět", "predmet", "subject"):
                continue
            if teacher.lower() in ("učitel", "ucitel", "teacher"):
                continue
            # Keep teacherless rows with an empty teacher: the subject is
            # still absence-relevant (Přehled předmětů is the canonical
            # tracked set) and must not vanish from it.
            directory[subject] = teacher
        except Exception:
            continue
    return directory
