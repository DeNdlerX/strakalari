"""UI strings for the Flet frontend (Czech + English).

``S(key)`` reads the active language from ``core.i18n`` so the setting is
shared with the rest of the app; missing keys fall back to Czech, then to
the key itself. Views must use ``S()`` for every user-visible string —
no hardcoded text outside this file.
"""

from __future__ import annotations

from strakalari.core.i18n import get_language

STRINGS: dict[str, dict[str, str]] = {
    # Shell ----------------------------------------------------------------
    "app_title": {"cs": "Strakaláři", "en": "Strakaláři"},
    "nav_today": {"cs": "Dnes", "en": "Today"},
    "nav_timetable": {"cs": "Rozvrh", "en": "Timetable"},
    "nav_absences": {"cs": "Absence", "en": "Absences"},
    "nav_planner": {"cs": "Plánovač", "en": "Planner"},
    "nav_lunches": {"cs": "Obědy", "en": "Lunches"},
    "nav_settings": {"cs": "Nastavení", "en": "Settings"},
    "refresh_data": {"cs": "Obnovit data", "en": "Refresh data"},
    "refreshing": {"cs": "Obnovuji…", "en": "Refreshing…"},
    "refresh_bakalari": {"cs": "Jen Bakaláři", "en": "Bakaláři only"},
    "refresh_strava": {"cs": "Jen Strava", "en": "Strava only"},
    "refresh_all": {"cs": "Vše", "en": "Everything"},
    "refresh_scope": {"cs": "Rozsah obnovy", "en": "Refresh scope"},
    "nav_activity": {"cs": "Aktivita", "en": "Activity"},

    "tray_open": {"cs": "Otevřít Strakaláře", "en": "Open Strakaláři"},
    "tray_refresh": {"cs": "Obnovit nyní", "en": "Refresh now"},
    "tray_quit": {"cs": "Ukončit", "en": "Quit"},
    "last_updated": {"cs": "Aktualizováno", "en": "Updated"},
    "no_data": {"cs": "Zatím žádná data", "en": "No data yet"},

    # Today ----------------------------------------------------------------
    "today_title": {"cs": "Dnešní přehled", "en": "Today at a glance"},

    "pending_excuses": {"cs": "Čekající omluvenky", "en": "Pending excuses"},

    "excused_btn": {"cs": "Omluvit", "en": "Excuse"},
    "ignore_btn": {"cs": "Ignorovat", "en": "Ignore"},
    "ignore_day": {"cs": "Ignorovat den", "en": "Ignore day"},
    "ignored_msg": {"cs": "Ignorováno — omluveno jinde.", "en": "Ignored — excused elsewhere."},
    "ignore_save_failed": {"cs": "Změnu seznamu ignorovaných se nepodařilo uložit — zkuste to znovu.",
                           "en": "Could not save the ignored list — try again."},
    "ignored_title": {"cs": "Ignorované", "en": "Ignored"},
    "restore": {"cs": "Vrátit", "en": "Restore"},
    "undo": {"cs": "Zpět", "en": "Undo"},
    "excuse_sent": {"cs": "Omluvenka odeslána", "en": "Excuse sent"},
    "excuse_dry_run": {"cs": "Nanečisto — nic nebylo odesláno", "en": "Dry run — nothing was sent"},
    "excuse_sending": {"cs": "Omluvenka se odesílá…", "en": "Sending excuse…"},
    "excuse_failed": {"cs": "Omluvenku se nepodařilo odeslat", "en": "Could not send the excuse"},
    "need_credentials": {
        "cs": "Vyplňte přihlášení v Nastavení a stiskněte Obnovit.",
        "en": "Fill in your logins in Settings and press Refresh.",
    },
    "next_lesson": {"cs": "Další hodina", "en": "Next lesson"},
    "no_lessons_today": {"cs": "Dnes žádné vyučování", "en": "No lessons today"},
    "week_changes": {"cs": "Změny tento týden", "en": "Changes this week"},
    "no_changes": {"cs": "Žádné změny", "en": "No changes"},
    "lunch_today": {"cs": "Dnešní oběd", "en": "Today's lunch"},
    "no_lunch": {"cs": "Žádný oběd objednán", "en": "No lunch ordered"},
    # Timetable -------------------------------------------------------------
    "timetable_title": {"cs": "Rozvrh", "en": "Timetable"},
    "view_table": {"cs": "Tabulka", "en": "Grid"},
    "view_list": {"cs": "Seznam", "en": "List"},
    "period": {"cs": "Hodina", "en": "Period"},

    "week": {"cs": "Týden", "en": "Week"},
    "prev_week": {"cs": "Předchozí týden", "en": "Previous week"},
    "next_week": {"cs": "Další týden", "en": "Next week"},
    "this_week": {"cs": "Tento týden", "en": "This week"},
    "stable_timetable": {"cs": "Stálý rozvrh", "en": "Stable timetable"},
    "stable_view": {"cs": "Stálý", "en": "Stable"},
    "room": {"cs": "Učebna", "en": "Room"},
    "teacher": {"cs": "Učitel", "en": "Teacher"},

    "status_late": {"cs": "Pozdní příchod", "en": "Late arrival"},
    "status_soon": {"cs": "Předčasný odchod", "en": "Left early"},
    "status_early": {"cs": "Předčasný odchod", "en": "Left early"},
    "status_absent": {"cs": "Absence", "en": "Absent"},
    "status_lesson_cancelled": {"cs": "Odpadá", "en": "Cancelled"},
    "status_excused": {"cs": "Omluveno", "en": "Excused"},
    "today_badge": {"cs": "Dnes", "en": "Today"},
    "group": {"cs": "Skupina", "en": "Group"},
    "theme": {"cs": "Téma", "en": "Topic"},

    "legend_change": {"cs": "Změna rozvrhu", "en": "Schedule change"},
    "legend_late_early": {"cs": "Pozdní příchod / odchod", "en": "Late / left early"},
    "legend_now": {"cs": "Teď / další hodina", "en": "Now / next lesson"},
    "tag_substitution": {"cs": "Suplování", "en": "Substitution"},
    "tag_room_change": {"cs": "Jiná učebna", "en": "Room change"},
    "tag_added": {"cs": "Hodina navíc", "en": "Extra lesson"},


    "close": {"cs": "Zavřít", "en": "Close"},
    # Absences ---------------------------------------------------------------
    "absence_title": {"cs": "Absence", "en": "Absences"},
    "avg_absence": {"cs": "Průměrná absence", "en": "Average absence"},
    "warn_subjects": {"cs": "S varováním", "en": "Warning"},
    "crit_subjects": {"cs": "Kritické", "en": "Critical"},
    "col_subject": {"cs": "Předmět", "en": "Subject"},

    "col_limit": {"cs": "Limit", "en": "Limit"},
    "col_safe": {"cs": "Zbývá hodin", "en": "Hours left"},

    "state_ok": {"cs": "V pořádku", "en": "Fine"},
    "state_warning": {"cs": "Varování", "en": "Warning"},
    "state_critical": {"cs": "Kritické", "en": "Critical"},
    # Marks ------------------------------------------------------------------
    "nav_marks": {"cs": "Známky", "en": "Marks"},
    "marks_title": {"cs": "Známky", "en": "Marks"},
    "marks_total": {"cs": "Známek", "en": "Marks"},
    "marks_average": {"cs": "Průměr", "en": "Average"},
    "marks_weight": {"cs": "Váha", "en": "Weight"},
    "marks_subjects_n": {"cs": "Předměty ({n})", "en": "Subjects ({n})"},
    "marks_report": {"cs": "Odhad vysvědčení", "en": "Report card estimate"},
    "marks_new": {"cs": "Nové (7 dní)", "en": "New (7 days)"},
    "marks_new_badge": {"cs": "{n} nové", "en": "{n} new"},
    "marks_count": {"cs": "Známek: {n}", "en": "{n} marks"},
    "marks_last": {"cs": "naposledy {day}", "en": "last {day}"},
    "marks_final": {"cs": "Na vysvědčení", "en": "Final grade"},
    "marks_final_tooltip": {"cs": "Odhad známky na vysvědčení", "en": "Estimated report-card grade"},
    "marks_trend": {"cs": "Vývoj průměru", "en": "Average over time"},
    "marks_trend_up": {"cs": "Poslední známka průměr zlepšila", "en": "The latest mark improved the average"},
    "marks_trend_down": {"cs": "Poslední známka průměr zhoršila", "en": "The latest mark lowered the average"},
    "marks_scale_auto": {"cs": "Auto", "en": "Auto"},
    "marks_scale_grade": {"cs": "1–5", "en": "1–5"},
    "marks_scale_percent": {"cs": "%", "en": "%"},
    "marks_scale_tooltip": {
        "cs": "Stupnice: Auto pozná známky 1–5 i procenta u každého předmětu zvlášť",
        "en": "Scale: Auto tells 1–5 marks and percentages apart per subject",
    },
    "marks_detected": {"cs": "Automaticky zjištěno: {scale}", "en": "Detected automatically: {scale}"},
    "marks_scale_global": {
        "cs": "Podle nastavení nahoře: {scale} (Auto = jako ostatní předměty)",
        "en": "Following the switch above: {scale} (Auto = same as other subjects)",
    },
    "marks_sort_name": {"cs": "A–Z", "en": "A–Z"},
    "marks_sort_average": {"cs": "Nejhorší", "en": "Worst first"},
    "marks_sort_recent": {"cs": "Nedávné", "en": "Recent"},
    "marks_pick_hint": {
        "cs": "Klikněte na předmět pro detail, výpočet a predikci známek.",
        "en": "Click a subject for details, the calculator and mark predictions.",
    },
    "marks_recent": {"cs": "Poslední známky", "en": "Latest marks"},
    "marks_no_recent": {"cs": "Zatím žádné známky.", "en": "No marks yet."},
    "marks_planned": {"cs": "Plánované zkoušení", "en": "Planned tests"},
    "marks_planned_test": {"cs": "Plánovaná známka", "en": "Planned mark"},
    "marks_planned_count": {"cs": "plánováno: {n}", "en": "{n} planned"},
    "marks_use_weight": {"cs": "Do predikce", "en": "Predict"},
    "marks_bands": {"cs": "Převod procent na známky", "en": "Percent to grade"},
    "marks_bands_hint": {
        "cs": "Horní hranice známek 2–5 jako v tabulce převodu v Bakalářích — hraniční hodnota už je horší známka (87 % = 2). Použije se u odhadu a při převodu mezi stupnicemi.",
        "en": "Top of grades 2–5, as in Bakaláři's conversion table — a boundary value is already the worse grade (87 % = 2). Used for estimates and scale conversion.",
    },
    "marks_band_label": {"cs": "Známka {grade}", "en": "Grade {grade}"},
    "marks_bands_default": {"cs": "Výchozí", "en": "Default"},
    "cal_marks_bands": {
        "cs": "Převod procent: známky 2–5 začínají na {bands} % (karta Známky)",
        "en": "Percent table: grades 2–5 start at {bands} % (Marks tab)",
    },
    "marks_bands_use_school": {"cs": "Podle školy", "en": "Use school's table"},
    "marks_bands_src_preset": {"cs": "Převzato z předvolby {school}", "en": "From the {school} preset"},
    "marks_bands_src_user": {"cs": "Vlastní nastavení", "en": "Your own values"},
    "marks_bands_src_default": {
        "cs": "Výchozí převod (škola ho v předvolbě nemá)",
        "en": "Default table (the school preset has none)",
    },
    "marks_bands_saved": {"cs": "Převod procent uložen", "en": "Percent bands saved"},
    "marks_bands_invalid": {
        "cs": "Zadejte čtyři klesající hodnoty mezi 0 a 100.",
        "en": "Enter four decreasing values between 0 and 100.",
    },
    "marks_save": {"cs": "Uložit", "en": "Save"},
    "marks_predictor": {"cs": "Známky a predikce", "en": "Marks & prediction"},
    "marks_predictor_hint": {
        "cs": "Přidávejte, upravujte a mažte známky nanečisto — skutečné známky zůstanou beze změny. Predikce platí do zavření aplikace.",
        "en": "Add, edit and delete marks as a what-if — your real marks stay untouched. Predictions last until you close the app.",
    },
    "marks_predicted": {"cs": "Predikce", "en": "Predicted"},
    "marks_predicted_short": {"cs": "predikce", "en": "predicted"},
    "marks_prediction_on": {"cs": "Predikce je zapnutá ({n} předm.)", "en": "Prediction on ({n} subj.)"},
    "marks_prediction_hint": {
        "cs": "Průměry počítají i s vymyšlenými změnami. Skutečné známky se nemění.",
        "en": "Averages include your what-if changes. Real marks are unchanged.",
    },
    "marks_reset": {"cs": "Zrušit predikci", "en": "Reset prediction"},
    "marks_reset_all": {"cs": "Zrušit vše", "en": "Reset all"},
    "marks_mark": {"cs": "Známka", "en": "Mark"},
    "marks_add": {"cs": "Přidat", "en": "Add"},
    "marks_edit": {"cs": "Upravit v predikci", "en": "Edit in prediction"},
    "marks_delete": {"cs": "Smazat", "en": "Delete"},
    "marks_leave_out": {"cs": "Vynechat z predikce", "en": "Leave out of prediction"},
    "marks_restore_real": {"cs": "Vrátit skutečnou známku", "en": "Back to the real mark"},
    "marks_hypothetical": {"cs": "Vymyšlená známka", "en": "What-if mark"},
    "marks_no_topic": {"cs": "Bez tématu", "en": "No topic"},
    "marks_written": {"cs": "psáno {day}", "en": "written {day}"},
    "marks_was": {"cs": "skutečně {mark} (váha {weight})", "en": "really {mark} (weight {weight})"},
    "marks_not_counted": {"cs": "nezapočítává se", "en": "not counted"},
    "marks_none_yet": {"cs": "V tomto předmětu zatím nejsou známky.", "en": "No marks in this subject yet."},
    "marks_invalid": {
        "cs": "Neplatná známka nebo váha — např. 1, 2-, 85 % nebo 17/20; váha kladné číslo.",
        "en": "Invalid mark or weight — e.g. 1, 2-, 85 % or 17/20; weight a positive number.",
    },
    "marks_need_title": {"cs": "Co potřebuji", "en": "What do I need"},
    "marks_target": {"cs": "Cíl", "en": "Goal"},
    "marks_target_option": {"cs": "Na vysvědčení {grade}", "en": "Final grade {grade}"},
    "marks_need_any": {
        "cs": "Na {grade} to vyjde s jakoukoli další známkou.",
        "en": "Any next mark keeps you at {grade}.",
    },
    "marks_need_grade": {
        "cs": "Na {grade} potřebujete z další známky nejhůř {mark}.",
        "en": "For a {grade} your next mark must be {mark} or better.",
    },
    "marks_need_pct": {
        "cs": "Na {grade} potřebujete z další známky aspoň {mark}.",
        "en": "For a {grade} your next mark must be at least {mark}.",
    },
    "marks_need_many": {
        "cs": "Jednou známkou to na {grade} nevyjde — potřebujete {n}× {mark} s váhou {weight}.",
        "en": "One mark is not enough for a {grade} — you need {n}× {mark} at weight {weight}.",
    },
    "marks_need_impossible": {
        "cs": "Na {grade} to s touto váhou prakticky nevyjde.",
        "en": "A {grade} is out of reach at this weight.",
    },
    # Planner -----------------------------------------------------------------
    "planner_title": {"cs": "Plánovač absence", "en": "Absence planner"},
    "planner_desc": {
        "cs": "Kolik si ještě můžete dovolit vynechat — a kdy, aby to vyšlo rovnoměrně na celé pololetí.",
        "en": "How much you can still afford to miss — and when, so it spreads evenly over the semester.",
    },
    "planner_need_refresh": {
        "cs": "Nejprve stiskněte Obnovit data, ať se naučím stálý rozvrh — bez něj neumím počítat.",
        "en": "Press Refresh data first so I can learn your stable timetable — I can't plan without it.",
    },
    "lessons_count": {"cs": "hodin", "en": "lessons"},
    "plan_skip": {"cs": "Naplánovat dovolenou", "en": "Plan vacation"},
    "skip_planned": {"cs": "Dovolená naplánována, oběd odhlášen", "en": "Vacation planned, lunch cancelled"},
    "choose_template": {"cs": "Způsob omluvení", "en": "How to excuse it"},
    "excuse_day": {"cs": "Omluvit celý den", "en": "Excuse whole day"},
    "confirm": {"cs": "Potvrdit", "en": "Confirm"},
    "cancel": {"cs": "Zrušit", "en": "Cancel"},
    "holidays_note": {
        "cs": "Prázdniny a svátky jsou z plánování vynechány.",
        "en": "Holidays are excluded from planning.",
    },
    # Lunches ------------------------------------------------------------------
    "lunch_title": {"cs": "Obědy", "en": "Lunches"},
    "ai_prefs": {"cs": "Co vám chutná / nechutná (AI filtr)", "en": "Likes / dislikes (AI filter)"},
    "ai_prefs_hint": {
        "cs": "Napište volně, např. „nemám rád vepřové, preferuji lehká jídla“",
        "en": "Write freely, e.g. “no pork, prefer light meals”",
    },


    "ordered": {"cs": "Objednáno", "en": "Ordered"},
    "send_orders": {"cs": "Odeslat objednávky do Stravy", "en": "Send orders to Strava"},
    "orders_sending": {"cs": "Objednávky se odesílají…", "en": "Sending orders…"},
    "orders_sent": {"cs": "Objednávky odeslány", "en": "Orders sent"},
    "orders_dry_run": {"cs": "Nanečisto — nic nebylo odesláno", "en": "Dry run — nothing was ordered"},
    "orders_failed": {"cs": "Objednávky se nepodařilo odeslat", "en": "Could not send the orders"},
    "session_busy": {
        "cs": "Právě probíhá jiná obnova nebo odesílání (lišta nebo jiné okno). Zkuste to za chvíli.",
        "en": "Another refresh or submit is running (tray or another window). Try again in a moment.",
    },

    "skipped_reason": {"cs": "Přeskočeno", "en": "Skipped"},
    "recommend": {"cs": "Doporučit (AI)", "en": "Recommend (AI)"},
    "ai_started": {"cs": "AI doporučení spuštěno…", "en": "AI recommendation started…"},
    "ai_running": {"cs": "AI vybírá obědy…", "en": "AI is picking lunches…"},
    "ai_already_running": {"cs": "AI doporučení již běží…", "en": "AI recommendation is already running…"},
    "ai_failed": {"cs": "AI doporučení selhalo", "en": "AI recommendation failed"},
    # Settings -------------------------------------------------------------------
    "settings_title": {"cs": "Nastavení", "en": "Settings"},
    "sec_accounts": {"cs": "Účty", "en": "Accounts"},
    "sec_group_school": {"cs": "Škola a účty", "en": "School & accounts"},
    "sec_group_automation": {"cs": "Automatizace", "en": "Automation"},
    "sec_group_app": {"cs": "Aplikace", "en": "App"},
    "sec_group_advanced": {"cs": "Pokročilé", "en": "Advanced"},
    "sec_limits": {"cs": "Limity předmětů", "en": "Subject limits"},
    "sec_templates": {"cs": "Šablony omluvenek", "en": "Excuse templates"},
    "sec_rules": {"cs": "Automatizace", "en": "Automation"},
    "sec_browser": {"cs": "Prohlížeč a běh na pozadí", "en": "Browser & background"},
    "sec_ai": {"cs": "AI doporučení", "en": "AI recommendations"},
    "sec_advanced": {"cs": "Pokročilé", "en": "Advanced"},
    "sec_diagnostics": {"cs": "Diagnostika", "en": "Diagnostics"},
    "sec_appearance": {"cs": "Vzhled", "en": "Appearance"},
    "sec_notifications": {"cs": "Oznámení", "en": "Notifications"},
    "theme_dark": {"cs": "Tmavý", "en": "Dark"},
    "theme_light": {"cs": "Světlý", "en": "Light"},
    "language": {"cs": "Jazyk", "en": "Language"},
    "density": {"cs": "Hustota", "en": "Density"},

    "density_compact": {"cs": "Kompaktní", "en": "Compact"},

    "saved": {"cs": "Uloženo", "en": "Saved"},
    "save_failed": {"cs": "Nepodařilo se uložit nastavení", "en": "Could not save settings"},
    "check_interval": {"cs": "Automatická kontrola každých (min)", "en": "Auto-check every (min)"},
    "tpl_late": {"cs": "Pozdní příchody", "en": "Late arrivals"},
    "tpl_soon": {"cs": "Předčasné odchody", "en": "Early leaves"},
    "tpl_short": {"cs": "Krátké absence", "en": "Short absences"},
    "tpl_long": {"cs": "Dlouhé absence", "en": "Long absences"},
    "signature": {"cs": "Podpis", "en": "Signature"},
    "add": {"cs": "Přidat", "en": "Add"},
    "delete": {"cs": "Smazat", "en": "Delete"},
    "bakalari_url": {"cs": "URL Bakalářů", "en": "Bakaláři URL"},
    "username": {"cs": "Uživatelské jméno", "en": "Username"},
    "password": {"cs": "Heslo", "en": "Password"},
    "use_strava": {"cs": "Používat Stravu", "en": "Use Strava"},
    "canteen_id": {"cs": "Číslo jídelny", "en": "Canteen ID"},

    "default_limit": {"cs": "Výchozí limit (%)", "en": "Default limit (%)"},
    "warn_limit": {"cs": "Varovný limit (%)", "en": "Warning limit (%)"},
    "reserve_limit": {"cs": "Rezerva na nemoc (%)", "en": "Illness reserve (%)"},
    "reserve_hint": {
        "cs": "Kolik % zbývajících hodin každého předmětu si plánovač nechá stranou na nemoc a nečekané absence. Rezerva se s blížící uzávěrkou zmenšuje.",
        "en": "Share of each subject's remaining lessons the planner keeps aside for illness and surprises. It shrinks as the closure approaches.",
    },
    "safe_to": {"cs": "Bezpečně do", "en": "Safe to"},

    # Activity ------------------------------------------------------------------
    "activity_title": {"cs": "Aktivita a stav", "en": "Activity & status"},
    "status_idle": {"cs": "Nečinné", "en": "Idle"},

    "status_error": {"cs": "Chyba", "en": "Error"},
    "status_ok": {"cs": "V pořádku", "en": "Healthy"},

    "last_run": {"cs": "Poslední běh", "en": "Last run"},
    "next_run": {"cs": "Další běh", "en": "Next run"},
    "run_history": {"cs": "Historie běhů", "en": "Run history"},
    "live_log": {"cs": "Živý protokol", "en": "Live log"},
    "clear_log": {"cs": "Vymazat protokol", "en": "Clear log"},
    "no_runs_yet": {"cs": "Zatím žádný běh — stiskněte Obnovit.", "en": "No runs yet — press Refresh."},
    "no_log_yet": {"cs": "Zatím žádné záznamy.", "en": "No log entries yet."},
    "refresh_started": {"cs": "Obnovování spuštěno", "en": "Refresh started"},
    "already_running": {"cs": "Obnovování již běží…", "en": "A refresh is already running…"},
    "cancel_refresh": {"cs": "Zrušit", "en": "Cancel"},

    # Settings — new fields -------------------------------------------------------
    "strava_url": {"cs": "URL Stravy", "en": "Strava URL"},
    "show_browser": {"cs": "Zobrazit prohlížeč při obnově", "en": "Show browser window during refresh"},
    "show_browser_hint": {
        "cs": "Když je zapnuto, uvidíte živé okno prohlížeče, jak prochází Bakaláře a Stravu.",
        "en": "When on, you will see the live browser window going through Bakaláři and Strava.",
    },
    "maximize_browser": {"cs": "Maximalizovat okno prohlížeče", "en": "Maximize browser window"},
    "autostart": {"cs": "Spouštět po startu systému", "en": "Start with the system"},
    "minimize_to_tray": {"cs": "Minimalizovat do oznamovací oblasti", "en": "Minimize to tray"},
    "test_bakalari": {"cs": "Otestovat Bakaláře", "en": "Test Bakaláři login"},
    "test_strava": {"cs": "Otestovat Stravu", "en": "Test Strava login"},
    "testing": {"cs": "Testuji…", "en": "Testing…"},
    "test_ai_key_log": {"cs": "Test AI klíče ({model})…", "en": "Testing AI key ({model})…"},
    "test_login_log": {"cs": "Test přihlášení ({service})…", "en": "Testing {service} login…"},
    "connection_ok": {"cs": "Připojení funguje", "en": "Connection works"},
    "connection_failed": {"cs": "Připojení selhalo", "en": "Connection failed"},
    "gemini_key": {"cs": "Gemini API klíč", "en": "Gemini API key"},
    "gemini_model": {"cs": "Gemini model", "en": "Gemini model"},
    "gemini_key_hint": {
        "cs": "Potřebné jen pro AI doporučení obědů — klíč je zdarma. Necháte-li prázdné, použije se lokální výběr.",
        "en": "Only needed for AI lunch recommendations — the key is free. Leave empty for local picks.",
    },
    "ai_key_link": {"cs": "Získat klíč zdarma", "en": "Get a free key"},
    "ai_key_steps": {
        "cs": "Zdarma bez karty: odkaz → Create API key → klíč vložte sem a otestujte. Klíč zůstává šifrovaně jen v tomto počítači.",
        "en": "Free, no card needed: open the link → Create API key → paste it here and test. The key stays encrypted on this computer.",
    },
    "ai_model_hint": {
        "cs": "Nechte výchozí — měňte jen když test selže.",
        "en": "Keep the default — change it only if the test fails.",
    },
    "ai_auto_enable": {"cs": "Automaticky vybírat obědy při obnovení", "en": "Auto-pick lunches on refresh"},
    "ai_auto_hint": {
        "cs": "Při obnovení v režimu Automaticky: je-li Gemini dle intervalu na řadě a je klíč, vybere AI, jinak filtr. Běží max 1× za X dní.",
        "en": "On refresh in Automatic mode: Gemini picks when due and a key is set, otherwise the filter. Runs at most once per X days.",
    },
    "ai_prompt": {"cs": "Zadání pro AI (prompt)", "en": "AI prompt"},
    "ai_prompt_hint": {
        "cs": "Volný text, např. „nemám rád vepřové, preferuji lehká jídla“. Stejné jako AI filtr v Obědech.",
        "en": "Free text, e.g. “no pork, prefer light meals”. Same as the AI filter in Lunches.",
    },
    "ai_interval": {"cs": "AI spouštět každých (dní)", "en": "Run AI every (days)"},
    "ai_interval_hint": {"cs": "1–30 dní, výchozí 2. Mezitím vybírá filtr.", "en": "1–30 days, default 2. The filter picks in between."},
    "ai_last_run": {"cs": "Naposledy AI vybralo", "en": "AI last ran"},
    "ai_never": {"cs": "zatím nikdy", "en": "never yet"},
    "auto_excuse_log": {"cs": "Automatické omlouvání…", "en": "Auto-excusing…"},
    "auto_excuses_sent": {"cs": "Automaticky odesláno omluvenek: {n}", "en": "Auto-sent excuses: {n}"},
    "auto_excuse_failed": {"cs": "Automatické omluvení selhalo: {err}", "en": "Auto-excuse failed: {err}"},
    "auto_lunch_log": {"cs": "Automatický výběr obědů…", "en": "Auto-picking lunches…"},
    "auto_lunch_sent": {"cs": "Automaticky objednáno obědů: {n}", "en": "Auto-ordered lunches: {n}"},
    "auto_lunch_none": {"cs": "Automatika: není co objednat.", "en": "Auto: nothing to order."},
    "auto_lunch_failed": {"cs": "Automatické objednání selhalo: {err}", "en": "Auto-order failed: {err}"},
    "automation_paused_log": {
        "cs": "Automatizace je pozastavená — nic se neodesílá ani neobjednává.",
        "en": "Automation is paused — nothing is sent or ordered.",
    },
    "automation_failed_body": {
        "cs": "Automatické odeslání selhalo: {detail}. Podrobnosti v Aktivitě.",
        "en": "Automatic sending failed: {detail}. See Activity for details.",
    },
    "automation_pause": {"cs": "Pozastavit automatizaci", "en": "Pause automation"},
    "automation_pause_hint": {
        "cs": "Dokud je zapnuto, obnova nic neodešle ani neobjedná (ani v režimu Automaticky).",
        "en": "While on, refreshes never send or order anything (even in Automatic mode).",
    },
    "automation_paused_banner": {
        "cs": "Automatizace je pozastavená.",
        "en": "Automation is paused.",
    },
    "automation_resume": {"cs": "Obnovit automatizaci", "en": "Resume automation"},
    "automation_resumed": {"cs": "Automatizace znovu běží.", "en": "Automation resumed."},
    "tray_pause": {"cs": "Pozastavit automatizaci", "en": "Pause automation"},
    "auto_confirm_title": {"cs": "Zapnout automatický režim?", "en": "Turn on automatic mode?"},
    "auto_confirm_excuse": {
        "cs": "Strakaláři budou při každé obnově (i na pozadí v liště) sami odesílat omluvenky pod vaším účtem v Bakalářích — bez ptaní. Odeslanou omluvenku nelze vzít zpět.",
        "en": "Strakaláři will send excuses under your Bakaláři account on every refresh (including in the background from the tray) — without asking. A sent excuse cannot be taken back.",
    },
    "auto_confirm_lunch": {
        "cs": "Strakaláři budou při každé obnově (i na pozadí v liště) sami objednávat a rušit obědy ve Stravě — bez ptaní. Objednané obědy se platí.",
        "en": "Strakaláři will order and cancel lunches on Strava on every refresh (including in the background from the tray) — without asking. Ordered lunches are paid for.",
    },
    "auto_confirm_no_dry_run": {
        "cs": "Zatím jste nezkusili režim Jen nanečisto. Doporučujeme ho nejdřív jednou spustit a zkontrolovat výsledek v Aktivitě.",
        "en": "You have not tried Dry run yet. We recommend running it once first and checking the result in Activity.",
    },
    "auto_confirm_pause_hint": {
        "cs": "Kdykoli ho zastavíte přepínačem Pozastavit automatizaci (Aktivita, Nastavení nebo ikona v liště). Vše odeslané najdete v Historii automatizace.",
        "en": "Stop it any time with Pause automation (Activity, Settings or the tray icon). Everything sent is listed in Automation history.",
    },
    "auto_confirm_ok": {"cs": "Rozumím, zapnout", "en": "I understand, turn on"},
    "auto_confirm_dry": {"cs": "Nejdřív nanečisto", "en": "Dry run first"},
    "automation_history": {"cs": "Historie automatizace", "en": "Automation history"},
    "automation_history_empty": {
        "cs": "Zatím nic neodesláno ani neobjednáno.",
        "en": "Nothing sent or ordered yet.",
    },
    "audit_kind_excuse": {"cs": "Omluvenka", "en": "Excuse"},
    "audit_kind_lunch": {"cs": "Oběd", "en": "Lunch"},
    "audit_source_auto": {"cs": "automaticky", "en": "automatic"},
    "audit_source_manual": {"cs": "ručně", "en": "manual"},
    "audit_sent": {"cs": "ODESLÁNO", "en": "SENT"},
    "audit_dry_run": {"cs": "NANEČISTO", "en": "DRY RUN"},
    "audit_covered": {"cs": "UŽ OMLUVENO", "en": "ALREADY DONE"},
    "audit_skipped": {"cs": "PŘESKOČENO", "en": "SKIPPED"},
    "audit_failed": {"cs": "SELHALO", "en": "FAILED"},
    "gemini_auto_used": {"cs": "AI výběr ({model})", "en": "AI pick ({model})"},
    "filter_auto_used": {"cs": "Výběr filtrem", "en": "Filter pick"},
    "bakalari_url_hint": {
        "cs": "Adresa přihlašovací stránky vaší školy — stejná, jakou otevíráte v prohlížeči.",
        "en": "Your school's login page URL — the same one you open in the browser.",
    },
    "canteen_id_hint": {
        "cs": "Číslo jídelny z webu Stravy — najdete ho po přihlášení v nastavení účtu.",
        "en": "The canteen number from the Strava website — find it in your account settings after logging in.",
    },
    "automation_modes_hint": {
        "cs": "Automaticky = odešle se při Obnovení bez ptaní (obědy i omluvenky). S potvrzením = vše schvalujete ručně v Dnes / Obědech, refresh nic neodesílá. Jen nanečisto = nic se neodesílá.",
        "en": "Automatic = sent on Refresh without asking (lunches and excuses). Ask me first = you approve everything manually in Today / Lunches, refresh sends nothing. Dry run = nothing is sent.",
    },
    "limit_subject_hint": {
        "cs": "Prázdné = platí výchozí limit výše.",
        "en": "Empty = the default limit above applies.",
    },



    "excuse_delay": {"cs": "Omlouvat se zpožděním (dny)", "en": "Excuse delay (days)"},
    "go_back_weeks": {"cs": "Kolik týdnů zpět kontrolovat", "en": "Weeks back to check"},
    "go_forward_weeks": {"cs": "Kolik týdnů dopředu stahovat", "en": "Weeks forward to fetch"},
    "default_excuse_pick": {"cs": "Výchozí výběr šablony", "en": "Default template pick"},
    "pick_first": {"cs": "První", "en": "First"},
    "pick_random": {"cs": "Náhodná", "en": "Random"},
    "cache_ttl": {"cs": "Platnost mezipaměti (hodiny)", "en": "Cache lifetime (hours)"},
    "timeout_page": {"cs": "Timeout načtení stránky (s)", "en": "Page load timeout (s)"},
    "timeout_element": {"cs": "Čekání na prvek (s)", "en": "Element wait (s)"},
    "week_switch_delay": {"cs": "Prodleva přepnutí týdne (s)", "en": "Week switch delay (s)"},
    "log_file": {"cs": "Soubor protokolu", "en": "Log file"},
    "blacklist_file": {"cs": "Soubor blacklistu jídel", "en": "Food blacklist file"},


    "config_problems": {"cs": "Problémy v nastavení", "en": "Configuration problems"},
    "config_ok": {"cs": "Nastavení je v pořádku.", "en": "Configuration looks good."},
    "cache_info": {"cs": "Mezipaměť", "en": "Cache"},
    "clear_cache": {"cs": "Vymazat mezipaměť", "en": "Clear cache"},
    "cache_cleared": {"cs": "Mezipaměť vymazána", "en": "Cache cleared"},



    "setup_needed": {
        "cs": "Zatím žádná data. Vyplňte přihlášení v Nastavení a stiskněte Obnovit.",
        "en": "No data yet. Fill in your logins in Settings and press Refresh.",
    },
    "go_to_settings": {"cs": "Otevřít nastavení", "en": "Open settings"},
    "mode_auto": {"cs": "Automaticky", "en": "Automatic"},
    "mode_confirm": {"cs": "S potvrzením", "en": "Ask me first"},
    "mode_dry_run": {"cs": "Jen nanečisto", "en": "Dry run"},
    "excuse_mode_label": {"cs": "Omlouvání absencí", "en": "Excusing absences"},
    "order_mode_label": {"cs": "Objednávání obědů", "en": "Ordering lunches"},
    # Today — excuse kinds ------------------------------------------------------
    "kind_late": {"cs": "Pozdní příchod", "en": "Late arrival"},
    "kind_soon": {"cs": "Předčasný odchod", "en": "Left early"},
    "kind_early": {"cs": "Předčasný odchod", "en": "Left early"},
    "kind_short": {"cs": "Krátká absence", "en": "Short absence"},
    "kind_long": {"cs": "Dlouhá absence", "en": "Long absence"},
    "whole_day": {"cs": "Celý den", "en": "Whole day"},
    "more_tasks": {"cs": "dalších", "en": "more"},
    "default_excuse_template": {
        "cs": "Dobrý den, omluvte prosím absenci.\nDěkuji\n",
        "en": "Hello, please excuse the absence.\nThank you\n",
    },
    # Today — lesson clock ------------------------------------------------------
    "now_running": {"cs": "Právě probíhá", "en": "Happening now"},
    "up_next": {"cs": "Následuje", "en": "Up next"},
    "before_school": {"cs": "Vyučování ještě nezačalo", "en": "School hasn't started yet"},

    "next_school_day": {"cs": "Příště", "en": "Next up"},
    "starts_in": {"cs": "Začíná za {m} min", "en": "Starts in {m} min"},
    "ends_in": {"cs": "Končí za {m} min", "en": "Ends in {m} min"},

    # Timetable — change vs note --------------------------------------------------
    "real_change": {"cs": "Změna", "en": "Change"},
    "note_label": {"cs": "Poznámka", "en": "Note"},
    "notes_title": {"cs": "Poznámky k výuce", "en": "Lesson notes"},

    "changed_to": {"cs": "Změna: {fields}", "en": "Changed: {fields}"},
    "field_subject": {"cs": "předmět", "en": "subject"},
    "field_teacher": {"cs": "učitel", "en": "teacher"},
    "field_room": {"cs": "učebna", "en": "room"},
    "field_time": {"cs": "čas", "en": "time"},
    "field_status": {"cs": "stav", "en": "status"},
    "field_notice": {"cs": "oznámení", "en": "notice"},
    "stable_value": {"cs": "Stále", "en": "Usual"},
    "current_value": {"cs": "Aktuálně", "en": "Now"},
    # Planner ----------------------------------------------------------------------
    "planner_horizon": {"cs": "Školních dní zbývá", "en": "School days left"},
    "see_absences": {"cs": "Podrobné přehledy v Absencích", "en": "Details in Absences"},
    "planned_title": {"cs": "Naplánované dovolené", "en": "Planned vacations"},
    "no_planned": {"cs": "Zatím nic naplánováno.", "en": "Nothing planned yet."},
    "unplan": {"cs": "Zrušit plán", "en": "Remove plan"},
    "plan_removed": {"cs": "Plán zrušen", "en": "Plan removed"},
    "today_left_note": {"cs": "dnes zbývá {n} z {t} hodin", "en": "{n} of {t} lessons left today"},
    "day_passed": {"cs": "Tento den už proběhl.", "en": "This day already passed."},
    # Planner — year plan ------------------------------------------------------
    "plan_buffer_note": {
        "cs": "Na nemoc a nečekané absence držím stranou {reserve:g} % zbývajících hodin každého předmětu — čím blíž uzávěrce, tím menší rezerva stačí.",
        "en": "I keep {reserve:g}% of each subject's remaining lessons aside for illness and surprises — the closer the closure, the smaller that reserve gets.",
    },
    "term_sem1": {"cs": "1. pololetí", "en": "Semester 1"},
    "term_sem2": {"cs": "2. pololetí", "en": "Semester 2"},
    "term_until": {"cs": "uzávěrka {d}", "en": "closes {d}"},
    "term_fresh": {
        "cs": "Nové pololetí začíná s čistým štítem — rozpočet počítám ze stálého rozvrhu.",
        "en": "The new semester starts from zero — budgets come from your usual timetable.",
    },
    "term_nothing": {
        "cs": "Absence za tento školní rok je uzavřená — není co plánovat.",
        "en": "Absences for this school year are closed — nothing left to plan.",
    },
    "days_one": {"cs": "{n} den", "en": "{n} day"},
    "days_few": {"cs": "{n} dny", "en": "{n} days"},
    "days_many": {"cs": "{n} dní", "en": "{n} days"},
    "stat_can_afford": {"cs": "Ještě si můžete dovolit", "en": "You can still afford"},
    "stat_planned": {"cs": "Naplánováno", "en": "Planned"},
    "stat_tightest": {"cs": "Nejtěsnější předmět", "en": "Tightest subject"},
    "hours_free": {"cs": "{n} h volno", "en": "{n} h free"},
    "section_overview": {"cs": "Přehled pololetí", "en": "Semester overview"},
    "overview_hint": {
        "cs": "Klikněte na školní den a naplánujte ho — nebo se podívejte, kolik by stál.",
        "en": "Click a school day to plan it — or just to see what it would cost.",
    },
    "legend_school": {"cs": "Škola", "en": "School"},
    "legend_free": {"cs": "Volno", "en": "Day off"},
    "legend_planned": {"cs": "Naplánováno", "en": "Planned"},
    "legend_recommended": {"cs": "Doporučeno", "en": "Recommended"},
    "legend_blocked": {"cs": "Nevejde se", "en": "Doesn't fit"},
    "legend_today": {"cs": "Dnes", "en": "Today"},
    "cal_tip_past": {"cs": "proběhlo", "en": "past"},
    "cal_tip_free": {"cs": "volno", "en": "day off"},
    "cal_tip_planned": {"cs": "naplánováno", "en": "planned"},
    "cal_tip_recommended": {"cs": "doporučeno — {h} h z rozpočtu", "en": "recommended — {h} h of budget"},
    "cal_tip_fits": {"cs": "vejde se — {h} h z rozpočtu", "en": "fits — {h} h of budget"},
    "cal_tip_blocked": {"cs": "nevejde se: {subjects}", "en": "doesn't fit: {subjects}"},
    "cal_tip_final": {"cs": "poslední týden před uzávěrkou", "en": "final week before the closure"},
    "section_plan": {"cs": "Doporučený plán", "en": "Recommended plan"},
    "plan_explain": {
        "cs": "Dny jsou rozložené rovnoměrně až do uzávěrky — rozpočet nevyčerpáte hned na začátku, ani ho nenecháte na poslední týden.",
        "en": "Days are spread evenly up to the closure — you won't burn the budget early or leave it all for the last week.",
    },
    "target_label": {"cs": "Kolik dní volna chcete", "en": "Days off you want"},
    "target_auto": {"cs": "Co nejvíc ({n})", "en": "As many as fit ({n})"},
    "plan_all": {"cs": "Naplánovat vše", "en": "Plan all"},
    "plan_all_title": {"cs": "Naplánovat doporučené dny", "en": "Plan the recommended days"},
    "plan_all_body": {"cs": "Naplánuji tyto dny: {days}", "en": "I'll plan these days: {days}"},
    "plan_all_done": {"cs": "Naplánováno dní: {n}", "en": "Days planned: {n}"},
    "plan_budget_empty": {
        "cs": "Rozpočet je teď vyčerpaný — další celý den se bezpečně nevejde. S každým odchozeným týdnem se trochu uvolní.",
        "en": "The budget is used up for now — no further whole day fits safely. Every week you attend frees a little more.",
    },
    "plan_target_met": {
        "cs": "Cíl splněn — naplánovaných dní: {n}.",
        "en": "Goal reached — days planned: {n}.",
    },
    "tag_bridge": {"cs": "Most · {n} dní volna", "en": "Bridge · {n} days off"},
    "tag_long_weekend": {"cs": "Prodloužený víkend", "en": "Long weekend"},
    "tag_light": {"cs": "Lehký den", "en": "Light day"},
    "tag_free": {"cs": "Nic vás nestojí", "en": "Costs nothing"},
    "tag_final_week": {"cs": "Týden uzávěrky", "en": "Closure week"},
    "tag_late_week": {"cs": "Blízko uzávěrky", "en": "Near the closure"},
    "day_cost": {"cs": "{n} h z rozpočtu", "en": "{n} h of budget"},
    "day_cost_free": {"cs": "bez dopadu na limity", "en": "no effect on limits"},
    "section_budgets": {"cs": "Rozpočet předmětů", "en": "Subject budgets"},
    "budget_line": {
        "cs": "volno {free} h · naplánováno {planned} h · rezerva {buffer} h",
        "en": "{free} h free · {planned} h planned · {buffer} h reserve",
    },
    "budget_final": {"cs": "na konci ~{p} % (limit {limit:g} %)", "en": "ends at ~{p}% (limit {limit:g}%)"},
    "budget_end": {"cs": "na konci ~{p} %", "en": "ends at ~{p}%"},
    "budget_ok": {"cs": "V pohodě", "en": "Fine"},
    "budget_tight": {"cs": "Těsné", "en": "Tight"},
    "budget_reserve": {"cs": "Sahá do rezervy", "en": "Into reserve"},
    "budget_over": {"cs": "Přes limit", "en": "Over limit"},
    "legend_missed": {"cs": "Zameškáno", "en": "Missed"},
    "legend_free_h": {"cs": "Volno", "en": "Free"},
    "legend_buffer": {"cs": "Rezerva na nemoc", "en": "Illness reserve"},
    "warn_over": {
        "cs": "Naplánované volno překračuje školní limit: {subjects}. Zrušte raději některý den.",
        "en": "Your planned days off break the school limit: {subjects}. Better remove one.",
    },
    "warn_reserve": {
        "cs": "Naplánované volno už ujídá z rezervy na nemoc: {subjects}.",
        "en": "Your planned days off already eat into the illness reserve: {subjects}.",
    },
    "warn_pace": {
        "cs": "Absence roste rychleji, než stačí rovnoměrné tempo: {subjects}.",
        "en": "Absences are growing faster than an even pace allows: {subjects}.",
    },
    "planned_cost": {"cs": "stojí {h} h", "en": "costs {h} h"},
    "impact_title": {"cs": "Dopad na limity", "en": "Effect on limits"},
    "impact_row": {
        "cs": "{name}: −{cost} h → volno {left} h, na konci ~{p} %",
        "en": "{name}: −{cost} h → {left} h free, ends at ~{p}%",
    },
    "impact_none": {"cs": "Tyto hodiny se do limitů nepočítají.", "en": "These lessons don't count toward any limit."},
    "impact_ok": {"cs": "Vejde se do rozpočtu.", "en": "Fits the budget."},
    "impact_reserve": {"cs": "Sáhnete do rezervy na nemoc.", "en": "This dips into your illness reserve."},
    "impact_over": {"cs": "Překročíte školní limit!", "en": "This breaks the school limit!"},
    "planner_next": {"cs": "Další doporučené volno: {day}", "en": "Next recommended day off: {day}"},
    "plan_custom": {"cs": "Naplánovat vlastní termín", "en": "Plan a custom range"},
    "plan_custom_hint": {
        "cs": "Vlastní rozsah — od data a hodiny do data a hodiny. Prostřední dny se berou celé.",
        "en": "Custom range — from date and period to date and period. Days in between count as whole.",
    },
    "custom_from_lesson": {"cs": "Od hodiny", "en": "From period"},
    "custom_to_lesson": {"cs": "Do hodiny", "en": "To period"},
    "custom_invalid": {
        "cs": "Zkontrolujte datum (DD.MM.RRRR) a hodiny — konec nesmí být před začátkem a začátek v minulosti.",
        "en": "Check the dates (DD.MM.YYYY) and periods — the end must not precede the start, and the start must not be in the past.",
    },
    "date_hint": {"cs": "DD.MM.RRRR", "en": "DD.MM.YYYY"},

    # Lunches ------------------------------------------------------------------------
    "pick_hint": {
        "cs": "Kliknutím vyberte oběd, pak vše odešlete najednou.",
        "en": "Click to pick a lunch, then send everything at once.",
    },
    "no_order_option": {"cs": "Bez oběda (odhlásit)", "en": "No lunch (cancel)"},
    "web_ordered": {"cs": "Objednáno ve Stravě", "en": "Ordered in Strava"},
    "to_send": {"cs": "K odeslání", "en": "To send"},
    "ai_section": {"cs": "AI doporučení", "en": "AI recommendations"},
    "ai_tools": {"cs": "AI a filtr", "en": "AI & filter"},
    "show_sidebar": {"cs": "Zobrazit AI panel", "en": "Show AI panel"},
    "hide_sidebar": {"cs": "Skrýt AI panel", "en": "Hide AI panel"},
    "ai_no_key": {
        "cs": "Bez Gemini klíče funguje jen lokální filtr — klíč je zdarma a zabere to minutu.",
        "en": "Without a Gemini key only the local filter works — the key is free and takes a minute.",
    },
    "blacklist_add_failed": {
        "cs": "Slovo nelze přidat (min. 3 písmena, bez duplicit).",
        "en": "Can't add the word (min. 3 letters, no duplicates).",
    },
    "blacklist_unreadable": {
        "cs": "Blacklist nelze načíst ({path}) — úprava zrušena, aby se nepřepsala uložená slova. Opravte nebo smažte soubor.",
        "en": "Can't read the blacklist ({path}) — edit cancelled so the saved words are not overwritten. Fix or delete the file.",
    },
    "blacklist_read_failed": {
        "cs": "Blacklist nelze načíst ({path}) — filtr je prázdný.",
        "en": "Can't read the blacklist ({path}) — the filter is empty.",
    },
    "low_balance_title": {
        "cs": "Na účtu ve Stravě není dost peněz",
        "en": "Not enough money on the Strava account",
    },
    "low_balance_body": {
        "cs": "Strava odmítla objednat obědy na {days}. Dobijte kredit — automatické objednávání to zkusí znovu, ruční výběr odešlete znovu.",
        "en": "Strava refused to order lunch for {days}. Top up the account — automatic ordering retries on its own; send manual picks again.",
    },
    "excuse_all": {"cs": "Omluvit vše z tohoto dne", "en": "Excuse all of this day"},
    "excuse_already_covered": {"cs": "Už bylo omluveno", "en": "Already excused"},
    "excuse_day_result": {"cs": "Omluveno {ok} z {n}", "en": "Excused {ok} of {n}"},
    "autostart_failed": {
        "cs": "Automatické spouštění se nepodařilo změnit.",
        "en": "Could not change the autostart setting.",
    },
    "blacklist_broken_log": {
        "cs": "Blacklist je poškozený — automatické objednávání pozastaveno do opravy.",
        "en": "Blacklist is corrupt — automatic ordering paused until it is fixed.",
    },
    "blacklist_section": {"cs": "Blacklist jídel", "en": "Food blacklist"},
    "blacklist_hint": {
        "cs": "Jídla obsahující tato slova se skryjí z výběru.",
        "en": "Meals containing these words are hidden from the picker.",
    },
    "add_word": {"cs": "Přidat slovo", "en": "Add word"},
    "no_blacklist": {"cs": "Blacklist je prázdný.", "en": "Blacklist is empty."},
    "hidden_meals": {"cs": "Skryto {n} jídel (filtr)", "en": "{n} meals hidden (filter)"},
    "lunch_order_closed": {
        "cs": "Objednávka uzavřena — Strava přijímá objednávky jen do předchozího pracovního dne",
        "en": "Ordering closed — Strava only accepts orders until the previous business day",
    },
    "lunch_closed_badge": {"cs": "Uzavřeno", "en": "Closed"},
    "lunch_show_past": {"cs": "Zobrazit proběhlé dny ({n})", "en": "Show past days ({n})"},
    "lunch_hide_past": {"cs": "Skrýt proběhlé dny", "en": "Hide past days"},
    "lunch_soup": {"cs": "Polévka", "en": "Soup"},
    "allergens": {"cs": "Alergeny", "en": "Allergens"},
    "lunch_closed_count": {"cs": "Uzavřeno uzávěrkou", "en": "Closed by cutoff"},
    "lunch_cutoff_label": {"cs": "Uzávěrka obědů (HH:MM předchozí pracovní den)", "en": "Lunch cutoff (HH:MM previous business day)"},
    "lunch_cutoff_hint": {
        "cs": "Prázdné = podle kalendáře školy (jinak 12:00). Oběd lze objednat jen do tohoto času předchozí pracovní den — ověřte si čas u své jídelny.",
        "en": "Empty = from the school calendar (else 12:00). Lunch can only be ordered until this time on the previous business day — check your canteen's deadline.",
    },
    "lunch_cutoff_invalid": {"cs": "Neplatný čas — použijte HH:MM (např. 12:00).", "en": "Invalid time — use HH:MM (e.g. 12:00)."},
    # Settings --------------------------------------------------------------------------
    "new_password": {"cs": "Nové heslo…", "en": "New password…"},
    "secret_empty": {"cs": "Nevyplněno", "en": "Not set"},
    "account_bakalari": {"cs": "Bakaláři", "en": "Bakaláři"},
    "account_strava": {"cs": "Strava", "en": "Strava"},
    # First-run wizard ----------------------------------------------------------
    "wiz_welcome_h": {"cs": "Vítejte ve Strakalářích!", "en": "Welcome to Strakaláři!"},
    "wiz_welcome_p": {
        "cs": "V několika krocích nastavíme Bakaláře, jídelnu Strava a volitelně AI doporučení.",
        "en": "In a few steps we'll set up Bakaláři, the Strava canteen and optional AI recommendations.",
    },
    "wiz_disclaimer_h": {"cs": "Než začneme", "en": "Before we start"},
    "wiz_disclaimer_p": {
        "cs": "Strakaláři je nezávislý studentský projekt bez oficiální podpory Bakalářů a Stravy. Přihlašovací údaje slouží jen k přihlášení do vašich systémů a ukládají se šifrovaně na tomto počítači.",
        "en": "Strakaláři is an independent student project with no official support from Bakaláři or Strava. Your logins are only used to sign in to your systems and are stored encrypted on this computer.",
    },
    "wiz_disclaimer_rules": {
        "cs": "• Používejte jen svůj vlastní účet a jen tak, jak to dovolují pravidla vaší školy a podmínky Bakalářů a Stravy.\n• Aplikace jedná vaším jménem: omluvenky i objednávky odeslané přes ni jsou vaše. Odeslanou omluvenku nelze vzít zpět.\n• Výchozí režim je S potvrzením — nic se neodešle bez vašeho kliknutí. Automatické úkony průběžně kontrolujte v Aktivitě; bezchybný provoz zaručit nemůžeme.\n• Software je poskytován bez záruky (GPLv3); autor neodpovídá za škody způsobené jeho použitím.",
        "en": "• Use only your own account, and only as your school's rules and the Bakaláři and Strava terms allow.\n• The app acts on your behalf: excuses and orders sent through it are yours. A sent excuse cannot be taken back.\n• The default mode is Ask me first — nothing is sent without your click. Review automated actions in Activity; error-free operation can't be guaranteed.\n• The software comes without warranty (GPLv3); the author is not liable for damage caused by its use.",
    },
    "wiz_disclaimer_ack": {
        "cs": "Rozumím a beru na vědomí",
        "en": "I understand and accept this",
    },
    "wiz_disclaimer_need": {
        "cs": "Pro pokračování potvrďte, že jste upozornění četli.",
        "en": "Please confirm you have read the notice to continue.",
    },
    "automation_disclaimer": {
        "cs": "Aplikace jedná pod vaším účtem — používejte ji jen v souladu s pravidly školy a podmínkami Bakalářů a Stravy. Vše odeslané najdete v Aktivitě.",
        "en": "The app acts under your account — use it only as your school's rules and the Bakaláři and Strava terms allow. Everything sent is listed in Activity.",
    },
    "wiz_next": {"cs": "Pokračovat", "en": "Continue"},
    "wiz_back": {"cs": "Zpět", "en": "Back"},
    "wiz_skip": {"cs": "Přeskočit prozatím", "en": "Skip for now"},
    "wiz_finish": {"cs": "Dokončit", "en": "Finish"},
    "wiz_step_of": {"cs": "Krok {i} z {n}", "en": "Step {i} of {n}"},
    "wiz_bakalari_h": {"cs": "Přihlášení do Bakalářů", "en": "Bakaláři login"},
    "wiz_bakalari_p": {
        "cs": "Zadejte adresu školy, uživatelské jméno a heslo — stejně jako v prohlížeči.",
        "en": "Enter your school URL, username and password — same as in the browser.",
    },
    "wiz_strava_h": {"cs": "Jídelna Strava", "en": "Strava canteen"},
    "wiz_strava_p": {
        "cs": "Pokud obědy neřešíte, integraci vypněte. Jinak vyplňte přihlášení a číslo jídelny.",
        "en": "If you don't use school lunches, turn the integration off. Otherwise fill in the login and canteen ID.",
    },
    "wiz_ai_h": {"cs": "AI doporučení (volitelné)", "en": "AI recommendations (optional)"},
    "wiz_ai_p": {
        "cs": "Klíč z Google AI Studia slouží jen k doporučení obědů — je zdarma. Bez klíče funguje lokální výběr.",
        "en": "A Google AI Studio key is only used for lunch picks — it's free. Without it, local selection works.",
    },
    "wiz_use_ai": {"cs": "Používat AI doporučení", "en": "Use AI recommendations"},
    "wiz_browser_h": {"cs": "Prohlížeč pro automatizaci", "en": "Automation browser"},
    "wiz_browser_p": {
        "cs": "Automatizace ovládá weby přes Chrome (~320 MB). Stáhne se jednorázově a automaticky.",
        "en": "Automation drives websites through Chrome (~320 MB). It downloads once, automatically.",
    },
    "wiz_browser_ok": {"cs": "Chrome je připraven.", "en": "Chrome is ready."},
    "wiz_browser_missing": {"cs": "Chrome zatím není stažen.", "en": "Chrome is not downloaded yet."},
    "wiz_install_browser": {"cs": "Stáhnout Chrome", "en": "Download Chrome"},
    "wiz_retry_browser": {"cs": "Zkusit znovu", "en": "Try again"},
    "wiz_browser_done": {"cs": "Hotovo, Chrome je připraven.", "en": "Done, Chrome is ready."},
    "wiz_browser_failed": {"cs": "Stažení Chrome selhalo: {e}", "en": "Chrome download failed: {e}"},
    "wiz_browser_downloading": {"cs": "Stahuji {name}", "en": "Downloading {name}"},
    "wiz_browser_extracting": {"cs": "Rozbaluji {name}", "en": "Unpacking {name}"},
    "wiz_browser_preparing": {"cs": "Připravuji stahování…", "en": "Preparing download…"},
    "wiz_browser_bg": {
        "cs": "Můžete pokračovat — stahování poběží na pozadí.",
        "en": "You can continue — the download keeps running in the background.",
    },
    "wiz_browser_wait_test": {
        "cs": "Chrome se ještě stahuje — přihlášení otestuji hned po dokončení.",
        "en": "Chrome is still downloading — the login test runs as soon as it's done.",
    },
    "wiz_test_continue": {"cs": "Otestovat a pokračovat", "en": "Test & continue"},
    "wiz_test_key": {"cs": "Otestovat klíč", "en": "Test key"},
    "wiz_need_browser_first": {
        "cs": "Nejdřív stáhněte Chrome — test přihlášení ho potřebuje.",
        "en": "Download Chrome first — the login test needs it.",
    },
    "wiz_finishing_refresh": {
        "cs": "Spouštím první obnovu dat…",
        "en": "Starting the first data refresh…",
    },
    "wiz_done_h": {"cs": "Vše je připraveno!", "en": "All set!"},
    "wiz_done_p": {
        "cs": "Nastavení je uloženo. Stiskněte Dokončit — první obnova dat se spustí sama.",
        "en": "Settings are saved. Press Finish — the first data refresh starts automatically.",
    },
    "wiz_done_next": {
        "cs": "Potom: Dnes ukáže omluvenky ke schválení, Obědy výběr jídel — nic se neodesílá bez vás.",
        "en": "Next: Today shows excuses to approve, Lunches shows meal picks — nothing is sent without you.",
    },
    "wiz_need_bakalari": {
        "cs": "Vyplňte adresu, jméno i heslo Bakalářů.",
        "en": "Fill in the Bakaláři URL, username and password.",
    },
    "wiz_need_strava": {
        "cs": "Zapněte-li Stravu, vyplňte jméno, heslo i číslo jídelny.",
        "en": "With Strava on, fill in username, password and canteen ID.",
    },
    "wiz_need_ai_key": {
        "cs": "Zapnete-li AI, vložte API klíč — nebo AI vypněte.",
        "en": "With AI on, paste the API key — or turn AI off.",
    },
    # School calendar ------------------------------------------------------
    "sec_calendar": {"cs": "Školní kalendář", "en": "School calendar"},
    "wiz_cal_h": {"cs": "Školní kalendář", "en": "School calendar"},
    "wiz_cal_p": {
        "cs": "Vyberte kalendář své školy — prázdniny a uzávěrky absence se nastaví samy. Pokud tu vaše škola není, zvolte Vlastní dny: vše funguje stejně, jen prázdniny a uzávěrky doplníte v Nastavení.",
        "en": "Pick your school's calendar — holidays and absence closures are set automatically. If your school is not listed, choose Custom days: everything works the same, you just add holidays and closures in Settings.",
    },
    "wiz_cal_custom": {"cs": "Vlastní dny", "en": "Custom days"},
    "wiz_cal_only_school": {
        "cs": "Jen pro studenty této školy.",
        "en": "Only for students of this school.",
    },
    "wiz_cal_custom_p": {
        "cs": "Pro jakoukoli školu — prázdniny, uzávěrky a čas objednání obědů si nastavíte v Nastavení.",
        "en": "For any school — set holidays, closures and the lunch order deadline in Settings.",
    },
    "wiz_cal_days": {
        "cs": "{n} dní volna do {end}",
        "en": "{n} free days until {end}",
    },
    "wiz_cal_pick": {
        "cs": "Vyber jednu možnost pro pokračování.",
        "en": "Pick one option to continue.",
    },
    "cal_preset": {"cs": "Přednastavení", "en": "Preset"},
    "cal_custom_opt": {"cs": "Vlastní (bez presetu)", "en": "Custom (no preset)"},
    "cal_sem1": {"cs": "Uzávěrka absence — 1. pololetí (DD.MM.RRRR)", "en": "Absence closure — semester 1 (DD.MM.YYYY)"},
    "cal_sem2": {"cs": "Uzávěrka absence — 2. pololetí (DD.MM.RRRR)", "en": "Absence closure — semester 2 (DD.MM.YYYY)"},

    "cal_auto": {"cs": "automaticky", "en": "auto"},
    "cal_free_days": {"cs": "Volné dny", "en": "Free days"},
    "cal_date": {"cs": "Datum (DD.MM.RRRR)", "en": "Date (DD.MM.YYYY)"},
    "cal_from": {"cs": "Od (DD.MM.RRRR)", "en": "From (DD.MM.YYYY)"},
    "cal_to": {"cs": "Do (DD.MM.RRRR)", "en": "To (DD.MM.YYYY)"},
    "cal_label": {"cs": "Název (nepovinné)", "en": "Label (optional)"},
    "cal_add_single": {"cs": "Přidat den", "en": "Add day"},
    "cal_add_range": {"cs": "Přidat období", "en": "Add range"},
    "cal_my": {"cs": "Moje", "en": "Mine"},
    "cal_cancel_preset": {"cs": "Zrušit — bude škola", "en": "Cancel — school day"},
    "cal_restore": {"cs": "Vrátit", "en": "Restore"},
    "cal_school_override": {"cs": "Škola (zrušeno z presetu)", "en": "School (removed from preset)"},
    "cal_clear_past": {"cs": "Smazat proběhlé", "en": "Clear past"},
    "cal_invalid_date": {"cs": "Neplatné datum (DD.MM.RRRR).", "en": "Invalid date (DD.MM.YYYY)."},
    "cal_invalid_range": {"cs": "Neplatné období — zkontrolujte data.", "en": "Invalid range — check the dates."},
    "cal_duplicate": {"cs": "Tento den už je volný.", "en": "This day is already free."},
    "cal_added": {"cs": "Přidáno.", "en": "Added."},
    "cal_no_days": {"cs": "Zatím žádné volné dny.", "en": "No free days yet."},
    "cal_summary": {
        "cs": "{preset} z presetu · +{added} moje · −{forced} zrušeno",
        "en": "{preset} from preset · +{added} mine · −{forced} cancelled",
    },
    "cal_closes": {"cs": "Uzávěrky: {a} / {b}", "en": "Closures: {a} / {b}"},
    "cal_open_calendar": {"cs": "Upravit kalendář", "en": "Edit calendar"},

    "cal_range_added": {"cs": "Přidáno {n} dní.", "en": "Added {n} days."},
    # Updates ------------------------------------------------------------------
    "update_available": {"cs": "Je dostupná nová verze {v}", "en": "New version {v} available"},
    "update_desc": {
        "cs": "Používáte {cur}, vyšla {v}. Stáhněte si ji z GitHub Releases.",
        "en": "You're on {cur}, {v} is out. Grab it from GitHub Releases.",
    },
    "download_update": {"cs": "Stáhnout aktualizaci", "en": "Download update"},
    "check_updates": {"cs": "Zkontrolovat aktualizace", "en": "Check for updates"},
    "checking_updates": {"cs": "Zjišťuji aktualizace…", "en": "Checking for updates…"},
    "app_version": {"cs": "Verze aplikace", "en": "App version"},
    "latest_version": {"cs": "Nejnovější verze", "en": "Latest version"},
    "up_to_date": {"cs": "Aktuální", "en": "Up to date"},
    "update_dismiss": {"cs": "Skrýt", "en": "Dismiss"},
    "update_open_releases": {"cs": "Otevřít stránku vydání", "en": "Open releases page"},
    "update_channel": {"cs": "Kanál aktualizací", "en": "Update channel"},
    "update_channel_stable": {"cs": "Stabilní", "en": "Stable"},
    "update_channel_beta": {"cs": "Beta (včetně stabilních)", "en": "Beta (includes stable)"},
    "update_channel_hint": {
        "cs": "Beta upozorní i na testovací verze, které mohou obsahovat chyby.",
        "en": "Beta also notifies about test versions, which may contain bugs.",
    },
    # Error reporting -------------------------------------------------------
    "error_title": {"cs": "Něco se pokazilo", "en": "Something went wrong"},
    "error_copy_logs": {"cs": "Kopírovat protokol", "en": "Copy log"},
    "error_copied": {"cs": "Protokol zkopírován do schránky", "en": "Log copied to clipboard"},
    "error_copy_failed": {
        "cs": "Kopírování selhalo — označte text ručně.",
        "en": "Copy failed — select the text manually.",
    },
    "error_close": {"cs": "Zavřít", "en": "Close"},
    "error_hint": {
        "cs": "Zkopírujte protokol a pošlete ho s popisem, co jste dělali — pomůže to najít chybu.",
        "en": "Copy the log and send it with a note on what you were doing — it helps track down the bug.",
    },
    "error_not_yours": {
        "cs": "Myslíte, že chyba není na vaší straně? Zkopírujte protokol a pošlete nám ho.",
        "en": "Think this isn't your fault? Copy the log and send it to us.",
    },
    "job_failed_log": {
        "cs": "Plánovaná úloha {name} selhala.",
        "en": "Scheduled job {name} failed.",
    },
    "job_failed": {"cs": "Úloha {name} selhala.", "en": "Job {name} failed."},
    "lunches_auto_ordered": {
        "cs": "Obědy automaticky objednány.",
        "en": "Lunches ordered automatically.",
    },
    "data_updated": {
        "cs": "Data aktualizována ({count} předmětů).",
        "en": "Data updated ({count} subjects).",
    },
    "cancel_refresh_log": {
        "cs": "Rušení obnovování na žádost uživatele…",
        "en": "Cancelling refresh at user request…",
    },
    "excuses_auto_sent": {
        "cs": "Automatické omluvenky odeslány.",
        "en": "Automatic excuses sent.",
    },
    "refresh_done_body": {
        "cs": "Data byla aktualizována.",
        "en": "Data has been updated.",
    },
    "refresh_empty_warn": {
        "cs": "Varování: prázdná data z Bakalářů — ponechávám předchozí mezipaměť.",
        "en": "Warning: empty data from Bakalari — keeping the previous cache.",
    },
    "refresh_finished_log": {"cs": "Obnovování dokončeno.", "en": "Refresh finished."},
    "refresh_cancelled_log": {"cs": "Obnovování zrušeno.", "en": "Refresh cancelled."},
    "refresh_failed_log": {"cs": "Obnovování selhalo: {detail}", "en": "Refresh failed: {detail}"},
    "refresh_failed_body": {"cs": "Obnovení selhalo: {detail}", "en": "Refresh failed: {detail}"},
    "cancelled_by_user": {"cs": "zrušeno uživatelem", "en": "cancelled by user"},
    "unknown_error": {"cs": "neznámá chyba", "en": "unknown error"},
    "subjects_count": {"cs": "{n} předmětů", "en": "{n} subjects"},
    "refresh_started_log": {"cs": "Obnovování spuštěno ({scope}).", "en": "Refresh started ({scope})."},
    "checking_browser": {"cs": "Kontroluji prohlížeč…", "en": "Checking the browser…"},
    "fetching_bakalari": {"cs": "Stahuji data z Bakalářů…", "en": "Fetching Bakalari data…"},
    "baseline_log": {
        "cs": "Stálý rozvrh: {slots} slotů, změn oproti stálému: {changes}.",
        "en": "Stable timetable: {slots} slots, {changes} changes vs stable.",
    },
    "bakalari_done_log": {"cs": "Bakaláři hotovi ({n} předmětů).", "en": "Bakalari done ({n} subjects)."},
    "planner_suggestion": {"cs": "Tip plánovače", "en": "Planner suggestion"},
    "timetable_history_log": {
        "cs": "Dohledávám historii rozvrhu tohoto školního roku ({n} týdnů)…",
        "en": "Backfilling this school year's timetable history ({n} weeks)…",
    },
    "bakalari_skipped_log": {
        "cs": "Bakaláři přeskočeni — není vyplněné přihlášení.",
        "en": "Bakalari skipped — no login configured.",
    },
    "excuse_sync_failed": {
        "cs": "Synchronizace odeslaných omluvenek selhala: {err}",
        "en": "Sent-excuse sync failed: {err}",
    },
    "fetching_menu": {"cs": "Stahuji jídelníček ze Stravy…", "en": "Fetching the Strava menu…"},
    "strava_done_log": {"cs": "Strava hotová ({n} dní).", "en": "Strava done ({n} days)."},
    "strava_skipped_log": {
        "cs": "Strava přeskočena — není vyplněné přihlášení.",
        "en": "Strava skipped — no login configured.",
    },
    "strava_fetch_failed": {
        "cs": "Stažení jídelníčku selhalo: {err} — data z Bakalářů jsou uložena.",
        "en": "Menu fetch failed: {err} — Bakalari data was saved.",
    },
    "strava_menu_empty": {
        "cs": "Strava nevrátila žádný jídelníček — ponechávám předchozí.",
        "en": "Strava returned no menu — keeping the previous one.",
    },
    "strava_disabled_skip": {
        "cs": "Strava je v nastavení vypnutá — přeskakuji.",
        "en": "Strava is disabled in settings — skipping.",
    },
    "saving_cache": {"cs": "Ukládám mezipaměť…", "en": "Saving cache…"},
    "missing_credentials_log": {
        "cs": "Nejsou vyplněné přihlašovací údaje — dokončete nejdřív nastavení.",
        "en": "No login credentials entered — finish the setup first.",
    },
    "password_saved_hint": {
        "cs": "Heslo uloženo — zadejte nové pro změnu",
        "en": "Password saved — enter a new one to change it",
    },
    "key_saved_hint": {
        "cs": "Klíč uložen — zadejte nový pro změnu",
        "en": "Key saved — enter a new one to change it",
    },
    "cal_preset_hint": {
        "cs": "Prázdné = hodnota z presetu.",
        "en": "Empty = preset value.",
    },
    "cal_show_past": {"cs": "Zobrazit proběhlé dny", "en": "Show past days"},
    "cal_hide_past": {"cs": "Skrýt proběhlé dny", "en": "Hide past days"},
    "cal_range_days": {"cs": "{n} dnů", "en": "{n} days"},
    "strava_disabled_title": {"cs": "Strava je vypnutá", "en": "Strava is disabled"},
    "strava_disabled_msg": {
        "cs": "Zapněte Stravu v Nastavení → Účty, abyste mohli objednávat obědy.",
        "en": "Enable Strava in Settings → Accounts to order lunches.",
    },
    "filter_hint": {
        "cs": "Filtr skryje jídla podle vašich chutí a blacklistu — nic se neodesílá do Stravy.",
        "en": "The filter hides meals matching your tastes and blacklist — nothing is sent to Strava.",
    },
    "apply_filter_long": {"cs": "Použít filtr", "en": "Apply filter"},
    "recommend_no_key": {
        "cs": "Doporučení potřebuje Gemini klíč — doplňte ho v Nastavení.",
        "en": "Recommendations need a Gemini key — add it in Settings.",
    },
    "plan_cancel_lunch": {"cs": "Odhlásit oběd", "en": "Cancel lunch"},
    "lunch_cannot_cancel": {
        "cs": "Oběd už nelze odhlásit — uzávěrka {deadline} proběhla.",
        "en": "Lunch can no longer be cancelled — the {deadline} cutoff passed.",
    },
    "skip_not_planned": {"cs": "Dovolenou se nepodařilo naplánovat", "en": "Could not plan the vacation"},
    # Tutorials (see tutorial.py) -------------------------------------------
    "tut_next": {"cs": "Další", "en": "Next"},
    "tut_back": {"cs": "Zpět", "en": "Back"},
    "tut_done": {"cs": "Rozumím", "en": "Got it"},
    "tut_skip_step": {"cs": "Pokračovat bez toho", "en": "Continue without it"},
    "tut_later": {"cs": "Teď ne", "en": "Not now"},
    "tut_skip_tour": {"cs": "Přeskočit tento návod", "en": "Skip this tutorial"},
    "tut_start": {"cs": "Provést mě", "en": "Show me around"},
    "tut_not_now": {"cs": "Přeskočit", "en": "Skip"},
    "tut_turn_off": {"cs": "Vypnout návody", "en": "Turn off tutorials"},
    "tut_off_note": {
        "cs": "Návody se ukazují jen jednou, když narazíte na něco nového. "
              "Zapnout či vypnout je jde v Nastavení → Vzhled.",
        "en": "Tutorials show once, when you first meet something new. "
              "Turn them on or off in Settings → Appearance.",
    },
    "tutorials": {"cs": "Návody", "en": "Tutorials"},
    "tutorials_toggle": {"cs": "Ukazovat interaktivní návody", "en": "Show interactive tutorials"},
    "tutorials_hint": {
        "cs": "Krátké bubliny, které vás provedou věcmi, na které narazíte poprvé "
              "(první omluvenka, první objednávka oběda…).",
        "en": "Short bubbles that walk you through things you meet for the first time "
              "(first excuse, first lunch order…).",
    },
    "tutorials_replay": {"cs": "Přehrát návody znovu", "en": "Replay tutorials"},
    "tutorials_replayed": {
        "cs": "Návody se znovu ukážou, až na jejich místo narazíte.",
        "en": "Tutorials will show again when you reach them.",
    },
    "tut_intro_welcome_title": {"cs": "Vítejte ve Strakalářích", "en": "Welcome to Strakaláři"},
    "tut_intro_welcome_body": {
        "cs": "Strakaláři hlídají absenci, posílají omluvenky do Bakalářů a objednávají "
              "obědy ve Stravě. Za minutku vám ukážu, kde co najdete.",
        "en": "Strakaláři watches your absences, sends excuses to Bakaláři and orders "
              "lunches on Strava. Let me show you around — it takes a minute.",
    },
    "tut_intro_nav_title": {"cs": "Obrazovky", "en": "Screens"},
    "tut_intro_nav_body": {
        "cs": "Tady vlevo přepínáte obrazovky. Dnes je rychlý přehled, Rozvrh a Absence "
              "ukazují data z Bakalářů, Plánovač hledá volné dny a Obědy řeší objednávky "
              "ve Stravě.",
        "en": "Switch screens on the left. Today is a quick overview, Timetable and "
              "Absences show your Bakaláři data, the Planner finds days off and Lunches "
              "handles Strava orders.",
    },
    "tut_intro_refresh_title": {"cs": "Obnovení dat", "en": "Refreshing data"},
    "tut_intro_refresh_body": {
        "cs": "Data se stahují sama na pozadí v nastaveném intervalu. Tímto tlačítkem "
              "je stáhnete hned — třeba když chcete vidět čerstvou změnu rozvrhu.",
        "en": "Data refreshes by itself in the background. This button fetches it right "
              "now — handy when you want to see a fresh timetable change.",
    },
    "tut_intro_status_title": {"cs": "Co se právě děje", "en": "What's going on"},
    "tut_intro_status_body": {
        "cs": "Tady vidíte, co aplikace dělá a jestli poslední obnova uspěla. "
              "Kliknutím otevřete Aktivitu s podrobným záznamem.",
        "en": "This shows what the app is doing and whether the last refresh worked. "
              "Click it to open Activity with the full log.",
    },
    "tut_intro_done_title": {"cs": "To je vše!", "en": "That's it!"},
    "tut_intro_done_body": {
        "cs": "Další věci vysvětlím, až na ně poprvé narazíte — třeba u první omluvenky "
              "nebo objednávky oběda. Každý návod jde zavřít křížkem.",
        "en": "I'll explain the rest when you first run into it — like your first excuse "
              "or lunch order. Any tutorial can be closed with the ×.",
    },
    "tut_excuse_pick_title": {"cs": "Absence k omluvení", "en": "An absence to excuse"},
    "tut_excuse_pick_body": {
        "cs": "Bakaláři hlásí hodinu bez omluvenky. V seznamu vyberte text omluvenky — "
              "šablony si upravíte v Nastavení → Šablony omluvenek.",
        "en": "Bakaláři reports a lesson without an excuse. Pick the excuse text from the "
              "list — edit the templates in Settings → Excuse templates.",
    },
    "tut_excuse_send_title": {"cs": "Odešlete ji", "en": "Send it"},
    "tut_excuse_send_body": {
        "cs": "Omluvit vyplní omluvenku v Bakalářích za vás. Pokud jste ji už omluvili "
              "jinde, dejte Ignorovat — zmizí ze seznamu a jde kdykoli vrátit.",
        "en": "Excuse fills in the excuse in Bakaláři for you. If you already excused it "
              "elsewhere, press Ignore — it leaves the list and can be restored any time.",
    },
    "tut_excuse_send_try": {
        "cs": "Vyzkoušejte to: stiskněte Omluvit nebo Ignorovat.",
        "en": "Try it: press Excuse or Ignore.",
    },
    "tut_excuse_done_title": {"cs": "Hotovo", "en": "Done"},
    "tut_excuse_done_body": {
        "cs": "Průběh odesílání vidíte nahoře ve stavové liště a v Aktivitě. Chcete-li, "
              "aby se omluvenky posílaly samy, nastavte to v Nastavení → Automatizace.",
        "en": "Watch the send in the status bar at the top or in Activity. Want excuses "
              "to go out by themselves? Set it up in Settings → Automation.",
    },
    "tut_tt_weeks_title": {"cs": "Listování týdny", "en": "Browsing weeks"},
    "tut_tt_weeks_body": {
        "cs": "Šipkami přecházíte mezi týdny, „Tento týden“ vás vrátí zpět. „Stálý“ ukáže "
              "běžný rozvrh bez změn. Vpravo přepnete tabulku a seznam.",
        "en": "Use the arrows to move between weeks; “This week” jumps back. “Stable” "
              "shows the regular timetable without changes. Switch grid/list on the right.",
    },
    "tut_tt_colors_title": {"cs": "Změny na první pohled", "en": "Changes at a glance"},
    "tut_tt_colors_body": {
        "cs": "Barvy značí změny oproti stálému rozvrhu — suplování, jinou učebnu, "
              "odpadlé hodiny či pozdní příchod. Kliknutím na hodinu otevřete detail.",
        "en": "Colors mark changes against the stable timetable — substitutions, room "
              "changes, cancelled lessons or late arrivals. Click a lesson for details.",
    },
    "tut_abs_stats_title": {"cs": "Přehled absence", "en": "Absence overview"},
    "tut_abs_stats_body": {
        "cs": "Každý předmět má vlastní limit absence. Tady vidíte průměr a kolik "
              "předmětů se k limitu blíží (varování) nebo ho skoro překročilo (kritické).",
        "en": "Every subject has its own absence limit. Here is your average and how many "
              "subjects are getting close to it (warning) or nearly over it (critical).",
    },
    "tut_abs_subject_title": {"cs": "Kolik si můžete dovolit", "en": "How much you can miss"},
    "tut_abs_subject_body": {
        "cs": "U každého předmětu je limit, kolik hodin ještě můžete vynechat a odhad na "
              "konci pololetí. Limity upravíte v Nastavení → Limity předmětů.",
        "en": "Each subject shows its limit, how many more lessons you can miss and a "
              "projection for the end of term. Change limits in Settings → Subject limits.",
    },
    "tut_plan_strip_title": {"cs": "Pololetí na jeden pohled", "en": "The whole term at once"},
    "tut_plan_strip_body": {
        "cs": "Každý čtvereček je školní den. Zelené dny plánovač doporučuje na volno — "
              "stojí vás nejméně absence v předmětech, kde máte nejvíc rezervy.",
        "en": "Each square is a school day. Green days are the planner's picks for a day "
              "off — they cost the least absence in the subjects with the most room.",
    },
    "tut_plan_pick_title": {"cs": "Naplánujte si volno", "en": "Plan a day off"},
    "tut_plan_pick_body": {
        "cs": "Naplánovaný den si pohlídá omluvenku a může za vás i odhlásit oběd. "
              "Před potvrzením uvidíte, kolik absence vás bude stát.",
        "en": "A planned day gets its excuse ready and can cancel your lunch too. "
              "Before confirming you'll see what it costs in absence.",
    },
    "tut_plan_pick_try": {
        "cs": "Vyzkoušejte: stiskněte Naplánovat dovolenou (v dialogu jde zrušit).",
        "en": "Try it: press Plan vacation (you can cancel in the dialog).",
    },
    "tut_plan_budget_title": {"cs": "Rozpočet hodin", "en": "Your hour budget"},
    "tut_plan_budget_body": {
        "cs": "Pruhy ukazují, kolik hodin z limitu už padlo, kolik je naplánováno a kolik "
              "zbývá. Žlutá rezerva zůstává schovaná pro nemoc.",
        "en": "The bars show how much of each limit is used, how much is planned and "
              "what's left. The yellow reserve stays put aside for sick days.",
    },
    "tut_lunch_pick_title": {"cs": "Vyberte si oběd", "en": "Pick a lunch"},
    "tut_lunch_pick_body": {
        "cs": "Klikněte na jídlo, které chcete. Zatím se nic neodesílá — výběr se jen "
              "připraví a můžete ho ještě změnit.",
        "en": "Click the meal you want. Nothing is sent yet — the pick is only staged "
              "and you can still change it.",
    },
    "tut_lunch_pick_try": {"cs": "Vyzkoušejte: klikněte na jídlo.", "en": "Try it: click a meal."},
    "tut_lunch_send_title": {"cs": "Odešlete objednávky", "en": "Send your orders"},
    "tut_lunch_send_body": {
        "cs": "Tlačítko pošle všechny připravené změny do Stravy najednou. Číslo v závorce "
              "říká, kolik jich čeká.",
        "en": "This button sends every staged change to Strava at once. The number in "
              "brackets shows how many are waiting.",
    },
    "tut_lunch_send_try": {"cs": "Vyzkoušejte: odešlete objednávku.", "en": "Try it: send the order."},
    "tut_lunch_tools_title": {"cs": "Pomocníci", "en": "Helpers"},
    "tut_lunch_tools_body": {
        "cs": "Tady otevřete panel s AI doporučením obědů a černou listinou jídel, která "
              "nechcete vidět.",
        "en": "This opens the panel with AI lunch picks and a blacklist of meals you "
              "never want to see.",
    },
    "tut_marks_stats_title": {"cs": "Známky na jeden pohled", "en": "Marks at a glance"},
    "tut_marks_stats_body": {
        "cs": "Nahoře je celkový průměr, odhad vysvědčení a kolik známek přibylo "
              "za posledních 7 dní. Odhad vychází z vážených průměrů jednotlivých předmětů.",
        "en": "Up top: your overall average, an estimated report card and how many marks "
              "arrived in the last 7 days. The estimate comes from each subject's "
              "weighted average.",
    },
    "tut_marks_subject_title": {"cs": "Předměty", "en": "Subjects"},
    "tut_marks_subject_body": {
        "cs": "Každá karta ukazuje průměr, pravděpodobnou známku na vysvědčení, trend "
              "a nejnovější známky. Po kliknutí se vpravo otevře detail předmětu.",
        "en": "Each card shows the average, the likely report grade, the trend and the "
              "newest marks. Click one to open the subject's detail on the right.",
    },
    "tut_marks_subject_try": {"cs": "Vyzkoušejte: klikněte na předmět.",
                              "en": "Try it: click a subject."},
    "tut_marks_need_title": {"cs": "Co potřebuji?", "en": "What do I need?"},
    "tut_marks_need_body": {
        "cs": "Zvolte známku, kterou chcete na vysvědčení, a váhu příští písemky — "
              "spočítám, co z ní musíte dostat (nebo jestli to ještě jde).",
        "en": "Pick the report grade you want and the weight of the next test — "
              "I'll work out what you need to get on it (or whether it's still possible).",
    },
    "tut_marks_predict_title": {"cs": "Co kdyby…", "en": "What if…"},
    "tut_marks_predict_body": {
        "cs": "Přidejte si vymyšlenou známku, upravte nebo vynechte skutečnou a hned "
              "uvidíte nový průměr. Skutečné známky v Bakalářích zůstanou netknuté.",
        "en": "Add a made-up mark, edit or leave out a real one and see the new average "
              "right away. Your real marks in Bakaláři stay untouched.",
    },
    "tut_marks_predict_try": {
        "cs": "Vyzkoušejte: zadejte známku a stiskněte Přidat.",
        "en": "Try it: type a mark and press Add.",
    },
    "tut_marks_scale_title": {"cs": "Známky, nebo procenta", "en": "Grades or percent"},
    "tut_marks_scale_body": {
        "cs": "Aplikace u každého předmětu sama pozná, jestli se známkuje 1–5, nebo "
              "v procentech. Tady to přepnete pro všechny, v detailu pro jeden předmět.",
        "en": "The app detects whether each subject is marked 1–5 or in percent. Switch "
              "it for all subjects here, or for one subject in its detail.",
    },
    "tut_settings_intro_title": {"cs": "Nastavení", "en": "Settings"},
    "tut_settings_intro_body": {
        "cs": "Nastavení je rozdělené do skupin vlevo. Změny se ukládají samy, jakmile "
              "opustíte pole — žádné tlačítko Uložit nehledejte.",
        "en": "Settings are grouped on the left. Changes save by themselves as soon as "
              "you leave a field — no Save button needed.",
    },
    "tut_activity_intro_title": {"cs": "Aktivita", "en": "Activity"},
    "tut_activity_intro_body": {
        "cs": "Záznam všeho, co aplikace dělala: obnovy, omluvenky, objednávky. Když se "
              "něco pokazí, odsud zkopírujete záznam pro nahlášení chyby.",
        "en": "A log of everything the app did: refreshes, excuses, orders. If something "
              "breaks, copy the log from here to report it.",
    },
}

