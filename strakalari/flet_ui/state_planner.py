"""School calendar, absence forecast and planned skips.

Mixin of :class:`strakalari.flet_ui.state.AppState` — it relies on the
state attributes and helpers defined there (``config``, ``data``,
``_emit``, ``_spawn``, ``log`` …).
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

from strakalari.core import forecast as fc
from strakalari.core.models import SubjectState
from strakalari.core.planned_skips import (
    cancels_lunch,
    entry_days,
    entry_start_iso,
    normalize_planned_entry,
)


class PlannerMixin:
    def calendar_data(self) -> tuple[set, dict, dict]:
        """(free-day dates, labels, info) from preset + user deltas."""
        from strakalari.core import school_presets as sp

        try:
            return sp.effective_calendar(self.config.data)
        except Exception:
            return set(), {}, {"preset_id": "", "preset_days": 0,
                               "user_added": 0, "forced_school": 0}

    def effective_holidays(self) -> list[str]:
        dates, _, _ = self.calendar_data()
        return sorted(d.strftime("%d.%m.%Y") for d in dates)

    def sem_close(self, which: str) -> str:
        """Resolved absence-closure date (user value, else preset, else '')."""
        from strakalari.core import school_presets as sp

        try:
            return sp.resolve_close(which, self.config.data)
        except Exception:
            return str(self.get("sem1_close" if which == "sem1" else "sem2_close", "") or "")

    def calendar_summary(self) -> tuple[int, int, int, str, str]:
        """(preset_n, added_n, forced_n, sem1, sem2) for summary lines."""
        _, _, info = self.calendar_data()
        return (int(info.get("preset_days", 0)), int(info.get("user_added", 0)),
                int(info.get("forced_school", 0)),
                self.sem_close("sem1"), self.sem_close("sem2"))

    def plan_reserve(self) -> float:
        """Global planning reserve in percentage points (>= 0)."""
        try:
            return max(0.0, float(self.get("absence_plan_reserve_pct", 10.0)))
        except (TypeError, ValueError):
            return 10.0

    def subject_states(self) -> tuple[list[SubjectState], list[date]]:
        # No timetable, no planner: without lessons there is nothing to
        # budget (the baseline is learned from the timetable, so it is
        # missing too). Callers show a "refresh first" hint instead.
        if not self.timetable():
            return [], []
        default_limit = 25.0
        try:
            default_limit = float(self.get("absence_critical_pct", 25.0))
        except (TypeError, ValueError):
            pass
        warn_pct = None
        try:
            # Default 15.0 matches the settings field and the Bakaláři
            # client default — a missing key must not silently mean
            # "disabled" while the UI shows 15.0.
            warn_pct = float(self.get("absence_warn_pct", 15.0) or 0) or None
        except (TypeError, ValueError):
            pass
        try:
            baseline = self.stable_baseline()
        except Exception:
            baseline = None
        return fc.forecast_all(
            self.absence(),
            self.timetable(),
            self.get("subject_limits", {}),
            self.effective_holidays(),
            default_limit=default_limit,
            school_year_end=self.get("school_year_end", ""),
            sem1_close=self.sem_close("sem1"),
            sem2_close=self.sem_close("sem2"),
            warn_pct=warn_pct,
            stable_baseline=baseline,
            reserve_pct=self.plan_reserve(),
            tracked_subjects=self.tracked_subjects(),
            absence_details=self.absence_details() or None,
        )

    def plan_skip(self, day_iso: str, template: str, cancel_lunch: bool = True) -> bool:
        """Accepts a suggestion: records the skip and optionally cancels lunch.

        Returns False when the range is invalid (mirrors plan_custom_skip).
        """
        return bool(self.plan_custom_skip(str(day_iso or ""), str(day_iso or ""),
                                          None, None, template,
                                          cancel_lunch=cancel_lunch))

    def plan_custom_skip(self, start_iso: str, end_iso: str,
                         start_period: int | None, end_period: int | None,
                         template: str, cancel_lunch: bool = True) -> bool:
        """Plans a custom range (single partial day … multi-day).

        ``start_period``/``end_period`` are 1-based lesson numbers or None
        for \"whole day\" (start_period = first missed lesson of the first
        day, end_period = last missed lesson of the last day, middle days
        are whole). Returns False when the range is invalid or persistence failed.
        """
        entry = normalize_planned_entry({
            "start_date": str(start_iso or ""), "end_date": str(end_iso or ""),
            "start_period": start_period, "end_period": end_period,
            "template": template, "cancel_lunch": bool(cancel_lunch),
        })
        if entry is None:
            return False
        if len(entry_days(entry)) > 31:
            return False
        _prev_skips = list(self.planned_skips)
        _prev_cancelled = set(self.cancelled_lunches)
        _prev_orders = dict(self.orders)
        _prev_pending = set(self.pending_orders)
        if entry not in self.planned_skips:
            self.planned_skips.append(entry)
        if bool(cancel_lunch) and self.strava_enabled():
            self._stage_lunch_cancel(entry)
        try:
            self.config.set("planned_skips", list(self.planned_skips))
            self.config.save()
        except Exception as exc:  # noqa: BLE001 - roll back memory to match disk
            self.planned_skips = _prev_skips
            self.cancelled_lunches = _prev_cancelled
            self.orders = _prev_orders
            self.pending_orders = _prev_pending
            print(f"Warning: could not persist planned skips: {exc}")
            self._emit()
            return False
        self.tutorial_event("day_planned")
        self._emit()
        return True

    def _stage_lunch_cancel(self, entry: dict) -> None:
        """Queues the lunch cancellation for every still-open day of ``entry``."""
        for day in entry_days(entry):
            day_label = day.strftime("%d.%m.%Y")
            try:
                _open = self.is_lunch_order_open(day_label)
            except Exception:
                _open = True
            if not _open:
                # Past the order/cancel cutoff: the web would reject the
                # change, so leave this day out of the local cancel set.
                continue
            self.cancelled_lunches.add(day_label)
            # Queue the lunch cancellation so Send transmits it: stage the
            # menu's deorder id as the local pick (pending). Without a known
            # menu just drop the local pick; submit_orders derives the deorder
            # from the menu at send time.
            deorder: str | None = None
            try:
                meals = (self.food() or {}).get(day_label, {}) or {}
                deorder = next((str(mid) for mid in meals if "&-1&" in str(mid)), None)
            except Exception:
                deorder = None
            if deorder:
                self.orders[day_label] = deorder
                self.pending_orders.add(day_label)
            else:
                self.orders.pop(day_label, None)
                self.pending_orders.discard(day_label)

    def plan_days(self, day_isos: list[str], template: str, cancel_lunch: bool = True) -> int:
        """Plans several whole days at once (one save, one repaint).

        Returns how many new days were planned (0 when nothing valid was
        given or persistence failed — memory is rolled back then).
        """
        entries: list[dict] = []
        for iso in day_isos or []:
            entry = normalize_planned_entry({"start_date": str(iso or ""),
                                             "end_date": str(iso or ""),
                                             "template": template,
                                             "cancel_lunch": bool(cancel_lunch)})
            if entry is not None and entry not in self.planned_skips and entry not in entries:
                entries.append(entry)
        if not entries:
            return 0
        _prev_skips = list(self.planned_skips)
        _prev_cancelled = set(self.cancelled_lunches)
        _prev_orders = dict(self.orders)
        _prev_pending = set(self.pending_orders)
        want_cancel = bool(cancel_lunch) and self.strava_enabled()
        for entry in entries:
            self.planned_skips.append(entry)
            if want_cancel:
                self._stage_lunch_cancel(entry)
        try:
            self.config.set("planned_skips", list(self.planned_skips))
            self.config.save()
        except Exception as exc:  # noqa: BLE001 - roll back memory to match disk
            self.planned_skips = _prev_skips
            self.cancelled_lunches = _prev_cancelled
            self.orders = _prev_orders
            self.pending_orders = _prev_pending
            print(f"Warning: could not persist planned skips: {exc}")
            self._emit()
            return 0
        self.tutorial_event("day_planned")
        self._emit()
        return len(entries)

    # -- year planner --------------------------------------------------------
    def first_plannable_day(self, now: datetime | None = None) -> date:
        """Today while any of today's lessons is still ahead, else tomorrow."""
        from strakalari.core.schedule import future_lessons

        now = now or datetime.now()
        today = now.date()
        key = today.strftime("%d.%m.%Y")
        try:
            rows = [r for r in (self.timetable().get(key, []) or []) if isinstance(r, dict)]
            if rows and future_lessons(rows, now, day=key):
                return today
        except Exception:
            pass
        return today + timedelta(days=1)

    def planner_target_days(self) -> int:
        """Whole days off per term the plan aims for (0 = as many as fit)."""
        try:
            return max(0, int(self.get("planner_target_days", 0) or 0))
        except (TypeError, ValueError):
            return 0

    def set_planner_target(self, days: int) -> bool:
        try:
            days = max(0, min(200, int(days)))
        except (TypeError, ValueError):
            days = 0
        return bool(self.save({"planner_target_days": days}))

    def planner_term_key(self) -> str | None:
        """Semester the planner shows (session memory; None = the running one)."""
        return getattr(self, "_planner_term", None)

    def select_planner_term(self, key: str | None) -> None:
        self._planner_term = key
        self._emit()

    def year_plan(self, now: datetime | None = None):
        """The whole-year plan (budgets, candidate days, balanced picks).

        Cached per input snapshot: the planner, absences and today views
        all ask for it on every render.
        """
        from strakalari.core.planner import YearPlan, build_year_plan

        now = now or datetime.now()
        if not self.timetable():
            return YearPlan(today=now.date(), first_day=now.date())
        first = self.first_plannable_day(now)
        try:
            dates, labels, _info = self.calendar_data()
        except Exception:
            dates, labels = set(), {}
        key = (
            getattr(self, "data_rev", 0), str(self.data.get("last_updated", "")),
            repr(self.planned_skips), now.date(), first, self.plan_reserve(),
            self.planner_target_days(), repr(self.get("subject_limits", {})),
            repr(self.get("absence_critical_pct", 25.0)), tuple(sorted(dates)),
            self.sem_close("sem1"), self.sem_close("sem2"),
        )
        cached = getattr(self, "_year_plan_cache", None)
        if cached is not None and cached[0] == key:
            return cached[1]
        states, _days = self.subject_states()
        try:
            baseline = self.stable_baseline()
        except Exception:
            baseline = None
        plan = build_year_plan(
            states, self.timetable(), baseline, dates, self.planned_skips,
            today=now.date(), first_day=first,
            sem1_close=self.sem_close("sem1"), sem2_close=self.sem_close("sem2"),
            school_year_end=self.get("school_year_end", ""),
            reserve_pct=self.plan_reserve(), target_days=self.planner_target_days(),
            free_labels=labels,
        )
        self._year_plan_cache = (key, plan)
        return plan

    def plan_impact(self, start_iso: str, end_iso: str, start_period: int | None = None,
                    end_period: int | None = None, now: datetime | None = None) -> list:
        """[(term, impact rows)] for a prospective range (what-if preview)."""
        entry = normalize_planned_entry({"start_date": start_iso, "end_date": end_iso,
                                         "start_period": start_period,
                                         "end_period": end_period})
        if entry is None:
            return []
        try:
            return self.year_plan(now).impact_of_entry(entry)
        except Exception:
            return []

    def unplan_entry(self, entry: dict) -> bool:
        """Removes one planned entry (range-aware lunch re-enable).

        Returns True when an entry was actually removed. Returns False
        when nothing matched or persistence failed.
        """
        target = normalize_planned_entry(entry)
        before = len(self.planned_skips)
        _prev_skips = list(self.planned_skips)
        _prev_cancelled = set(self.cancelled_lunches)
        _prev_orders = dict(self.orders)
        _prev_pending = set(self.pending_orders)
        removed_days: list[date] = entry_days(target) if target else []
        if target is not None:
            self.planned_skips = [e for e in self.planned_skips if e != target]
        else:
            self.planned_skips = [e for e in self.planned_skips if e != entry]
        remaining: set[str] = set()
        for kept in self.planned_skips:
            if not cancels_lunch(kept):
                continue
            for day in entry_days(kept):
                remaining.add(day.strftime("%d.%m.%Y"))
        for day in removed_days:
            day_label = day.strftime("%d.%m.%Y")
            if day_label in remaining:
                continue
            self.cancelled_lunches.discard(day_label)
            # Drop a staged planner deorder so the tab falls back to web truth.
            try:
                staged = self.orders.get(day_label)
            except Exception:
                staged = None
            if staged is not None and "&-1&" in str(staged):
                self.orders.pop(day_label, None)
                self.pending_orders.discard(day_label)
        try:
            self.config.set("planned_skips", list(self.planned_skips))
            self.config.save()
        except Exception as exc:  # noqa: BLE001 - roll back memory to match disk
            self.planned_skips = _prev_skips
            self.cancelled_lunches = _prev_cancelled
            self.orders = _prev_orders
            self.pending_orders = _prev_pending
            print(f"Warning: could not persist planned skips: {exc}")
            self._emit()
            return False
        self._emit()
        return len(self.planned_skips) < before

    def planned_for(self, day_iso: str) -> dict | None:
        day_iso = str(day_iso or "")
        try:
            day = date.fromisoformat(day_iso)
        except ValueError:
            for entry in self.planned_skips:
                if entry_start_iso(entry) == day_iso:
                    return entry
            return None
        for entry in self.planned_skips:
            days = entry_days(entry)
            if days and any(d == day for d in days):
                return entry
        return None

    def limit_subjects(self) -> list[str] | None:
        """Subjects the limits tab may list (stable + tracked), or None.

        Returns None when neither the stable baseline nor the subject
        directory is known — then the tab falls back to absence keys.
        """
        from strakalari.core.forecast import canon_subject

        allowed: set[str] | None = None
        try:
            tracked = self.tracked_subjects()
        except Exception:
            tracked = None
        if tracked:
            try:
                allowed = {canon_subject(n) for n in tracked}
            except Exception:
                allowed = None
        try:
            baseline = self.stable_baseline()
        except Exception:
            baseline = None
        stable_names: set[str] | None = None
        if baseline:
            try:
                from strakalari.core.schedule import stable_weekly_hours

                hours = stable_weekly_hours(baseline) or {}
                if hours:
                    stable_names = {canon_subject(n) for n in hours}
            except Exception:
                stable_names = None
        if allowed is None:
            allowed = stable_names
        elif stable_names:
            allowed = allowed & stable_names
        if not allowed:
            return None
        # Map back to display names from absence keys.
        try:
            absence_names = list(self.absence().keys())
        except Exception:
            return sorted(allowed)
        out: list[str] = []
        seen: set[str] = set()
        for name in absence_names:
            try:
                canon = canon_subject(name)
            except Exception:
                continue
            if canon in allowed and canon not in seen:
                seen.add(canon)
                out.append(str(name))
        for canon in sorted(allowed - seen):
            out.append(str(canon))
        return out

    def stable_baseline(self) -> dict:
        """The stable timetable: scraped 'Stálý' view when cached, else learned."""
        from strakalari.core.schedule import baseline_from_dict, learn_stable_schedule

        # Cached per data revision: views ask for it per lesson / per cell.
        key = (getattr(self, "data_rev", 0), id(self.data))
        if getattr(self, "_baseline_key", None) == key:
            return self._baseline
        baseline = None
        stored = self.data.get("stable_baseline")
        if isinstance(stored, dict) and stored:
            try:
                baseline = baseline_from_dict(stored) or None
            except Exception:
                baseline = None
        if baseline is None:
            baseline = learn_stable_schedule(self.timetable())
        self._baseline = baseline
        self._baseline_key = key
        return baseline

    def stable_complete(self) -> bool:
        """True when the cached baseline is the scraped template week.

        Only then is an empty slot a free period (added/missing detection
        applies). Missing key (old caches) or the learned fallback means
        "no data" — callers must use the notice heuristic instead.
        """
        try:
            return str(self.data.get("stable_baseline_source", "") or "") == "scraped"
        except Exception:
            return False
