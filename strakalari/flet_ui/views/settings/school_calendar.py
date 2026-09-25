"""Settings section: school calendar (preset, closures, own days off)."""

from __future__ import annotations

import flet as ft

from strakalari.core.i18n import get_language

from ... import components as C
from ...overlays import snack
from ...strings import S


class SchoolCalendarMixin:
    """Sections of :class:`SettingsView` (needs ``self.state`` / ``self.page``)."""

    # -- school calendar ------------------------------------------------------------
    def _calendar(self) -> list:
        from datetime import date as _date
        from datetime import timedelta as _timedelta

        from strakalari.core import school_presets as sp
        from strakalari.core.models import parse_cz_date

        state, tok, page = self.state, self.state.tok, self.page
        preset_id = str(state.get("school_preset_id", "") or "")
        preset = sp.get_preset(preset_id)
        preset_map = sp.preset_days(preset_id)
        user_map = sp.expand_entries(state.get("user_free_days", []))
        forced_map = sp.expand_entries(state.get("forced_school_days", []))
        p_sem1, p_sem2 = sp.preset_closes(preset_id)
        sem1 = state.sem_close("sem1")
        sem2 = state.sem_close("sem2")
        # Never display free days past the final sem2 closure — even preset
        # days (stored data is kept, only the timeline view is cut off).
        sem2_end = parse_cz_date(sem2) if sem2 else None
        in_scope = (lambda d: sem2_end is None or d <= sem2_end)
        known = set(preset_map) | set(user_map)
        effective = {d for d in known if d not in forced_map and in_scope(d)}
        forced_active = {d for d in forced_map if d in known and in_scope(d)}
        preset_n = len([d for d in preset_map if d not in forced_map and in_scope(d)])
        added_n = len([d for d in user_map if d in effective])
        forced_n = len(forced_active)

        def _refresh(msg: str = "") -> None:
            if msg:
                snack(page, msg)
            try:
                page.update()
            except Exception:
                pass

        def _store_list(key: str, mapping: dict) -> bool:
            items = [{"date": d.strftime("%d.%m.%Y"), "label": lbl}
                     for d, lbl in sorted(mapping.items()) if lbl]
            items += [d.strftime("%d.%m.%Y") for d in sorted(mapping) if not mapping[d]]
            try:
                ok = bool(state.save({key: items}))
            except Exception:
                return False
            if ok and key in ("forced_school_days", "user_free_days", "holidays"):
                try:
                    if sp.prune_orphan_forced(state.config.data):
                        state.save({"forced_school_days":
                                    state.config.data.get("forced_school_days", [])})
                except Exception:
                    pass
            return ok

        # -- preset + closures card (autosave, empty = preset) --------------

        preset_opts = sp.preset_options(get_language()) + [("custom", S("cal_custom_opt"))]
        known_ids = {pid for pid, _ in preset_opts}

        def _on_preset(e):
            if not state.save(
                {"school_preset_id": (e.control.value if e.control else "") or "custom"}):
                e.control.value = preset_id if preset_id in known_ids else "custom"
                snack(page, S("save_failed"))
                page.update()
                return
            try:
                if sp.prune_orphan_forced(state.config.data):
                    state.save({"forced_school_days":
                                state.config.data.get("forced_school_days", [])})
            except Exception:
                pass

        preset_dd = C.dropdown(
            tok, S("cal_preset"), preset_opts,
            preset_id if preset_id in known_ids else "custom",
            on_change=_on_preset,
        )

        def _parse_close(raw: str) -> str:
            cleaned = str(raw or "").strip()
            if cleaned and parse_cz_date(cleaned) is None:
                raise ValueError(S("cal_invalid_date"))
            return cleaned

        sem1_field = self._auto(S("cal_sem1"), "cal:sem1", "sem1_close",
                                str(state.get("sem1_close", "") or ""),
                                hint=f"{p_sem1 or S('cal_auto')} · {S('cal_preset_hint')}",
                                parse=_parse_close)
        sem2_field = self._auto(S("cal_sem2"), "cal:sem2", "sem2_close",
                                str(state.get("sem2_close", "") or ""),
                                hint=f"{p_sem2 or S('cal_auto')} · {S('cal_preset_hint')}",
                                parse=_parse_close)
        summary = S("cal_summary").format(preset=preset_n, added=added_n, forced=forced_n)
        closes = S("cal_closes").format(a=sem1 or S("cal_auto"), b=sem2 or S("cal_auto"))
        head_rows: list = [preset_dd, C.txt(summary, tok, size=tok.fs_small, muted=True),
                           C.txt(closes, tok, size=tok.fs_small, muted=True)]
        preset_bands = sp.preset_marks_bands(preset_id)
        if preset_bands is not None:
            head_rows.append(C.txt(
                S("cal_marks_bands").format(bands=" / ".join(f"{b:g}" for b in preset_bands)),
                tok, size=tok.fs_small, muted=True))
        head_rows += [sem1_field, sem2_field]
        out: list = [C.form_card(*[r for r in head_rows if r is not None], tok=tok)]

        # -- add single / range (immediate) --------------------------------
        def _add_single(e):
            raw = state.draft("cal:add_date", "").strip()
            label = state.draft("cal:add_label", "").strip()
            day = parse_cz_date(raw)
            if day is None:
                snack(page, S("cal_invalid_date"))
                return
            if day in forced_map and day in known:
                forced_map.pop(day, None)
                ok = _store_list("forced_school_days", forced_map)
                state.clear_drafts("cal:add_")
                _refresh(S("cal_added") if ok else S("save_failed"))
                return
            if day in effective:
                snack(page, S("cal_duplicate"))
                return
            if day in user_map:
                snack(page, S("cal_duplicate"))
                return
            user_map[day] = label
            ok = _store_list("user_free_days", user_map)
            state.clear_drafts("cal:add_")
            _refresh(S("cal_added") if ok else S("save_failed"))

        def _add_range(e):
            start = parse_cz_date(state.draft("cal:from_", "").strip())
            end = parse_cz_date(state.draft("cal:to", "").strip())
            label = state.draft("cal:range_label", "").strip()
            if start is None or end is None or end < start:
                snack(page, S("cal_invalid_range"))
                return
            restored = 0
            added = 0
            cursor = start
            while cursor <= end:
                if cursor in forced_map and cursor in known:
                    forced_map.pop(cursor, None)
                    restored += 1
                elif cursor not in effective and cursor not in user_map:
                    user_map[cursor] = label
                    added += 1
                cursor += _timedelta(days=1)
            _store_ok = _store_list("forced_school_days", forced_map)
            _store_ok = _store_list("user_free_days", user_map) and _store_ok
            state.clear_drafts("cal:from_")
            state.clear_drafts("cal:to")
            state.clear_drafts("cal:range_label")
            _refresh(S("cal_range_added").format(n=added + restored) if _store_ok else S("save_failed"))

        out.append(C.form_card(
            C.txt(S("cal_free_days"), tok, bold=True),
            self._text(S("cal_date"), "cal:add_date", ""),
            self._text(S("cal_label"), "cal:add_label", ""),
            ft.Row([C.primary_button(S("cal_add_single"), tok, on_click=_add_single)],
                   spacing=8, wrap=True),
            C.divider(tok),
            self._text(S("cal_from"), "cal:from_", ""),
            self._text(S("cal_to"), "cal:to", ""),
            self._text(S("cal_label"), "cal:range_label", ""),
            ft.Row([C.primary_button(S("cal_add_range"), tok, on_click=_add_range)],
                   spacing=8, wrap=True),
            tok=tok,
        ))

        # -- timeline -------------------------------------------------------
        def _restore(e, day=None):
            forced_map.pop(day, None)
            ok = _store_list("forced_school_days", forced_map)
            _refresh(S("saved") if ok else S("save_failed"))

        def _clear_past(e):
            today = _date.today()
            for d in [d for d in user_map if d < today]:
                user_map.pop(d, None)
            for d in [d for d in forced_map if d < today]:
                forced_map.pop(d, None)
            ok = _store_list("user_free_days", user_map)
            ok = _store_list("forced_school_days", forced_map) and ok
            _refresh(S("saved") if ok else S("save_failed"))

        rows: list = []
        today = _date.today()
        show_past = bool(getattr(state, "show_past_calendar", False))

        # Group consecutive days with the same label + source into ranges
        # (e.g. the whole Christmas break is one row, not eight).
        def _grouped(days: list) -> list:
            groups: list = []
            for day in sorted(days):
                in_preset = day in preset_map
                label = (preset_map.get(day) or user_map.get(day) or "")
                if groups and groups[-1][1] == day - _timedelta(days=1) \
                        and groups[-1][2] == label and groups[-1][3] == in_preset:
                    groups[-1][1] = day
                else:
                    groups.append([day, day, label, in_preset])
            return groups

        def _range_title(start, end, label: str) -> tuple[str, str | None]:
            if start == end:
                return f"{C.day_name(start, short=True)} {start.strftime('%d.%m.%Y')}", label or None
            n = (end - start).days + 1
            title = (f"{start.strftime('%d.%m.%Y')} – {end.strftime('%d.%m.%Y')} "
                     f"· {S('cal_range_days').format(n=n)}")
            return title, label or None

        past_hidden = 0
        for start, end, label, in_preset in _grouped(list(effective)):
            if end < today and not show_past:
                past_hidden += (end - start).days + 1
                continue
            day_label, sub = _range_title(start, end, label)
            left = C.txt(day_label, tok, bold=True)
            sub_ctl = C.txt(sub, tok, size=tok.fs_small, muted=True) if sub else None
            chip = (C.badge(sp.preset_title(preset, get_language()) if preset else "?",
                            tok, kind="info") if in_preset
                    else C.badge(S("cal_my"), tok, kind="sent"))
            if in_preset:
                days_in_group = []
                cursor = start
                while cursor <= end:
                    days_in_group.append(cursor)
                    cursor += _timedelta(days=1)

                def _cancel_group(e, days=tuple(days_in_group)):
                    for d in days:
                        forced_map[d] = ""
                    ok = _store_list("forced_school_days", forced_map)
                    _refresh(S("saved") if ok else S("save_failed"))

                action = C.danger_button(S("cal_cancel_preset"), tok,
                                         on_click=_cancel_group)
            else:
                days_in_group = []
                cursor = start
                while cursor <= end:
                    days_in_group.append(cursor)
                    cursor += _timedelta(days=1)

                def _delete_group(e, days=tuple(days_in_group)):
                    for d in days:
                        user_map.pop(d, None)
                    ok = _store_list("user_free_days", user_map)
                    _refresh(S("saved") if ok else S("save_failed"))

                action = (ft.IconButton(ft.Icons.DELETE_OUTLINE, tooltip=S("delete"),
                                        on_click=_delete_group)
                          if len(days_in_group) == 1 else
                          C.danger_button(S("delete"), tok, on_click=_delete_group))
            rows.append(ft.Row(
                [ft.Column([left] + ([sub_ctl] if sub_ctl else []), spacing=2, expand=True, tight=True),
                 chip, action],
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ))
        for day in sorted(forced_active):
            if day < today and not show_past:
                past_hidden += 1
                continue
            label = preset_map.get(day) or user_map.get(day) or ""
            rows.append(ft.Row(
                [ft.Column([C.txt(f"{C.day_name(day, short=True)} {day.strftime('%d.%m.%Y')}", tok, bold=True),
                            C.txt(S("cal_school_override") + (f" · {label}" if label else ""),
                                  tok, size=tok.fs_small, muted=True)],
                           spacing=2, expand=True, tight=True),
                 C.ghost_button(S("cal_restore"), tok,
                                on_click=lambda e, d=day: _restore(e, d))],
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ))
        if past_hidden:
            def _toggle_past(e):
                state.set_show_past_calendar(not show_past)

            rows.append(ft.Row(
                [C.ghost_button(
                    (S("cal_hide_past") if show_past
                     else f"{S('cal_show_past')} ({past_hidden})"),
                    tok, on_click=_toggle_past)],
                spacing=8, wrap=True,
            ))
        elif show_past:
            def _hide_past(e):
                state.set_show_past_calendar(False)

            rows.append(ft.Row(
                [C.ghost_button(S("cal_hide_past"), tok, on_click=_hide_past)],
                spacing=8, wrap=True,
            ))
        if not rows:
            rows = [C.txt(S("cal_no_days"), tok, faint=True)]
        else:
            rows.append(ft.Row(
                [C.ghost_button(S("cal_clear_past"), tok, on_click=_clear_past)],
                spacing=8, wrap=True,
            ))
        out.append(C.form_card(C.txt(S("cal_free_days"), tok, bold=True), *rows, tok=tok))
        return out