#: Per-event notification labels (kept separate — dict-valued).
NOTIF_LABELS: dict[str, dict[str, str]] = {
    "excuse_sent": {"cs": "Odeslaná omluvenka", "en": "Excuse sent"},
    "excuse_needs_confirm": {"cs": "Omluvenka ke schválení", "en": "Excuse needs approval"},
    "refresh_done": {"cs": "Dokončená aktualizace", "en": "Refresh finished"},
    "refresh_failed": {"cs": "Neúspěšná aktualizace", "en": "Refresh failed"},
    "lunch_ordered": {"cs": "Objednaný oběd", "en": "Lunch ordered"},
    "lunch_skipped": {"cs": "Přeskočený oběd", "en": "Lunch skipped"},
    "planner_suggestion": {"cs": "Tip plánovače", "en": "Planner suggestion"},
    "automation_failed": {"cs": "Selhané odeslání / objednání", "en": "Send or order failed"},
}


def S(key: str) -> str:
    """Translated UI string for the active language."""
    lang = get_language()
    if lang not in ("cs", "en"):
        lang = "cs"
    entry = STRINGS.get(key)
    if not entry:
        return key
    text = entry.get(lang) or entry.get("cs") or entry.get("en") or key
    return text if text else key


def notif_label(event: str) -> str:
    lang = get_language()
    if lang not in ("cs", "en"):
        lang = "cs"
    return NOTIF_LABELS.get(event, {}).get(lang, event)
