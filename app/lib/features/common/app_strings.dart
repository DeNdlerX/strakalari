/// UI strings for the Phase 6 screens (cs + en).
///
/// Port of `strakalari/flet_ui/strings.py` restricted to the keys used by
/// the today / timetable / absences / marks / wizard screens (plus the
/// excuse mixin). Same keys, same texts, same `{name}` placeholders.
/// Missing keys fall back to Czech, then to the key itself — like `S()`.
class AppStrings {
  /// `'cs'` or `'en'`.
  final String language;

  const AppStrings([this.language = 'cs']);

  String _lang() => language == 'en' ? 'en' : 'cs';

  /// Normalized language code (`'cs'` or `'en'`).
  String get lang => _lang();

  /// Raw lookup with cs fallback, then the key itself.
  String get(String key) {
    final entry = _values[key];
    if (entry == null) return key;
    return entry[_lang()] ?? entry['cs'] ?? key;
  }

  /// Lookup with `{name}` placeholder substitution (Dart-side `str.format`).
  String tr(String key, [Map<String, Object?> params = const {}]) {
    var out = get(key);
    params.forEach((name, value) {
      out = out.replaceAll('{$name}', '${value ?? ''}');
    });
    return out;
  }

  static const Map<String, Map<String, String>> _values = {
    'absence_title': {'cs': 'Absence', 'en': 'Absences'},
    'ai_key_link': {'cs': 'Získat klíč zdarma', 'en': 'Get a free key'},
    'ai_key_steps': {
      'cs':
          'Zdarma bez karty: odkaz → Create API key → klíč vložte sem a otestujte. Klíč zůstává šifrovaně jen v tomto počítači.',
      'en':
          'Free, no card needed: open the link → Create API key → paste it here and test. The key stays encrypted on this computer.',
    },
    'ai_model_hint': {
      'cs': 'Nechte výchozí — měňte jen když test selže.',
      'en': 'Keep the default — change it only if the test fails.',
    },
    'already_running': {
      'cs': 'Obnovování již běží…',
      'en': 'A refresh is already running…',
    },
    'avg_absence': {'cs': 'Průměrná absence', 'en': 'Average absence'},
    'bakalari_url': {'cs': 'URL Bakalářů', 'en': 'Bakaláři URL'},
    'bakalari_url_hint': {
      'cs':
          'Adresa přihlašovací stránky vaší školy — stejná, jakou otevíráte v prohlížeči.',
      'en':
          'Your school\u2019s login page URL — the same one you open in the browser.',
    },
    'before_school': {
      'cs': 'Vyučování ještě nezačalo',
      'en': 'School hasn\u2019t started yet',
    },
    'budget_end': {'cs': 'na konci ~{p} %', 'en': 'ends at ~{p}%'},
    'cal_auto': {'cs': 'automaticky', 'en': 'auto'},
    'cal_closes': {'cs': 'Uzávěrky: {a} / {b}', 'en': 'Closures: {a} / {b}'},
    'cancel': {'cs': 'Zrušit', 'en': 'Cancel'},
    'canteen_id': {'cs': 'Číslo jídelny', 'en': 'Canteen ID'},
    'canteen_id_hint': {
      'cs':
          'Číslo jídelny z webu Stravy — najdete ho po přihlášení v nastavení účtu.',
      'en':
          'The canteen number from the Strava website — find it in your account settings after logging in.',
    },
    'changed_to': {'cs': 'Změna: {fields}', 'en': 'Changed: {fields}'},
    'choose_template': {'cs': 'Způsob omluvení', 'en': 'How to excuse it'},
    'close': {'cs': 'Zavřít', 'en': 'Close'},
    'col_limit': {'cs': 'Limit', 'en': 'Limit'},
    'col_safe': {'cs': 'Zbývá hodin', 'en': 'Hours left'},
    'col_subject': {'cs': 'Předmět', 'en': 'Subject'},
    'connection_failed': {'cs': 'Připojení selhalo', 'en': 'Connection failed'},
    'connection_ok': {'cs': 'Připojení funguje', 'en': 'Connection works'},
    'crit_subjects': {'cs': 'Kritické', 'en': 'Critical'},
    'current_value': {'cs': 'Aktuálně', 'en': 'Now'},
    'default_excuse_template': {
      'cs': 'Dobrý den, omluvte prosím absenci.\nDěkuji\n',
      'en': 'Hello, please excuse the absence.\nThank you\n',
    },
    'day_group_covers': {
      'cs': 'Najednou {lessons}: {subjects}',
      'en': 'All at once, {lessons}: {subjects}',
    },
    'day_group_each': {
      'cs': '{lessons} zvlášť, každá svou zprávou: {subjects}',
      'en': '{lessons} separately, one message each: {subjects}',
    },
    'default_limit': {'cs': 'Výchozí limit (%)', 'en': 'Default limit (%)'},
    'ends_in': {'cs': 'Končí za {m} min', 'en': 'Ends in {m} min'},
    'excuse_all': {
      'cs': 'Omluvit vše z tohoto dne',
      'en': 'Excuse all of this day',
    },
    'excuse_already_covered': {'cs': 'Už bylo omluveno', 'en': 'Already excused'},
    'excuse_blocked_unconfirmed': {
      'cs':
          'Předchozí odeslání této absence se nepotvrdilo. Obnovte data — pokud v Komens → Odeslané nic není, půjde omluvenku poslat znovu.',
      'en':
          'An earlier send of this absence was not confirmed. Refresh — if nothing is in Komens → Sent, the excuse can be sent again.',
    },
    'excuse_day': {'cs': 'Omluvit celý den', 'en': 'Excuse whole day'},
    'excuse_day_result': {'cs': 'Omluveno {ok} z {n}', 'en': 'Excused {ok} of {n}'},
    'excuse_dry_run': {
      'cs': 'Nanečisto — nic nebylo odesláno',
      'en': 'Dry run — nothing was sent',
    },
    'excuse_each_lesson': {'cs': 'Každou hodinu zvlášť', 'en': 'Each lesson separately'},
    'excuse_each_lesson_tip': {
      'cs': 'Omluvenka za každou hodinu odejde jako samostatná zpráva.',
      'en': 'Each lesson\u2019s excuse goes out as a message of its own.',
    },
    'excuse_failed': {
      'cs': 'Omluvenku se nepodařilo odeslat',
      'en': 'Could not send the excuse',
    },
    'excuse_lessons': {'cs': 'Omluvit {lessons}', 'en': 'Excuse {lessons}'},
    'excuse_sending': {'cs': 'Omluvenka se odesílá…', 'en': 'Sending excuse…'},
    'excuse_sent': {'cs': 'Omluvenka odeslána', 'en': 'Excuse sent'},
    'excuse_unconfirmed': {
      'cs':
          'Odeslání se nepotvrdilo — omluvenka možná odešla. Znovu se neodešle, dokud další obnovení nezkontroluje Komens → Odeslané.',
      'en':
          'The send was not confirmed — the excuse may have gone out. It will not be sent again until the next refresh checks Komens → Sent.',
    },
    'excused_btn': {'cs': 'Omluvit', 'en': 'Excuse'},
    'field_notice': {'cs': 'oznámení', 'en': 'notice'},
    'field_room': {'cs': 'učebna', 'en': 'room'},
    'field_status': {'cs': 'stav', 'en': 'status'},
    'field_subject': {'cs': 'předmět', 'en': 'subject'},
    'field_teacher': {'cs': 'učitel', 'en': 'teacher'},
    'field_time': {'cs': 'čas', 'en': 'time'},
    'gemini_key': {'cs': 'Gemini API klíč', 'en': 'Gemini API key'},
    'gemini_model': {'cs': 'Gemini model', 'en': 'Gemini model'},
    'go_to_settings': {'cs': 'Otevřít nastavení', 'en': 'Open settings'},
    'group': {'cs': 'Skupina', 'en': 'Group'},
    'hours_free': {'cs': '{n} h volno', 'en': '{n} h free'},
    'ignore_btn': {'cs': 'Ignorovat', 'en': 'Ignore'},
    'ignore_day': {'cs': 'Ignorovat den', 'en': 'Ignore day'},
    'ignore_save_failed': {
      'cs':
          'Změnu seznamu ignorovaných se nepodařilo uložit — zkuste to znovu.',
      'en': 'Could not save the ignored list — try again.',
    },
    'ignored_msg': {'cs': 'Ignorováno — omluveno jinde.', 'en': 'Ignored — excused elsewhere.'},
    'ignored_title': {'cs': 'Ignorované', 'en': 'Ignored'},
    'legend_change': {'cs': 'Změna rozvrhu', 'en': 'Schedule change'},
    'legend_late_early': {'cs': 'Pozdní příchod / odchod', 'en': 'Late / left early'},
    'legend_now': {'cs': 'Teď / další hodina', 'en': 'Now / next lesson'},
    'legend_planned': {'cs': 'Naplánováno', 'en': 'Planned'},
    'lessons_few': {'cs': '{n} hodiny', 'en': '{n} lessons'},
    'lessons_many': {'cs': '{n} hodin', 'en': '{n} lessons'},
    'lessons_one': {'cs': '{n} hodina', 'en': '{n} lesson'},
    'limit_subject_hint': {
      'cs': 'Prázdné = platí výchozí limit výše.',
      'en': 'Empty = the default limit above applies.',
    },
    'lunch_today': {'cs': 'Dnešní oběd', 'en': 'Today\u2019s lunch'},
    'marks_add': {'cs': 'Přidat', 'en': 'Add'},
    'marks_average': {'cs': 'Průměr', 'en': 'Average'},
    'marks_band_label': {'cs': 'Známka {grade}', 'en': 'Grade {grade}'},
    'marks_bands': {'cs': 'Převod procent na známky', 'en': 'Percent to grade'},
    'marks_bands_default': {'cs': 'Výchozí', 'en': 'Default'},
    'marks_bands_hint': {
      'cs':
          'Horní hranice známek 2–5 jako v tabulce převodu v Bakalářích — hraniční hodnota už je horší známka (87 % = 2). Použije se u odhadu a při převodu mezi stupnicemi.',
      'en':
          'Top of grades 2–5, as in Bakaláři\u2019s conversion table — a boundary value is already the worse grade (87 % = 2). Used for estimates and scale conversion.',
    },
    'marks_bands_invalid': {
      'cs': 'Zadejte čtyři klesající hodnoty mezi 0 a 100.',
      'en': 'Enter four decreasing values between 0 and 100.',
    },
    'marks_bands_saved': {
      'cs': 'Převod procent uložen',
      'en': 'Percent bands saved',
    },
    'marks_bands_src_default': {
      'cs': 'Výchozí převod (škola ho v předvolbě nemá)',
      'en': 'Default table (the school preset has none)',
    },
    'marks_bands_src_preset': {
      'cs': 'Převzato z předvolby {school}',
      'en': 'From the {school} preset',
    },
    'marks_bands_src_user': {'cs': 'Vlastní nastavení', 'en': 'Your own values'},
    'marks_bands_use_school': {'cs': 'Podle školy', 'en': 'Use school\u2019s table'},
    'marks_count': {'cs': 'Známek: {n}', 'en': '{n} marks'},
    'marks_delete': {'cs': 'Smazat', 'en': 'Delete'},
    'marks_detected': {
      'cs': 'Automaticky zjištěno: {scale}',
      'en': 'Detected automatically: {scale}',
    },
    'marks_edit': {'cs': 'Upravit v predikci', 'en': 'Edit in prediction'},
    'marks_final': {'cs': 'Na vysvědčení', 'en': 'Final grade'},
    'marks_final_tooltip': {
      'cs': 'Odhad známky na vysvědčení',
      'en': 'Estimated report-card grade',
    },
    'marks_hypothetical': {'cs': 'Vymyšlená známka', 'en': 'What-if mark'},
    'marks_invalid': {
      'cs':
          'Neplatná známka nebo váha — např. 1, 2-, 85 % nebo 17/20; váha kladné číslo.',
      'en':
          'Invalid mark or weight — e.g. 1, 2-, 85 % or 17/20; weight a positive number.',
    },
    'marks_last': {'cs': 'naposledy {day}', 'en': 'last {day}'},
    'marks_leave_out': {'cs': 'Vynechat z predikce', 'en': 'Leave out of prediction'},
    'marks_mark': {'cs': 'Známka', 'en': 'Mark'},
    'marks_need_any': {
      'cs': 'Na {grade} to vyjde s jakoukoli další známkou.',
      'en': 'Any next mark keeps you at {grade}.',
    },
    'marks_need_grade': {
      'cs': 'Na {grade} potřebujete z další známky nejhůř {mark}.',
      'en': 'For a {grade} your next mark must be {mark} or better.',
    },
    'marks_need_impossible': {
      'cs': 'Na {grade} to s touto váhou prakticky nevyjde.',
      'en': 'A {grade} is out of reach at this weight.',
    },
    'marks_need_many': {
      'cs':
          'Jednou známkou to na {grade} nevyjde — potřebujete {n}× {mark} s váhou {weight}.',
      'en':
          'One mark is not enough for a {grade} — you need {n}× {mark} at weight {weight}.',
    },
    'marks_need_pct': {
      'cs': 'Na {grade} potřebujete z další známky aspoň {mark}.',
      'en': 'For a {grade} your next mark must be at least {mark}.',
    },
    'marks_need_title': {'cs': 'Co potřebuji', 'en': 'What do I need'},
    'marks_new': {'cs': 'Nové (7 dní)', 'en': 'New (7 days)'},
    'marks_new_badge': {'cs': '{n} nové', 'en': '{n} new'},
    'marks_no_recent': {'cs': 'Zatím žádné známky.', 'en': 'No marks yet.'},
    'marks_no_topic': {'cs': 'Bez tématu', 'en': 'No topic'},
    'marks_none_yet': {
      'cs': 'V tomto předmětu zatím nejsou známky.',
      'en': 'No marks in this subject yet.',
    },
    'marks_not_counted': {'cs': 'nezapočítává se', 'en': 'not counted'},
    'marks_pick_hint': {
      'cs': 'Klikněte na předmět pro detail, výpočet a predikci známek.',
      'en': 'Click a subject for details, the calculator and mark predictions.',
    },
    'marks_planned': {'cs': 'Plánované zkoušení', 'en': 'Planned tests'},
    'marks_planned_count': {'cs': 'plánováno: {n}', 'en': '{n} planned'},
    'marks_planned_test': {'cs': 'Plánovaná známka', 'en': 'Planned mark'},
    'marks_predicted': {'cs': 'Predikce', 'en': 'Predicted'},
    'marks_predicted_short': {'cs': 'predikce', 'en': 'predicted'},
    'marks_prediction_hint': {
      'cs':
          'Průměry počítají i s vymyšlenými změnami. Skutečné známky se nemění.',
      'en': 'Averages include your what-if changes. Real marks are unchanged.',
    },
    'marks_prediction_on': {
      'cs': 'Predikce je zapnutá ({n} předm.)',
      'en': 'Prediction on ({n} subj.)',
    },
    'marks_predictor': {'cs': 'Známky a predikce', 'en': 'Marks & prediction'},
    'marks_predictor_hint': {
      'cs':
          'Přidávejte, upravujte a mažte známky nanečisto — skutečné známky zůstanou beze změny. Predikce platí do zavření aplikace.',
      'en':
          'Add, edit and delete marks as a what-if — your real marks stay untouched. Predictions last until you close the app.',
    },
    'marks_quarterly': {'cs': 'Čtvrtletní: {mark}', 'en': 'Quarterly: {mark}'},
    'marks_quarterly_tooltip': {
      'cs': 'Čtvrtletní známka (prozatímní výsledná)',
      'en': 'Quarterly mark (interim final grade)',
    },
    'marks_recent': {'cs': 'Poslední známky', 'en': 'Latest marks'},
    'marks_report': {'cs': 'Odhad vysvědčení', 'en': 'Report card estimate'},
    'marks_reset': {'cs': 'Zrušit predikci', 'en': 'Reset prediction'},
    'marks_reset_all': {'cs': 'Zrušit vše', 'en': 'Reset all'},
    'marks_restore_real': {
      'cs': 'Vrátit skutečnou známku',
      'en': 'Back to the real mark',
    },
    'marks_save': {'cs': 'Uložit', 'en': 'Save'},
    'marks_scale_auto': {'cs': 'Auto', 'en': 'Auto'},
    'marks_scale_global': {
      'cs':
          'Podle nastavení nahoře: {scale} (Auto = jako ostatní předměty)',
      'en': 'Following the switch above: {scale} (Auto = same as other subjects)',
    },
    'marks_scale_grade': {'cs': '1–5', 'en': '1–5'},
    'marks_scale_percent': {'cs': '%', 'en': '%'},
    'marks_scale_tooltip': {
      'cs':
          'Stupnice: Auto pozná známky 1–5 i procenta u každého předmětu zvlášť',
      'en': 'Scale: Auto tells 1–5 marks and percentages apart per subject',
    },
    'marks_sort_average': {'cs': 'Nejhorší', 'en': 'Worst first'},
    'marks_sort_name': {'cs': 'A–Z', 'en': 'A–Z'},
    'marks_sort_recent': {'cs': 'Nedávné', 'en': 'Recent'},
    'marks_subjects_n': {'cs': 'Předměty ({n})', 'en': 'Subjects ({n})'},
    'marks_target': {'cs': 'Cíl', 'en': 'Goal'},
    'marks_target_option': {
      'cs': 'Na vysvědčení {grade}',
      'en': 'Final grade {grade}',
    },
    'marks_title': {'cs': 'Známky', 'en': 'Marks'},
    'marks_total': {'cs': 'Známek', 'en': 'Marks'},
    'marks_trend': {'cs': 'Vývoj průměru', 'en': 'Average over time'},
    'marks_trend_down': {
      'cs': 'Poslední známka průměr zhoršila',
      'en': 'The latest mark lowered the average',
    },
    'marks_trend_up': {
      'cs': 'Poslední známka průměr zlepšila',
      'en': 'The latest mark improved the average',
    },
    'marks_use_weight': {'cs': 'Do predikce', 'en': 'Predict'},
    'marks_was': {
      'cs': 'skutečně {mark} (váha {weight})',
      'en': 'really {mark} (weight {weight})',
    },
    'marks_weight': {'cs': 'Váha', 'en': 'Weight'},
    'marks_written': {'cs': 'psáno {day}', 'en': 'written {day}'},
    'more_tasks': {'cs': 'dalších', 'en': 'more'},
    'nav_planner': {'cs': 'Plánovač', 'en': 'Planner'},
    'need_credentials': {
      'cs': 'Vyplňte přihlášení v Nastavení a stiskněte Obnovit.',
      'en': 'Fill in your logins in Settings and press Refresh.',
    },
    'new_password': {'cs': 'Nové heslo…', 'en': 'New password…'},
    'next_lesson': {'cs': 'Další hodina', 'en': 'Next lesson'},
    'next_school_day': {'cs': 'Příště', 'en': 'Next up'},
    'next_week': {'cs': 'Další týden', 'en': 'Next week'},
    'no_changes': {'cs': 'Žádné změny', 'en': 'No changes'},
    'no_data': {'cs': 'Zatím žádná data', 'en': 'No data yet'},
    'no_lessons_today': {'cs': 'Dnes žádné vyučování', 'en': 'No lessons today'},
    'no_lunch': {'cs': 'Žádný oběd objednán', 'en': 'No lunch ordered'},
    'note_label': {'cs': 'Poznámka', 'en': 'Note'},
    'notes_title': {'cs': 'Poznámky k výuce', 'en': 'Lesson notes'},
    'now_running': {'cs': 'Právě probíhá', 'en': 'Happening now'},
    'or_one_by_one': {
      'cs': 'Nebo jednotlivě ({n})',
      'en': 'Or one by one ({n})',
    },
    'ordered': {'cs': 'Objednáno', 'en': 'Ordered'},
    'password': {'cs': 'Heslo', 'en': 'Password'},
    'pending_excuses': {'cs': 'Čekající omluvenky', 'en': 'Pending excuses'},
    'period': {'cs': 'Hodina', 'en': 'Period'},
    'planner_next': {
      'cs': 'Další doporučené volno: {day}',
      'en': 'Next recommended day off: {day}',
    },
    'planner_suggestion': {'cs': 'Tip plánovače', 'en': 'Planner suggestion'},
    'prev_week': {'cs': 'Předchozí týden', 'en': 'Previous week'},
    'real_change': {'cs': 'Změna', 'en': 'Change'},
    'refresh_data': {'cs': 'Obnovit data', 'en': 'Refresh data'},
    'restore': {'cs': 'Vrátit', 'en': 'Restore'},
    'room': {'cs': 'Učebna', 'en': 'Room'},
    'safe_to': {'cs': 'Bezpečně do', 'en': 'Safe to'},
    'save_failed': {
      'cs': 'Nepodařilo se uložit nastavení',
      'en': 'Could not save settings',
    },
    'secret_empty': {'cs': 'Nevyplněno', 'en': 'Not set'},
    'session_busy': {
      'cs':
          'Právě probíhá jiná obnova nebo odesílání (lišta nebo jiné okno). Zkuste to za chvíli.',
      'en':
          'Another refresh or submit is running (tray or another window). Try again in a moment.',
    },
    'setup_needed': {
      'cs': 'Zatím žádná data. Vyplňte přihlášení v Nastavení a stiskněte Obnovit.',
      'en': 'No data yet. Fill in your logins in Settings and press Refresh.',
    },
    'signature': {'cs': 'Podpis', 'en': 'Signature'},
    'signature_ask_p': {
      'cs':
          'Omluvenka by odešla nepodepsaná. Zadejte jméno, kterým se omluvenky podepisují — uloží se i do Nastavení.',
      'en':
          'The excuse would go out unsigned. Enter the name excuses are signed with — it is saved to Settings too.',
    },
    'signature_ask_title': {'cs': 'Chybí podpis', 'en': 'Signature missing'},
    'signature_hint': {'cs': 'Jméno Příjmení', 'en': 'First and last name'},
    'signature_save_send': {'cs': 'Uložit a odeslat', 'en': 'Save and send'},
    'stable_timetable': {'cs': 'Stálý rozvrh', 'en': 'Stable timetable'},
    'stable_value': {'cs': 'Stále', 'en': 'Usual'},
    'stable_view': {'cs': 'Stálý', 'en': 'Stable'},
    'starts_in': {'cs': 'Začíná za {m} min', 'en': 'Starts in {m} min'},
    'state_critical': {'cs': 'Kritické', 'en': 'Critical'},
    'state_ok': {'cs': 'V pořádku', 'en': 'Fine'},
    'state_warning': {'cs': 'Varování', 'en': 'Warning'},
    'status_absent': {'cs': 'Absence', 'en': 'Absent'},
    'status_early': {'cs': 'Předčasný odchod', 'en': 'Left early'},
    'status_excused': {'cs': 'Omluveno', 'en': 'Excused'},
    'status_late': {'cs': 'Pozdní příchod', 'en': 'Late arrival'},
    'status_lesson_cancelled': {'cs': 'Odpadá', 'en': 'Cancelled'},
    'status_soon': {'cs': 'Předčasný odchod', 'en': 'Left early'},
    'tag_added': {'cs': 'Hodina navíc', 'en': 'Extra lesson'},
    'tag_room_change': {'cs': 'Jiná učebna', 'en': 'Room change'},
    'tag_substitution': {'cs': 'Suplování', 'en': 'Substitution'},
    'teacher': {'cs': 'Učitel', 'en': 'Teacher'},
    'template_n': {'cs': 'Šablona', 'en': 'Template'},
    'testing': {'cs': 'Testuji…', 'en': 'Testing…'},
    'theme': {'cs': 'Téma', 'en': 'Topic'},
    'this_week': {'cs': 'Tento týden', 'en': 'This week'},
    'timetable_title': {'cs': 'Rozvrh', 'en': 'Timetable'},
    'today_badge': {'cs': 'Dnes', 'en': 'Today'},
    'today_title': {'cs': 'Dnešní přehled', 'en': 'Today at a glance'},
    'undo': {'cs': 'Zpět', 'en': 'Undo'},
    'up_next': {'cs': 'Následuje', 'en': 'Up next'},
    'use_strava': {'cs': 'Používat Stravu', 'en': 'Use Strava'},
    'username': {'cs': 'Uživatelské jméno', 'en': 'Username'},
    'view_list': {'cs': 'Seznam', 'en': 'List'},
    'view_table': {'cs': 'Tabulka', 'en': 'Grid'},
    'week': {'cs': 'Týden', 'en': 'Week'},
    'wakeup_badge': {'cs': 'Budík {time}', 'en': 'Alarm {time}'},
    'wakeup_badge_eve': {'cs': 'Budík {day} {time}', 'en': 'Alarm {day} {time}'},
    'wakeup_enable': {
      'cs': 'Budík před první hodinou',
      'en': 'Wake-up alarm before the first lesson',
    },
    'wakeup_exact_allow': {
      'cs': 'Povolit přesné budíky',
      'en': 'Allow exact alarms',
    },
    'wakeup_exact_off': {
      'cs':
          'Přesné budíky nejsou povolené — budík může zazvonit pozdě (až o hodinu) a v tichém režimu zůstat potichu.',
      'en':
          'Exact alarms aren\u2019t allowed — the alarm may ring late (up to an hour) and stay quiet in silent mode.',
    },
    'wakeup_hint': {
      'cs':
          'Zazvoní {n} min před první hodinou, která opravdu proběhne — odpadlé hodiny, volné dny a naplánované absence přeskočí. Budíky na dva týdny dopředu zvoní i se zavřenou aplikací, hlasitostí budíku i v tichém režimu.',
      'en':
          'Rings {n} min before your first lesson that actually takes place — cancelled lessons, days off and planned absences are skipped. Alarms for the next two weeks ring even with the app closed, at alarm volume even in silent mode.',
    },
    'wakeup_minutes': {
      'cs': 'Kolik minut před první hodinou budit (min)',
      'en': 'Minutes before the first lesson (min)',
    },
    'wakeup_minutes_invalid': {
      'cs': 'Zadejte počet minut od 1 do 720.',
      'en': 'Enter a number of minutes from 1 to 720.',
    },
    'warn_subjects': {'cs': 'S varováním', 'en': 'Warning'},
    'week_changes': {'cs': 'Změny tento týden', 'en': 'Changes this week'},
    'wiz_ai_h': {'cs': 'AI doporučení (volitelné)', 'en': 'AI recommendations (optional)'},
    'wiz_ai_p': {
      'cs':
          'Klíč z Google AI Studia slouží jen k doporučení obědů — je zdarma. Bez klíče funguje lokální výběr.',
      'en':
          'A Google AI Studio key is only used for lunch picks — it\u2019s free. Without it, local selection works.',
    },
    'wiz_alarm_h': {'cs': 'Budík před vyučováním', 'en': 'Wake-up alarm'},
    'wiz_alarm_later': {
      'cs': 'Později ho najdete v Nastavení → Budík nebo v menu Více.',
      'en':
          'Later you\u2019ll find it in Settings → Wake-up alarm or in the More menu.',
    },
    'wiz_alarm_p': {
      'cs':
          'Telefon vás může budit podle rozvrhu z Bakalářů — vždy před první hodinou, která opravdu proběhne. Je to volitelné.',
      'en':
          'The phone can wake you by your Bakaláři timetable — always before the first lesson that actually takes place. It\u2019s optional.',
    },
    'wiz_back': {'cs': 'Zpět', 'en': 'Back'},
    'wiz_bakalari_h': {'cs': 'Přihlášení do Bakalářů', 'en': 'Bakaláři login'},
    'wiz_bakalari_p': {
      'cs':
          'Zadejte adresu školy, uživatelské jméno a heslo — stejně jako v prohlížeči.',
      'en': 'Enter your school URL, username and password — same as in the browser.',
    },
    'wiz_cal_custom': {'cs': 'Vlastní dny', 'en': 'Custom days'},
    'wiz_cal_custom_p': {
      'cs':
          'Pro jakoukoli školu — prázdniny, uzávěrky a čas objednání obědů si nastavíte v Nastavení.',
      'en':
          'For any school — set holidays, closures and the lunch order deadline in Settings.',
    },
    'wiz_cal_days': {'cs': '{n} dní volna do {end}', 'en': '{n} free days until {end}'},
    'wiz_cal_h': {'cs': 'Školní kalendář', 'en': 'School calendar'},
    'wiz_cal_only_school': {
      'cs': 'Jen pro studenty této školy.',
      'en': 'Only for students of this school.',
    },
    'wiz_cal_p': {
      'cs':
          'Vyberte kalendář své školy — prázdniny a uzávěrky absence se nastaví samy. Pokud tu vaše škola není, zvolte Vlastní dny: vše funguje stejně, jen prázdniny a uzávěrky doplníte v Nastavení.',
      'en':
          'Pick your school\u2019s calendar — holidays and absence closures are set automatically. If your school is not listed, choose Custom days: everything works the same, you just add holidays and closures in Settings.',
    },
    'wiz_cal_pick': {
      'cs': 'Vyber jednu možnost pro pokračování.',
      'en': 'Pick one option to continue.',
    },
    'wiz_disclaimer_ack': {'cs': 'Rozumím a beru na vědomí', 'en': 'I understand and accept this'},
    'wiz_disclaimer_h': {'cs': 'Než začneme', 'en': 'Before we start'},
    'wiz_disclaimer_need': {
      'cs': 'Pro pokračování potvrďte, že jste upozornění četli.',
      'en': 'Please confirm you have read the notice to continue.',
    },
    'wiz_disclaimer_p': {
      'cs':
          'Strakaláři je nezávislý studentský projekt bez oficiální podpory Bakalářů a Stravy. Přihlašovací údaje slouží jen k přihlášení do vašich systémů a ukládají se šifrovaně na tomto počítači.',
      'en':
          'Strakaláři is an independent student project with no official support from Bakaláři or Strava. Your logins are only used to sign in to your systems and are stored encrypted on this computer.',
    },
    'wiz_disclaimer_rules': {
      'cs':
          '• Používejte jen svůj vlastní účet a jen tak, jak to dovolují pravidla vaší školy a podmínky Bakalářů a Stravy.\n• Aplikace jedná vaším jménem: omluvenky i objednávky odeslané přes ni jsou vaše. Odeslanou omluvenku nelze vzít zpět.\n• Výchozí režim je S potvrzením — nic se neodešle bez vašeho kliknutí. Automatické úkony průběžně kontrolujte v Aktivitě; bezchybný provoz zaručit nemůžeme.\n• Software je poskytován bez záruky (GPLv3); autor neodpovídá za škody způsobené jeho použitím.',
      'en':
          '• Use only your own account, and only as your school\u2019s rules and the Bakaláři and Strava terms allow.\n• The app acts on your behalf: excuses and orders sent through it are yours. A sent excuse cannot be taken back.\n• The default mode is Ask me first — nothing is sent without your click. Review automated actions in Activity; error-free operation can\u2019t be guaranteed.\n• The software comes without warranty (GPLv3); the author is not liable for damage caused by its use.',
    },
    'wiz_done_h': {'cs': 'Vše je připraveno!', 'en': 'All set!'},
    'wiz_done_next': {
      'cs':
          'Potom: Dnes ukáže omluvenky ke schválení, Obědy výběr jídel — nic se neodesílá bez vás.',
      'en':
          'Next: Today shows excuses to approve, Lunches shows meal picks — nothing is sent without you.',
    },
    'wiz_done_p': {
      'cs': 'Nastavení je uloženo. Stiskněte Dokončit — první obnova dat se spustí sama.',
      'en': 'Settings are saved. Press Finish — the first data refresh starts automatically.',
    },
    'wiz_excuses_h': {'cs': 'Omluvenky', 'en': 'Excuses'},
    'wiz_excuses_p': {
      'cs':
          'Tímto jménem se podepíše každá omluvenka — bez něj by odešla nepodepsaná.',
      'en': 'Every excuse is signed with this name — without it, it would go out unsigned.',
    },
    'wiz_excuses_tpl': {
      'cs':
          'Texty omluvenek si můžete upravit — teď nebo kdykoli později v Nastavení → Šablony omluvenek. Podpis se připojí na konec sám.',
      'en':
          'You can edit the excuse texts — now or any time later in Settings → Excuse templates. The signature is added at the end automatically.',
    },
    'wiz_finish': {'cs': 'Dokončit', 'en': 'Finish'},
    'wiz_finishing_refresh': {
      'cs': 'Spouštím první obnovu dat…',
      'en': 'Starting the first data refresh…',
    },
    'wiz_limits_h': {'cs': 'Limity absence', 'en': 'Absence limits'},
    'wiz_limits_invalid': {
      'cs': 'Limit musí být číslo od 0 do 100.',
      'en': 'A limit must be a number from 0 to 100.',
    },
    'wiz_limits_loading': {
      'cs': 'Načítám předměty z Bakalářů…',
      'en': 'Loading subjects from Bakaláři…',
    },
    'wiz_limits_none': {
      'cs':
          'Předměty se zatím nepodařilo načíst. Limity můžete nastavit i později v Nastavení → Limity předmětů.',
      'en':
          'The subjects could not be loaded yet. You can also set the limits later in Settings → Subject limits.',
    },
    'wiz_limits_p': {
      'cs': 'Kolik procent hodin můžete v každém předmětu zameškat. Limit určuje vaše škola.',
      'en': 'The share of lessons you may miss in each subject. Your school sets the limit.',
    },
    'wiz_limits_retry': {'cs': 'Načíst znovu', 'en': 'Load again'},
    'wiz_need_ai_key': {
      'cs': 'Zapnete-li AI, vložte API klíč — nebo AI vypněte.',
      'en': 'With AI on, paste the API key — or turn AI off.',
    },
    'wiz_need_bakalari': {
      'cs': 'Vyplňte adresu, jméno i heslo Bakalářů.',
      'en': 'Fill in the Bakaláři URL, username and password.',
    },
    'wiz_need_signature': {
      'cs': 'Vyplňte jméno, kterým se omluvenky podepisují.',
      'en': 'Enter the name excuses are signed with.',
    },
    'wiz_need_strava': {
      'cs': 'Zapnete-li Stravu, vyplňte jméno, heslo i číslo jídelny.',
      'en': 'With Strava on, fill in username, password and canteen ID.',
    },
    'wiz_next': {'cs': 'Pokračovat', 'en': 'Continue'},
    'wiz_skip': {'cs': 'Přeskočit krok', 'en': 'Skip this step'},
    'wiz_step_of': {'cs': 'Krok {i} z {n}', 'en': 'Step {i} of {n}'},
    'wiz_strava_h': {'cs': 'Jídelna Strava', 'en': 'Strava canteen'},
    'wiz_strava_p': {
      'cs':
          'Pokud obědy neřešíte, integraci vypněte. Jinak vyplňte přihlášení a číslo jídelny.',
      'en':
          'If you don\u2019t use school lunches, turn the integration off. Otherwise fill in the login and canteen ID.',
    },
    'wiz_test_continue': {'cs': 'Otestovat a pokračovat', 'en': 'Test & continue'},
    'wiz_use_ai': {'cs': 'Používat AI doporučení', 'en': 'Use AI recommendations'},
    'wiz_welcome_h': {'cs': 'Vítejte ve Strakalářích!', 'en': 'Welcome to Strakaláři!'},
    'wiz_welcome_p': {
      'cs': 'V několika krocích nastavíme Bakaláře, jídelnu Strava a volitelně AI doporučení.',
      'en':
          'In a few steps we\u2019ll set up Bakaláři, the Strava canteen and optional AI recommendations.',
    },
  };
}
