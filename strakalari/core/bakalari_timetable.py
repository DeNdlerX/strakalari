"""Bakaláři timetable scraping: weekly views and the stable ("Stálý") timetable."""

import json
import re
from datetime import datetime, timedelta

from .helpers import extract_lesson_num
from .bakalari_common import (
    _norm_date_str,
    parse_timetable_detail,
    _DETAIL_ATTR_RE,
    _html_lesson_days,
    _week_loaded_js,
    week_offsets,
)


class TimetableMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def extract_timetable_html(self):
        if not self.logged_in:
            self.log("Warning: extract_timetable_html called while logged out, skipping (no weeks fetched).")
            return

        self.page.locator(".ico32-modul-vyuka").first.click(timeout=self._nav_ms, once=True)
        self._wait_for_module(".ico32-modul-rozvrhHodin")
        self.page.locator(".ico32-modul-rozvrhHodin").first.click(timeout=self._nav_ms, once=True)

        # Switch to calendar
        cal_btn = self.page.locator('[data-bind*="SelectedTerm() === \'cal\'"]').first
        cal_btn.wait_for(state="visible", timeout=self._nav_ms)
        cal_btn.click(timeout=self._nav_ms, once=True)

        current_week = datetime.today().date()
        offsets = week_offsets(self.go_back_weeks, self.go_forward_weeks)
        # Timetable history: older school-year weeks the cache still lacks
        # (all of them on the first run, none afterwards). Fetched after
        # the regular window so a slow backfill never delays fresh data.
        this_monday = current_week - timedelta(days=current_week.weekday())
        for monday in sorted(getattr(self, "history_weeks", None) or (), reverse=True):
            off = (monday - this_monday).days // 7
            if off < 0 and off not in offsets:
                offsets.append(off)
        self.timetable_loaded_weeks = set()
        if not offsets:
            self.log("Warning: no timetable weeks to fetch (go_back_weeks=0, go_forward_weeks=0).")
        for off in offsets:
            if self._cancelled():
                raise InterruptedError("Cancelled by user.")
            week_date = current_week + timedelta(weeks=off)
            input_el = self.page.locator(".dx-texteditor-input").first
            input_el.wait_for(state="visible", timeout=self._element_ms)
            date_str = week_date.strftime("%d. %m. %Y")
            # Clear with fill(""), then type the date + ENTER: the
            # DevExpress date box ignores values set without key events.
            input_el.click()
            input_el.fill("")
            self.bm.random_sleep(0.3)
            input_el.press_sequentially(date_str, delay=10)
            input_el.press("Enter")

            # Verify the datepicker accepted the week. Every retype fires
            # another DevExpress postback, so wait out the callback first;
            # only a settled page with a provably wrong value earns one
            # retype.
            _date_ms = self._settle_ms()
            if not self._wait_for_date_value(".dx-texteditor-input", date_str,
                                             timeout_ms=_date_ms):
                try:
                    self._wait_for_page_settled(_date_ms)
                except InterruptedError:
                    raise
                except Exception:
                    pass
                try:
                    _echo = input_el.input_value(timeout=_date_ms)
                except InterruptedError:
                    raise
                except Exception:
                    _echo = ""
                if not (_echo and _norm_date_str(_echo) == _norm_date_str(date_str)):
                    try:
                        input_el.click()
                        input_el.fill("")
                        input_el.press_sequentially(date_str, delay=10)
                        input_el.press("Enter")
                        self._wait_for_date_value(".dx-texteditor-input", date_str,
                                                 timeout_ms=_date_ms)
                    except Exception:
                        pass

            # The week switch is an AJAX grid refresh. The previous week's
            # lessons are still in the DOM right after ENTER, so wait for a
            # lesson of the TARGET week (empty weeks wait the full budget).
            monday = week_date - timedelta(days=week_date.weekday())
            target_days = [monday + timedelta(days=i) for i in range(7)]
            settle_ms = self._settle_ms()
            if settle_ms > 0:
                try:
                    self.page.wait_for_function(
                        _week_loaded_js(target_days), timeout=settle_ms)
                except InterruptedError:
                    raise
                except Exception:
                    pass
            # Tiny fixed pause for the final JS re-render, then capture.
            self._sleep_s(0.2)

            html = str(self.page.content())
            if "data-detail" not in html:
                # Slow render: one more settle window + re-capture instead of
                # storing an empty week.
                self.log(f"Warning: Timetable for week of {date_str} looks empty, waiting a bit longer.")
                self._sleep_s(self._week_settle_s)
                html = str(self.page.content())
            shown = _html_lesson_days(html)
            if shown and not shown.intersection(target_days):
                # Still the previous week: storing it would silently skip
                # this week. The cache merge keeps its previously known days.
                self.log(f"Warning: week of {date_str} did not load (page still shows "
                         f"{min(shown):%d.%m.}–{max(shown):%d.%m.}), skipping it this run.")
                continue
            self.timetable_sources.append(html)
            self.timetable_loaded_weeks.add(monday)

    def extract_timetable_data(self, html_file_string: str, target: dict = None):
        """Parses a captured timetable page's ``data-detail`` lessons.

        Lessons merge into ``timetableData`` (or ``target`` — the stable
        view scrape parses into its own dict), grouped per day.
        """
        import html

        results = []
        dropped_json = 0
        dropped_incomplete = 0

        for m in _DETAIL_ATTR_RE.finditer(html_file_string):
            raw = m.group(2)
            detail_str = html.unescape(raw)
            try:
                detail = json.loads(detail_str)
            except json.JSONDecodeError:
                dropped_json += 1
                continue

            hour_to_add = parse_timetable_detail(detail)
            if hour_to_add is None:
                dropped_incomplete += 1
                continue
            if hour_to_add not in results:
                results.append(hour_to_add)

        unsortedTimetableData = {}
        for result in results:
            date_key = result.get("date")
            if not date_key:
                dropped_incomplete += 1
                continue
            if date_key not in unsortedTimetableData:
                unsortedTimetableData[date_key] = []
            unsortedTimetableData[date_key].append(result)
        if dropped_json or dropped_incomplete:
            self.log(
                f"Warning: timetable parse dropped {dropped_json} malformed + "
                f"{dropped_incomplete} dateless/incomplete rows (markup may have changed)."
            )

        for day, lessons in unsortedTimetableData.items():
            def lesson_sort_key(item):
                num = extract_lesson_num(item.get("time", ""))
                if num is None:
                    try:
                        num = int(item.get("period")) if item.get("period") is not None else None
                    except (TypeError, ValueError):
                        num = None
                return num if num is not None else 999

            dest = target if target is not None else self.timetableData
            if day not in dest:
                dest[day] = []
            for lesson in sorted(lessons, key=lesson_sort_key):
                if lesson not in dest[day]:
                    dest[day].append(lesson)

    def _open_stable_view(self) -> str:
        """Opens the 'Stálý' (stable timetable) mode if present.

        The timetable mode switcher is a Knockout radio group
        (``SelectedTerm``: ``now``/``next``/``perm``/``cal``) with stable
        ``data-testid`` hooks. The ``perm`` option is targeted exactly —
        never a fuzzy "any non-calendar option", which would land on
        "Tento týden" and silently scrape the wrong week as stable.
        Returns which strategy worked, or "" when the button wasn't found.
        Never raises except on user cancel.
        """
        # 1) Exact: the 'Stálý' (perm) radio label via data-testid
        # (desktop switcher first, small-screen dropdown variant second).
        for tid in ("timetable-permanent-link",
                    "timetable-small-permanent-link"):
            try:
                label = self.page.locator(
                    f'label:has(input[data-testid="{tid}"])').first
                label.wait_for(state="visible", timeout=self._element_ms)
                label.click(timeout=self._nav_ms, once=True)
                self.page.wait_for_function(
                    "() => { const el = document.querySelector("
                    f"'input[data-testid=\"{tid}\"]'); return !!el && "
                    "(el.checked === true || "
                    "((el.closest('label') || {}).classList || {})"
                    ".contains('active')); }",
                    timeout=self._element_ms,
                )
                return f"testid:{tid}"
            except InterruptedError:
                raise
            except Exception:
                continue
        # 2) Fallback: the Knockout perm term label (same switcher family
        # the calendar click uses).
        try:
            loc = self.page.locator(
                '[data-bind*="SelectedTerm() === \'perm\'"]').first
            loc.wait_for(state="visible", timeout=self._element_ms)
            loc.click(timeout=self._nav_ms, once=True)
            return "term-switch:perm"
        except InterruptedError:
            raise
        except Exception:
            pass
        # 3) Last resort: visible "Stálý" text (older markup without testids).
        try:
            loc = self.page.get_by_text(
                re.compile(r"stálý|stable timetable",
                           re.IGNORECASE)).first
            loc.wait_for(state="visible", timeout=self._element_ms)
            loc.click(timeout=self._nav_ms, once=True)
            return "text:Stálý"
        except InterruptedError:
            raise
        except Exception:
            pass
        return ""

    def extract_stable_timetable(self) -> bool:
        """Scrapes the 'Stálý rozvrh' view into ``stableTimetableData``.

        Runs after the actual weeks were captured (same module, no extra
        login). Returns True when the stable view opened and yielded
        lessons; False when the button wasn't found or the view was empty
        (callers fall back to the learned baseline). Never raises except
        on user cancel.
        """
        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        self.stableTimetableData = {}
        try:
            strategy = self._open_stable_view()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: stable timetable button search failed: {e}")
            return False
        if not strategy:
            self.log("Stable timetable button not found — "
                     "baseline will be learned from actual weeks.")
            return False
        self.log(f"Stable view opened ({strategy}).")
        settle_ms = self._settle_ms()
        if settle_ms > 0:
            try:
                self.page.wait_for_function(
                    "() => document.body && document.body.innerHTML.includes('data-detail')",
                    timeout=settle_ms,
                )
            except Exception:
                pass
        self._sleep_s(0.2)
        html = str(self.page.content())
        if "data-detail" not in html:
            self.log("Warning: stable timetable view looks empty, waiting a bit longer.")
            self._sleep_s(self._week_settle_s)
            html = str(self.page.content())
        if "data-detail" not in html:
            self.log("Warning: stable timetable view is empty — "
                     "baseline will be learned from actual weeks.")
            return False
        self.extract_timetable_data(html, target=self.stableTimetableData)
        n_lessons = sum(len(v) for v in self.stableTimetableData.values())
        if not n_lessons:
            self.log("Warning: no stable lessons parsed — "
                     "baseline will be learned from actual weeks.")
            return False
        self.log(f"Stable timetable scraped: {n_lessons} lessons "
                 f"in {len(self.stableTimetableData)} days.")
        return True
