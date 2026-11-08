import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Minimal cs/en string table for the ported Phase-6 screens.
///
/// The shell will provide the generated [Strings]/ARB table; until it
/// lands, views use [Str.t] so widget tests can run standalone.
/// Unknown keys fall back to the key itself (never a crash).
class Str {
  static String language = 'cs';

  static String t(String key, [Map<String, Object?> args = const {}]) {
    final table = tables[language] ?? tables['cs']!;
    var text = table[key] ?? tables['cs']![key] ?? key;
    args.forEach((k, v) {
      text = text.replaceAll('{$k}', '${v ?? ''}');
    });
    return text;
  }

  static const Map<String, Map<String, String>> tables = {
    'cs': {
      'nav_more': 'Více',
      'nav_absences': 'Absence',
      'nav_planner': 'Plánovač',
      'nav_activity': 'Aktivita',
      'nav_settings': 'Nastavení',
      'sec_alarm': 'Budík',
      'cancel': 'Zrušit',
      'confirm': 'Potvrdit',
      'close': 'Zavřít',
      'delete': 'Smazat',
      'add': 'Přidat',
      'saved': 'Uloženo',
      'save_failed': 'Uložení se nezdařilo',
      // planner
      'planner_title': 'Plánovač',
      'planner_desc': 'Kolik celých dnů si ještě můžeš dovolit.',
      'plan_buffer_note': 'Rezerva: {reserve} p. b.',
      'no_data': 'Zatím žádná data',
      'need_credentials': 'Nejprve se přihlas',
      'planner_need_refresh': 'Stáhni data tlačítkem Obnovit.',
      'plan_custom': 'Vlastní volno',
      'plan_custom_hint': 'Vyber dny a hodiny v kalendáři',
      'see_absences': 'Absence',
      'term_sem1': '1. pololetí',
      'term_sem2': '2. pololetí',
      'term_until': 'do {d}',
      'term_nothing': 'Žádné pololetí',
      'term_fresh': 'V tomto pololetí zatím nejsou absence.',
      'stat_can_afford': 'Ještě si může dovolit',
      'stat_planned': 'Naplánováno',
      'stat_tightest': 'Nejtěsnější předmět',
      'planner_horizon': 'Dnů ve hře',
      'hours_free': 'volných {n} h',
      'warn_over': 'Přes limit: {subjects}',
      'warn_reserve': 'V rezervě: {subjects}',
      'warn_pace': 'Rychlé tempo: {subjects}',
      'section_overview': 'Přehled',
      'overview_hint': 'Klepnutím na den ho naplánuj, klepnutím na naplánovaný den ho zruš.',
      'legend_school': 'Škola',
      'legend_free': 'Volno',
      'legend_recommended': 'Doporučeno',
      'legend_planned': 'Naplánováno',
      'legend_blocked': 'Nejde',
      'legend_today': 'Dnes',
      'legend_missed': 'Zameškáno',
      'legend_free_h': 'Volné hodiny',
      'legend_buffer': 'Rezerva',
      'tag_bridge': 'Přemostění +{n}',
      'tag_long_weekend': 'Prodloužený víkend',
      'tag_light': 'Lehký den',
      'tag_free': 'Volno?',
      'tag_final_week': 'Poslední týden',
      'tag_late_week': 'Pozdní týden',
      'day_cost': '{n} h',
      'day_cost_free': 'zdarma',
      'section_plan': 'Doporučený plán',
      'plan_explain': 'Rozloženo rovnoměrně do uzavření absencí.',
      'plan_budget_empty': 'Rozpočet je vyčerpaný.',
      'plan_target_met': 'Cíl splněn: {n} dní.',
      'plan_all': 'Naplánovat vše',
      'plan_all_title': 'Naplánovat doporučené dny',
      'plan_all_body': 'Dny: {days}',
      'plan_all_done': 'Naplánováno {n} dní',
      'plan_skip': 'Naplánovat volno',
      'skip_planned': 'Volno naplánováno',
      'skip_planned_keep_lunch': 'Volno naplánováno (oběd zůstává)',
      'skip_not_planned': 'Nepodařilo se naplánovat',
      'plan_removed': 'Plán zrušen',
      'today_left_note': 'zbývá {n} z {t} hodin',
      'choose_template': 'Omluvenka',
      'template_n': 'Šablona {n}',
      'default_excuse_template': 'Prosím o omluvení absence.',
      'target_label': 'Cíl pololetí',
      'target_auto': 'Co nejvíc ({n})',
      'days_one': '{n} den',
      'days_few': '{n} dny',
      'days_many': '{n} dní',
      'pick_how': 'Klepni na den pro celé volno, rozklikni ho pro výběr hodin.',
      'pick_empty': 'Nic vybráno',
      'pick_total': '{days} · {lessons}',
      'pick_rest_of_day': 'zbytek dne',
      'whole_day': 'Celý den',
      'pick_nothing': 'Nic z tohoto dne',
      'pick_no_lessons': 'Žádné hodiny k naplánování',
      'pick_selected': 'Vybráno',
      'pick_partial': 'Částečně',
      'pick_change': 'Změna',
      'pick_tip_none': 'Nelze naplánovat',
      'pick_started': 'Už začalo',
      'pick_from_stable': 'Ze stálého rozvrhu',
      'pick_from_guess': 'Odhad podle plánu',
      'pick_prev_month': 'Předchozí měsíc',
      'pick_next_month': 'Další měsíc',
      'pick_choose_lessons': 'Vybrat hodiny',
      'section_budgets': 'Rozpočty předmětů',
      'budget_over': 'Přes limit',
      'budget_reserve': 'V rezervě',
      'budget_tight': 'Těsné',
      'budget_ok': 'V pohodě',
      'budget_final': '{p} % · limit {limit}',
      'budget_line': 'volných {free} h · naplánováno {planned} h · rezerva {buffer} h',
      'planned_title': 'Naplánované volno',
      'no_planned': 'Zatím nic naplánováno.',
      'planned_cost': 'cena {h} h',
      'day_passed': 'Proběhlo',
      'holidays_note': 'Prázdniny a volna se berou z nastavení kalendáře.',
      'cal_open_calendar': 'Otevřít kalendář',
      'cal_tip_free': 'Volno',
      'cal_tip_past': 'Proběhlo',
      'cal_tip_planned': 'Naplánováno',
      'cal_tip_recommended': 'Doporučeno (cena {h} h)',
      'cal_tip_fits': 'Vejde se (cena {h} h)',
      'cal_tip_blocked': 'Nejde: {subjects}',
      'cal_tip_final': 'Poslední týden před uzavřením',
      'unplan': 'Zrušit plán',
      'impact_title': 'Dopad na limity',
      'impact_row': '{name}: cena {cost} h · zbude {left} h · projekce {p} %',
      'impact_none': 'Bez dopadu na limity.',
      'impact_ok': 'Vejde se do limitů.',
      'impact_over': 'Překročí limit!',
      'impact_reserve': 'Zasáhne do rezervy.',
      'plan_cancel_lunch': 'Zrušit i oběd',
      'lunch_cannot_cancel': 'Oběd už zrušit nejde ({deadline})',
      'custom_from_lesson': 'Od',
      'custom_to_lesson': 'Do',
      'reserve_title': 'Plánovací rezerva',
      'reserve_body': 'Kolik procentních bodů pod limitem se plán zastaví.',
      // lunches
      'lunch_title': 'Obědy',
      'strava_disabled_title': 'Strava je vypnutá',
      'strava_disabled_msg': 'Zapni ji v nastavení v Účtech.',
      'go_to_settings': 'Do nastavení',
      'pick_hint': 'Klepnutím na jídlo ho vybereš, Odeslat vše odešle najednou.',
      'send_orders': 'Odeslat',
      'already_running': 'Už běží',
      'no_changes': 'Žádné změny',
      'ai_section': 'AI doporučení',
      'ai_prefs': 'Co (ne)mám rád',
      'ai_prefs_hint': 'např. nemám rád vepřové',
      'ai_no_key': 'Bez Gemini klíče AI nevaří.',
      'ai_key_link': 'Získat klíč',
      'recommend': 'Doporučit',
      'apply_filter_long': 'Použít filtr',
      'filter_hint': 'Skryje nechtěná jídla a předvybere zbytek.',
      'ai_running': 'AI přemýšlí…',
      'hidden_meals': 'Skryto jídel: {n}',
      'lunch_soup': 'Polévka',
      'allergens': 'Alergeny',
      'no_order_option': 'Bez oběda',
      'lunch_closed_badge': 'Uzavřeno',
      'lunch_show_past': 'Starší ({n})',
      'lunch_hide_past': 'Skrýt starší',
      'lunch_empty_no_menu': 'Jídelníček zatím nepřišel.',
      'lunch_empty_no_login': 'Bez přihlášení ke Stravě menu nebude.',
      'web_ordered': 'Objednáno ve Stravě',
      'to_send': 'K odeslání',
      'no_lunch': 'Bez oběda',
      'blacklist_section': 'Černá listina jídel',
      'blacklist_hint': 'Slova, která jídlo nikdy nesmí obsahovat.',
      'no_blacklist': 'Prázdná.',
      'add_word': 'Slovo',
      'ai_tools': 'AI a filtr',
      'hide_sidebar': 'Skrýt panel',
      'show_sidebar': 'Zobrazit panel',
      'orders_sending': 'Odesílám objednávky',
      'orders_sent': 'Objednávky odeslány',
      'orders_failed': 'Odeslání se nezdařilo',
      'orders_dry_run': 'Zkušební režim — nic se neodeslalo',
      'lunch_order_closed': 'Objednávky jsou uzavřeny',
      'low_balance_title': 'Dochází kredit',
      'low_balance_body': 'Dny: {days}',
      'recommend_no_key': 'Nejprve vlož Gemini klíč.',
      'ai_already_running': 'AI už běží',
      // activity
      'activity_title': 'Aktivita',
      'app_version': 'Verze',
      'check_updates': 'Zkontrolovat aktualizace',
      'checking_updates': 'Hledám aktualizace…',
      'refresh_data': 'Obnovit',
      'refresh_all': 'Vše',
      'scope_bakalari': 'Bakaláři',
      'scope_strava': 'Strava',
      'refresh_scope': 'Co obnovit',
      'cancel_refresh': 'Zrušit obnovu',
      'refreshing': 'Obnovuji…',
      'activity_working_hint': 'Pracuji na pozadí, klidně pokračuj.',
      'status_error': 'Chyba',
      'status_ok': 'Vše v pořádku',
      'status_idle': 'Zatím klid',
      'activity_last_ok': 'Poslední běh {when} proběhl.',
      'activity_last_failed': 'Poslední běh {when} selhal.',
      'activity_last_cancelled': 'Poslední běh {when} zrušen.',
      'no_runs_yet': 'Zatím žádný běh.',
      'last_run': 'Poslední běh',
      'next_run': 'Další běh',
      'stat_success': 'Úspěšnost',
      'stat_sent_week': 'Odesláno za týden',
      'run_history': 'Historie běhů',
      'run_done': 'Hotovo',
      'run_failed': 'Selhalo',
      'run_cancelled': 'Zrušeno',
      'run_took': 'trvalo {d}',
      'live_log': 'Živý deník',
      'log_errors': 'chyb: {n}',
      'log_copy_tooltip': 'Kopírovat deník',
      'no_log_yet': 'Deník je zatím prázdný.',
      'clear_log': 'Vymazat deník',
      'automation_card': 'Automatizace',
      'automation_paused_banner': 'Automatizace pozastavena',
      'automation_running': 'Automatizace běží.',
      'automation_pause': 'Pozastavit automatizaci',
      'automation_pause_hint': 'Pozastaví všechny automatické běhy.',
      'automation_edit': 'Upravit pravidla',
      'excuse_mode_label': 'Režim omluvenek',
      'order_mode_label': 'Režim objednávek',
      'mode_auto': 'Automaticky',
      'mode_confirm': 'S potvrzením',
      'mode_dry_run': 'Zkušební',
      'automation_history': 'Historie automatizace',
      'audit_filter_all': 'Vše',
      'audit_filter_excuse': 'Omluvenky',
      'audit_filter_lunch': 'Obědy',
      'automation_history_empty': 'Zatím nic neodesláno.',
      'audit_kind_excuse': 'Omluvenka',
      'audit_kind_lunch': 'Oběd',
      'audit_lunch_order': 'objednávka',
      'audit_lunch_cancel': 'odhláška',
      'audit_reason_low_balance': 'málo kreditu',
      'audit_source_auto': 'automaticky',
      'audit_source_manual': 'ručně',
      'audit_sent': 'Odesláno',
      'audit_dry_run': 'Zkušební',
      'audit_covered': 'Pokryto',
      'audit_skipped': 'Přeskočeno',
      'audit_unconfirmed': 'Nepotvrzeno',
      'audit_failed': 'Selhalo',
      'ago_now': 'právě teď',
      'ago_min': 'před {n} min',
      'ago_hours': 'před {n} h',
      'error_details': 'Detaily chyby',
      'error_title': 'Něco se pokazilo',
      'error_copy_logs': 'Kopírovat deník',
      'error_copied': 'Zkopírováno',
      'error_copy_failed': 'Kopírování selhalo',
      'error_hint': 'Co se stalo (technicky):',
      'error_not_yours': 'Není to tvoje chyba? Zkopíruj to a pošli.',
      'error_close': 'Zavřít',
      'update_available': 'Nová verze {v}',
      'update_desc': 'Nainstalováno {cur}, vyšla {v}.',
      'download_update': 'Stáhnout',
      'update_dismiss': 'Zahodit',
      // settings
      'settings_title': 'Nastavení',
      'sec_accounts': 'Účty',
      'sec_limits': 'Limity',
      'sec_calendar': 'Školní kalendář',
      'sec_templates': 'Šablony omluvenek',
      'sec_rules': 'Pravidla automatizace',
      'sec_browser': 'Běh na pozadí',
      'sec_appearance': 'Vzhled',
      'sec_ai': 'AI',
      'sec_advanced': 'Pokročilé',
      'sec_notifications': 'Oznámení',
      'sec_diagnostics': 'Diagnostika',
      'sec_group_school': 'Škola',
      'sec_group_automation': 'Automatizace',
      'sec_group_app': 'Aplikace',
      'sec_group_advanced': 'Pokročilé',
      'account_bakalari': 'Bakaláři',
      'account_strava': 'Strava',
      'bakalari_url': 'Adresa Bakalářů',
      'bakalari_url_hint': 'např. https://skola.bakalari.cz',
      'username': 'Uživatelské jméno',
      'password': 'Heslo',
      'strava_url': 'Adresa Stravy',
      'canteen_id': 'Číslo jídelny',
      'canteen_id_hint': 'Najdeš ho v adrese objednávky.',
      'use_strava': 'Používat Stravu',
      'test_bakalari': 'Test Bakalářů',
      'test_strava': 'Test Stravy',
      'password_saved_hint': 'Uloženo (prázdné = beze změny)',
      'secret_empty': 'Nevyplněno',
      'testing': 'Testuji…',
      'connection_ok': 'Spojení funguje',
      'connection_failed': 'Spojení selhalo',
      'default_limit': 'Výchozí limit absence (%)',
      'warn_limit': 'Varovný limit (%)',
      'reserve_limit': 'Plánovací rezerva (p. b.)',
      'reserve_hint': 'Plán se zastaví tolik bodů pod limitem.',
      'limit_subject_hint': 'Prázdné = výchozí limit.',
      'cal_preset': 'Školní prázdniny',
      'cal_custom_opt': 'Vlastní',
      'cal_sem1': 'Uzavření 1. pololetí',
      'cal_sem2': 'Uzavření 2. pololetí',
      'cal_closes': 'Uzavření: {a} / {b}',
      'cal_summary': 'Volna: škola {preset}, vlastní {added}, zrušená {forced}',
      'cal_auto': 'automaticky',
      'cal_preset_hint': 'prázdné = z předvolby',
      'cal_marks_bands': 'Známková pásma: {bands}',
      'cal_free_days': 'Dny volna',
      'cal_date': 'Datum',
      'cal_label': 'Popisek',
      'cal_from': 'Od',
      'cal_to': 'Do',
      'cal_add_single': 'Přidat den',
      'cal_add_range': 'Přidat rozsah',
      'cal_added': 'Přidáno',
      'cal_range_added': 'Přidáno {n} dní',
      'cal_duplicate': 'Tento den už je volný',
      'cal_invalid_date': 'Špatné datum (D.M.RRRR)',
      'cal_invalid_range': 'Špatný rozsah dat',
      'cal_my': 'Vlastní',
      'cal_cancel_preset': 'Zrušit výuku',
      'cal_school_override': 'Výuka i přes volno',
      'cal_restore': 'Obnovit',
      'cal_range_days': '{n} dní',
      'cal_no_days': 'Žádné dny volna.',
      'cal_show_past': 'Starší ({n})',
      'cal_hide_past': 'Skrýt starší',
      'cal_clear_past': 'Smazat proběhlé',
      'tpl_late': 'Pozdní příchody',
      'tpl_soon': 'Dřívější odchody',
      'tpl_short': 'Krátké absence',
      'tpl_long': 'Dlouhé absence',
      'tpl_name': 'Název {n}',
      'tpl_name_hint': 'např. Rodina',
      'tpl_text': 'Text omluvenky',
      'signature': 'Podpis',
      'automation_disclaimer': 'Automatizace posílá omluvenky tvým jménem.',
      'automation_modes_hint': 'Automaticky = bez ptaní. Zkušební = nic neodešle.',
      'check_interval': 'Interval kontrol (min)',
      'excuse_delay': 'Odklad omluvenky (dny)',
      'go_back_weeks': 'Týdnů zpět',
      'go_forward_weeks': 'Týdnů vpřed',
      'default_excuse_pick': 'Výběr omluvenky',
      'pick_first': 'První',
      'pick_random': 'Náhodná',
      'lunch_cutoff_label': 'Uzávěrka obědů (HH:MM)',
      'lunch_cutoff_hint': 'předchozí pracovní den',
      'lunch_cutoff_invalid': 'Špatný čas (HH:MM)',
      'wakeup_title': 'Budík',
      'wakeup_enable': 'Budík zapnutý',
      'wakeup_minutes': 'Minut před první hodinou',
      'wakeup_unavailable': 'Na tomto zařízení není k dispozici.',
      'wakeup_hint': 'Zazvoní {n} minut před první hodinou.',
      'wakeup_none': 'Žádný budík v dohlednu.',
      'wakeup_next': 'Zazvoní {day} v {alarm} ({subject}, {lesson}).',
      'wakeup_next_eve': 'Zazvoní večer {day} v {alarm} ({subject}).',
      'wakeup_skip_next': 'Přeskočit',
      'wakeup_set_clock': 'Do hodin',
      'wakeup_clock_weekly': 'Týdenní: {day} v {time}.',
      'wakeup_skipped': 'Přeskočené dny:',
      'wakeup_restore_day': 'Obnovit {day}',
      'wakeup_restore_alarm': 'Obnovit {day} {time}',
      'wakeup_notif_off': 'Oznámení jsou vypnutá.',
      'wakeup_exact_off': 'Přesné budíky jsou vypnuté.',
      'wakeup_exact_allow': 'Povolit přesné budíky',
      'wakeup_clock_failed': 'Hodiny se nepodařilo otevřít',
      'wakeup_minutes_invalid': 'Špatný počet minut',
      'notif_allow': 'Povolit',
      'notif_open_settings': 'Otevřít nastavení',
      'autostart': 'Spouštět po startu',
      'autostart_failed': 'Nepodařilo se nastavit',
      'autostart_store_managed': 'Verze ze Storu spouští Windows sám.',
      'autostart_open_settings': 'Otevřít nastavení spouštění',
      'minimize_to_tray': 'Minimalizovat do lišty',
      'run_in_background': 'Běžet na pozadí',
      'run_in_background_hint': 'Služba kontroluje data i se zavřenou aplikací.',
      'bg_overview_title': 'Co ukazuje oznámení',
      'bg_overview_hint': 'Vyber řádky stavového oznámení.',
      'bg_item_next_lesson': 'Další hodina',
      'bg_item_lunch': 'Oběd',
      'bg_item_lunch_orders': 'Objednávky',
      'bg_item_excuses': 'Omluvenky',
      'bg_item_wakeup': 'Budík',
      'bg_preview': 'Náhled',
      'bg_notif_title': 'Strakaláři běží',
      'bg_notif_text': 'Kontrola každých {n} min.',
      'theme_dark': 'Tmavý',
      'theme_light': 'Světlý',
      'language': 'Jazyk',
      'density': 'Hustota',
      'density_compact': 'kompaktní',
      'tutorials': 'Návody',
      'tutorials_hint': 'Krátké prohlídky při prvním použití.',
      'tutorials_toggle': 'Návody zapnuté',
      'tutorials_replay': 'Přehrát znovu',
      'tutorials_replayed': 'Návody se zase ukážou.',
      'cache_ttl': 'Platnost mezipaměti (h)',
      'timeout_page': 'Timeout stránky (s)',
      'log_file': 'Soubor deníku',
      'blacklist_file': 'Soubor černé listiny',
      'update_channel': 'Kanál aktualizací',
      'update_channel_stable': 'Stabilní',
      'update_channel_beta': 'Beta',
      'update_channel_hint': 'Beta nabízí i testovací verze.',
      'update_store_managed': 'Aktualizace řeší obchod.',
      'latest_version': 'Nejnovější verze',
      'up_to_date': 'aktuální',
      'config_problems': 'Problémy v nastavení:',
      'config_ok': 'Nastavení je v pořádku.',
      'cache_info': 'Mezipaměť',
      'clear_cache': 'Vymazat mezipaměť',
      'cache_cleared': 'Mezipaměť vymazána.',
      'gemini_key': 'Gemini klíč',
      'gemini_model': 'Model',
      'key_saved_hint': 'Uloženo (prázdné = beze změny)',
      'ai_key_steps': 'Klíč zdarma na aistudio.google.com.',
      'gemini_key_hint': 'Nikam se neposílá kromě Gemini.',
      'ai_model_hint': 'Např. gemini-3.8-flash.',
      'ai_auto_enable': 'Automatické doporučování',
      'ai_auto_hint': 'Po každé obnově menu.',
      'ai_prompt': 'Vlastní přání',
      'ai_prompt_hint': 'např. v pátek bezmasé',
      'ai_interval': 'Jak často (dny)',
      'ai_interval_hint': '1–30 dní.',
      'ai_last_run': 'Naposledy',
      'ai_never': 'nikdy',
      'wiz_test_key': 'Test klíče',
      // tutorial
      'tut_start': 'Ukázat',
      'tut_not_now': 'Teď ne',
      'tut_off_note': 'Návody lze vrátit v Nastavení → Vzhled.',
      'tut_turn_off': 'Vypnout návody',
      'tut_skip_tour': 'Přeskočit návod',
      'tut_next': 'Dál',
      'tut_back': 'Zpět',
      'tut_done': 'Hotovo',
      'tut_later': 'Později',
      'tut_skip_step': 'Přeskočit krok',
      'tut_intro_welcome_title': 'Vítej ve Strakalářích!',
      'tut_intro_welcome_body': 'Krátká prohlídka toho nejdůležitějšího.',
      'tut_intro_nav_title': 'Navigace',
      'tut_intro_nav_body': 'Tady přepínáš obrazovky.',
      'tut_intro_refresh_title': 'Obnovení',
      'tut_intro_refresh_body': 'Tady stahuješ čerstvá data.',
      'tut_intro_status_title': 'Stav',
      'tut_intro_status_body': 'Tady vidíš, co aplikace dělá.',
      'tut_intro_done_title': 'To je vše',
      'tut_intro_done_body': 'Návody najdeš i v nastavení.',
      'tut_excuse_pick_title': 'Nevyřízená omluvenka',
      'tut_excuse_pick_body': 'Tady ji vybereš.',
      'tut_excuse_send_title': 'Odeslat',
      'tut_excuse_send_body': 'Tímto ji odešleš.',
      'tut_excuse_send_try': 'Zkus to: odešli omluvenku.',
      'tut_excuse_done_title': 'Hotovo',
      'tut_excuse_done_body': 'Tak to chodí.',
      'tut_tt_weeks_title': 'Týdny',
      'tut_tt_weeks_body': 'Listuj mezi týdny.',
      'tut_tt_colors_title': 'Barvy',
      'tut_tt_colors_body': 'Barvy značí změny a absence.',
      'tut_abs_stats_title': 'Souhrn',
      'tut_abs_stats_body': 'Tady je přehled absence.',
      'tut_abs_subject_title': 'Předměty',
      'tut_abs_subject_body': 'Klepni pro detail předmětu.',
      'tut_plan_strip_title': 'Přehled roku',
      'tut_plan_strip_body': 'Tady vidíš celý rok.',
      'tut_plan_pick_title': 'Naplánuj den',
      'tut_plan_pick_body': 'Klepni na den a naplánuj si volno.',
      'tut_plan_pick_try': 'Zkus to: naplánuj si den.',
      'tut_plan_budget_title': 'Rozpočty',
      'tut_plan_budget_body': 'Kolik hodin zbývá předmětům.',
      'tut_lunch_pick_title': 'Vyber oběd',
      'tut_lunch_pick_body': 'Klepni na jídlo.',
      'tut_lunch_pick_try': 'Zkus to: vyber si oběd.',
      'tut_lunch_send_title': 'Odešli objednávku',
      'tut_lunch_send_body': 'Tímto vše odešleš najednou.',
      'tut_lunch_send_try': 'Zkus to: odešli objednávky.',
      'tut_lunch_tools_title': 'AI a filtr',
      'tut_lunch_tools_body': 'Tady ladíš výběr jídel.',
      'tut_marks_stats_title': 'Průměry',
      'tut_marks_stats_body': 'Tady je přehled známek.',
      'tut_marks_subject_title': 'Předmět',
      'tut_marks_subject_body': 'Klepni pro detail.',
      'tut_marks_subject_try': 'Zkus to: otevři předmět.',
      'tut_marks_need_title': 'Co potřebuješ',
      'tut_marks_need_body': 'Jakou známku musíš dostat.',
      'tut_marks_predict_title': 'Prediktor',
      'tut_marks_predict_body': 'Vyzkoušej si, co by bylo kdyby.',
      'tut_marks_predict_try': 'Zkus to: přidej předpověď.',
      'tut_marks_scale_title': 'Stupnice',
      'tut_marks_scale_body': 'Tady přepínáš stupnici.',
      'tut_settings_intro_title': 'Nastavení',
      'tut_settings_intro_body': 'Vše důležité je tady.',
      'tut_activity_intro_title': 'Aktivita',
      'tut_activity_intro_body': 'Tady vidíš, co aplikace dělá.',
    },
    'en': {
      'nav_more': 'More',
      'nav_absences': 'Absences',
      'nav_planner': 'Planner',
      'nav_activity': 'Activity',
      'nav_settings': 'Settings',
      'sec_alarm': 'Alarm',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'close': 'Close',
      'delete': 'Delete',
      'add': 'Add',
      'saved': 'Saved',
      'save_failed': 'Save failed',
      'planner_title': 'Planner',
      'planner_desc': 'How many whole days you can still afford.',
      'plan_buffer_note': 'Reserve: {reserve} pp.',
      'no_data': 'No data yet',
      'need_credentials': 'Log in first',
      'planner_need_refresh': 'Fetch data with Refresh first.',
      'plan_custom': 'Custom days off',
      'plan_custom_hint': 'Pick days and lessons in the calendar',
      'see_absences': 'Absences',
      'term_sem1': 'Semester 1',
      'term_sem2': 'Semester 2',
      'term_until': 'until {d}',
      'term_nothing': 'No semester',
      'term_fresh': 'No absences in this semester yet.',
      'stat_can_afford': 'Can still afford',
      'stat_planned': 'Planned',
      'stat_tightest': 'Tightest subject',
      'planner_horizon': 'Days in play',
      'hours_free': '{n} h free',
      'warn_over': 'Over limit: {subjects}',
      'warn_reserve': 'In reserve: {subjects}',
      'warn_pace': 'Fast pace: {subjects}',
      'section_overview': 'Overview',
      'overview_hint': 'Tap a day to plan it, tap a planned day to unplan.',
      'legend_school': 'School',
      'legend_free': 'Free',
      'legend_recommended': 'Recommended',
      'legend_planned': 'Planned',
      'legend_blocked': 'Blocked',
      'legend_today': 'Today',
      'legend_missed': 'Missed',
      'legend_free_h': 'Free hours',
      'legend_buffer': 'Reserve',
      'tag_bridge': 'Bridge +{n}',
      'tag_long_weekend': 'Long weekend',
      'tag_light': 'Light day',
      'tag_free': 'Free?',
      'tag_final_week': 'Final week',
      'tag_late_week': 'Late week',
      'day_cost': '{n} h',
      'day_cost_free': 'free',
      'section_plan': 'Recommended plan',
      'plan_explain': 'Spread evenly until the absence closure.',
      'plan_budget_empty': 'Budget is spent.',
      'plan_target_met': 'Target met: {n} days.',
      'plan_all': 'Plan all',
      'plan_all_title': 'Plan recommended days',
      'plan_all_body': 'Days: {days}',
      'plan_all_done': 'Planned {n} days',
      'plan_skip': 'Plan a day off',
      'skip_planned': 'Day off planned',
      'skip_planned_keep_lunch': 'Day off planned (lunch kept)',
      'skip_not_planned': 'Could not plan',
      'plan_removed': 'Plan removed',
      'today_left_note': '{n} of {t} lessons left',
      'choose_template': 'Excuse template',
      'template_n': 'Template {n}',
      'default_excuse_template': 'Please excuse the absence.',
      'target_label': 'Semester target',
      'target_auto': 'As many as fit ({n})',
      'days_one': '{n} day',
      'days_few': '{n} days',
      'days_many': '{n} days',
      'pick_how': 'Tap a day for the whole day off, expand it to pick lessons.',
      'pick_empty': 'Nothing selected',
      'pick_total': '{days} · {lessons}',
      'pick_rest_of_day': 'rest of the day',
      'whole_day': 'Whole day',
      'pick_nothing': 'Nothing of this day',
      'pick_no_lessons': 'No lessons to plan',
      'pick_selected': 'Selected',
      'pick_partial': 'Partial',
      'pick_change': 'Change',
      'pick_tip_none': 'Cannot plan',
      'pick_started': 'Already started',
      'pick_from_stable': 'From the stable timetable',
      'pick_from_guess': 'Estimated from the plan',
      'pick_prev_month': 'Previous month',
      'pick_next_month': 'Next month',
      'pick_choose_lessons': 'Pick lessons',
      'section_budgets': 'Subject budgets',
      'budget_over': 'Over limit',
      'budget_reserve': 'In reserve',
      'budget_tight': 'Tight',
      'budget_ok': 'Fine',
      'budget_final': '{p} % · limit {limit}',
      'budget_line': '{free} h free · {planned} h planned · {buffer} h reserve',
      'planned_title': 'Planned days off',
      'no_planned': 'Nothing planned yet.',
      'planned_cost': 'cost {h} h',
      'day_passed': 'Past',
      'holidays_note': 'Free days come from the calendar settings.',
      'cal_open_calendar': 'Open calendar',
      'cal_tip_free': 'Free',
      'cal_tip_past': 'Past',
      'cal_tip_planned': 'Planned',
      'cal_tip_recommended': 'Recommended (cost {h} h)',
      'cal_tip_fits': 'Fits (cost {h} h)',
      'cal_tip_blocked': 'Blocked: {subjects}',
      'cal_tip_final': 'Final week before closure',
      'unplan': 'Unplan',
      'impact_title': 'Effect on limits',
      'impact_row': '{name}: cost {cost} h · {left} h left · projection {p} %',
      'impact_none': 'No effect on limits.',
      'impact_ok': 'Fits the limits.',
      'impact_over': 'Exceeds the limit!',
      'impact_reserve': 'Eats into the reserve.',
      'plan_cancel_lunch': 'Also cancel lunch',
      'lunch_cannot_cancel': 'Lunch can no longer be cancelled ({deadline})',
      'custom_from_lesson': 'From',
      'custom_to_lesson': 'To',
      'reserve_title': 'Planning reserve',
      'reserve_body': 'How many points under the limit planning stops at.',
      'lunch_title': 'Lunches',
      'strava_disabled_title': 'Strava is off',
      'strava_disabled_msg': 'Turn it on in Settings → Accounts.',
      'go_to_settings': 'To settings',
      'pick_hint': 'Tap a meal to pick it, Send pushes everything at once.',
      'send_orders': 'Send',
      'already_running': 'Already running',
      'no_changes': 'No changes',
      'ai_section': 'AI recommendations',
      'ai_prefs': 'Likes / dislikes',
      'ai_prefs_hint': 'e.g. no pork',
      'ai_no_key': 'No Gemini key, no AI cooking.',
      'ai_key_link': 'Get a key',
      'recommend': 'Recommend',
      'apply_filter_long': 'Apply filter',
      'filter_hint': 'Hides unwanted meals and pre-picks the rest.',
      'ai_running': 'AI is thinking…',
      'hidden_meals': 'Hidden meals: {n}',
      'lunch_soup': 'Soup',
      'allergens': 'Allergens',
      'no_order_option': 'No lunch',
      'lunch_closed_badge': 'Closed',
      'lunch_show_past': 'Older ({n})',
      'lunch_hide_past': 'Hide older',
      'lunch_empty_no_menu': 'No menu arrived yet.',
      'lunch_empty_no_login': 'No Strava login, no menu.',
      'web_ordered': 'Ordered in Strava',
      'to_send': 'To send',
      'no_lunch': 'No lunch',
      'blacklist_section': 'Food blacklist',
      'blacklist_hint': 'Words a meal must never contain.',
      'no_blacklist': 'Empty.',
      'add_word': 'Word',
      'ai_tools': 'AI & filter',
      'hide_sidebar': 'Hide panel',
      'show_sidebar': 'Show panel',
      'orders_sending': 'Sending orders',
      'orders_sent': 'Orders sent',
      'orders_failed': 'Sending failed',
      'orders_dry_run': 'Dry run — nothing was sent',
      'lunch_order_closed': 'Ordering is closed',
      'low_balance_title': 'Low credit',
      'low_balance_body': 'Days: {days}',
      'recommend_no_key': 'Enter a Gemini key first.',
      'ai_already_running': 'AI is already running',
      'activity_title': 'Activity',
      'app_version': 'Version',
      'check_updates': 'Check for updates',
      'checking_updates': 'Checking for updates…',
      'refresh_data': 'Refresh',
      'refresh_all': 'All',
      'scope_bakalari': 'Bakaláři',
      'scope_strava': 'Strava',
      'refresh_scope': 'What to refresh',
      'cancel_refresh': 'Cancel refresh',
      'refreshing': 'Refreshing…',
      'activity_working_hint': 'Working in the background, carry on.',
      'status_error': 'Error',
      'status_ok': 'All good',
      'status_idle': 'Idle so far',
      'activity_last_ok': 'Last run {when} went fine.',
      'activity_last_failed': 'Last run {when} failed.',
      'activity_last_cancelled': 'Last run {when} was cancelled.',
      'no_runs_yet': 'No runs yet.',
      'last_run': 'Last run',
      'next_run': 'Next run',
      'stat_success': 'Success rate',
      'stat_sent_week': 'Sent this week',
      'run_history': 'Run history',
      'run_done': 'Done',
      'run_failed': 'Failed',
      'run_cancelled': 'Cancelled',
      'run_took': 'took {d}',
      'live_log': 'Live log',
      'log_errors': 'errors: {n}',
      'log_copy_tooltip': 'Copy log',
      'no_log_yet': 'The log is still empty.',
      'clear_log': 'Clear log',
      'automation_card': 'Automation',
      'automation_paused_banner': 'Automation paused',
      'automation_running': 'Automation is running.',
      'automation_pause': 'Pause automation',
      'automation_pause_hint': 'Pauses every automatic run.',
      'automation_edit': 'Edit rules',
      'excuse_mode_label': 'Excuse mode',
      'order_mode_label': 'Order mode',
      'mode_auto': 'Automatic',
      'mode_confirm': 'Confirm',
      'mode_dry_run': 'Dry run',
      'automation_history': 'Automation history',
      'audit_filter_all': 'All',
      'audit_filter_excuse': 'Excuses',
      'audit_filter_lunch': 'Lunches',
      'automation_history_empty': 'Nothing sent yet.',
      'audit_kind_excuse': 'Excuse',
      'audit_kind_lunch': 'Lunch',
      'audit_lunch_order': 'order',
      'audit_lunch_cancel': 'cancellation',
      'audit_reason_low_balance': 'low credit',
      'audit_source_auto': 'automatic',
      'audit_source_manual': 'manual',
      'audit_sent': 'Sent',
      'audit_dry_run': 'Dry run',
      'audit_covered': 'Covered',
      'audit_skipped': 'Skipped',
      'audit_unconfirmed': 'Unconfirmed',
      'audit_failed': 'Failed',
      'ago_now': 'just now',
      'ago_min': '{n} min ago',
      'ago_hours': '{n} h ago',
      'error_details': 'Error details',
      'error_title': 'Something broke',
      'error_copy_logs': 'Copy log',
      'error_copied': 'Copied',
      'error_copy_failed': 'Copy failed',
      'error_hint': 'What happened (technical):',
      'error_not_yours': 'Not your fault? Copy it and send it over.',
      'error_close': 'Close',
      'update_available': 'New version {v}',
      'update_desc': 'Installed {cur}, {v} is out.',
      'download_update': 'Download',
      'update_dismiss': 'Dismiss',
      'settings_title': 'Settings',
      'sec_accounts': 'Accounts',
      'sec_limits': 'Limits',
      'sec_calendar': 'School calendar',
      'sec_templates': 'Excuse templates',
      'sec_rules': 'Automation rules',
      'sec_browser': 'Background running',
      'sec_appearance': 'Appearance',
      'sec_ai': 'AI',
      'sec_advanced': 'Advanced',
      'sec_notifications': 'Notifications',
      'sec_diagnostics': 'Diagnostics',
      'sec_group_school': 'School',
      'sec_group_automation': 'Automation',
      'sec_group_app': 'App',
      'sec_group_advanced': 'Advanced',
      'account_bakalari': 'Bakaláři',
      'account_strava': 'Strava',
      'bakalari_url': 'Bakaláři URL',
      'bakalari_url_hint': 'e.g. https://school.bakalari.cz',
      'username': 'Username',
      'password': 'Password',
      'strava_url': 'Strava URL',
      'canteen_id': 'Canteen number',
      'canteen_id_hint': 'Find it in the order URL.',
      'use_strava': 'Use Strava',
      'test_bakalari': 'Test Bakaláři',
      'test_strava': 'Test Strava',
      'password_saved_hint': 'Saved (empty = unchanged)',
      'secret_empty': 'Empty',
      'testing': 'Testing…',
      'connection_ok': 'Connection works',
      'connection_failed': 'Connection failed',
      'default_limit': 'Default absence limit (%)',
      'warn_limit': 'Warning limit (%)',
      'reserve_limit': 'Planning reserve (pp)',
      'reserve_hint': 'Planning stops this far under the limit.',
      'limit_subject_hint': 'Empty = default limit.',
      'cal_preset': 'School holidays',
      'cal_custom_opt': 'Custom',
      'cal_sem1': 'Semester 1 closure',
      'cal_sem2': 'Semester 2 closure',
      'cal_closes': 'Closures: {a} / {b}',
      'cal_summary': 'Free days: school {preset}, own {added}, cancelled {forced}',
      'cal_auto': 'automatic',
      'cal_preset_hint': 'empty = from preset',
      'cal_marks_bands': 'Grade bands: {bands}',
      'cal_free_days': 'Free days',
      'cal_date': 'Date',
      'cal_label': 'Label',
      'cal_from': 'From',
      'cal_to': 'To',
      'cal_add_single': 'Add day',
      'cal_add_range': 'Add range',
      'cal_added': 'Added',
      'cal_range_added': 'Added {n} days',
      'cal_duplicate': 'This day is already free',
      'cal_invalid_date': 'Bad date (D.M.YYYY)',
      'cal_invalid_range': 'Bad date range',
      'cal_my': 'Own',
      'cal_cancel_preset': 'Cancel lessons',
      'cal_school_override': 'School despite free day',
      'cal_restore': 'Restore',
      'cal_range_days': '{n} days',
      'cal_no_days': 'No free days.',
      'cal_show_past': 'Older ({n})',
      'cal_hide_past': 'Hide older',
      'cal_clear_past': 'Delete past',
      'tpl_late': 'Late arrivals',
      'tpl_soon': 'Early leaves',
      'tpl_short': 'Short absences',
      'tpl_long': 'Long absences',
      'tpl_name': 'Name {n}',
      'tpl_name_hint': 'e.g. Family',
      'tpl_text': 'Excuse text',
      'signature': 'Signature',
      'automation_disclaimer': 'Automation sends excuses in your name.',
      'automation_modes_hint': 'Automatic = no asking. Dry run = sends nothing.',
      'check_interval': 'Check interval (min)',
      'excuse_delay': 'Excuse delay (days)',
      'go_back_weeks': 'Weeks back',
      'go_forward_weeks': 'Weeks forward',
      'default_excuse_pick': 'Excuse picking',
      'pick_first': 'First',
      'pick_random': 'Random',
      'lunch_cutoff_label': 'Lunch cutoff (HH:MM)',
      'lunch_cutoff_hint': 'previous business day',
      'lunch_cutoff_invalid': 'Bad time (HH:MM)',
      'wakeup_title': 'Alarm',
      'wakeup_enable': 'Alarm on',
      'wakeup_minutes': 'Minutes before first lesson',
      'wakeup_unavailable': 'Not available on this device.',
      'wakeup_hint': 'Rings {n} minutes before the first lesson.',
      'wakeup_none': 'No alarm in sight.',
      'wakeup_next': 'Rings {day} at {alarm} ({subject}, {lesson}).',
      'wakeup_next_eve': 'Rings in the evening {day} at {alarm} ({subject}).',
      'wakeup_skip_next': 'Skip',
      'wakeup_set_clock': 'To clock app',
      'wakeup_clock_weekly': 'Weekly: {day} at {time}.',
      'wakeup_skipped': 'Skipped days:',
      'wakeup_restore_day': 'Restore {day}',
      'wakeup_restore_alarm': 'Restore {day} {time}',
      'wakeup_notif_off': 'Notifications are off.',
      'wakeup_exact_off': 'Exact alarms are off.',
      'wakeup_exact_allow': 'Allow exact alarms',
      'wakeup_clock_failed': 'Could not open the clock',
      'wakeup_minutes_invalid': 'Bad minute count',
      'notif_allow': 'Allow',
      'notif_open_settings': 'Open settings',
      'autostart': 'Start on login',
      'autostart_failed': 'Could not set that',
      'autostart_store_managed': 'The Store build is started by Windows.',
      'autostart_open_settings': 'Open startup settings',
      'minimize_to_tray': 'Minimize to tray',
      'run_in_background': 'Run in background',
      'run_in_background_hint': 'The service checks data with the app closed.',
      'bg_overview_title': 'What the notification shows',
      'bg_overview_hint': 'Pick the status notification rows.',
      'bg_item_next_lesson': 'Next lesson',
      'bg_item_lunch': 'Lunch',
      'bg_item_lunch_orders': 'Orders',
      'bg_item_excuses': 'Excuses',
      'bg_item_wakeup': 'Alarm',
      'bg_preview': 'Preview',
      'bg_notif_title': 'Strakaláři running',
      'bg_notif_text': 'Checking every {n} min.',
      'theme_dark': 'Dark',
      'theme_light': 'Light',
      'language': 'Language',
      'density': 'Density',
      'density_compact': 'compact',
      'tutorials': 'Tours',
      'tutorials_hint': 'Short walkthroughs on first use.',
      'tutorials_toggle': 'Tours enabled',
      'tutorials_replay': 'Replay',
      'tutorials_replayed': 'Tours will show again.',
      'cache_ttl': 'Cache lifetime (h)',
      'timeout_page': 'Page timeout (s)',
      'log_file': 'Log file',
      'blacklist_file': 'Blacklist file',
      'update_channel': 'Update channel',
      'update_channel_stable': 'Stable',
      'update_channel_beta': 'Beta',
      'update_channel_hint': 'Beta also offers test builds.',
      'update_store_managed': 'Updates come from the store.',
      'latest_version': 'Latest version',
      'up_to_date': 'up to date',
      'config_problems': 'Config problems:',
      'config_ok': 'Config is fine.',
      'cache_info': 'Cache',
      'clear_cache': 'Clear cache',
      'cache_cleared': 'Cache cleared.',
      'gemini_key': 'Gemini key',
      'gemini_model': 'Model',
      'key_saved_hint': 'Saved (empty = unchanged)',
      'ai_key_steps': 'Free key at aistudio.google.com.',
      'gemini_key_hint': 'Sent nowhere except Gemini.',
      'ai_model_hint': 'E.g. gemini-3.8-flash.',
      'ai_auto_enable': 'Automatic recommendations',
      'ai_auto_hint': 'After every menu refresh.',
      'ai_prompt': 'Extra wishes',
      'ai_prompt_hint': 'e.g. meatless on Fridays',
      'ai_interval': 'How often (days)',
      'ai_interval_hint': '1–30 days.',
      'ai_last_run': 'Last run',
      'ai_never': 'never',
      'wiz_test_key': 'Test key',
      'tut_start': 'Show me',
      'tut_not_now': 'Not now',
      'tut_off_note': 'Tours can come back in Settings → Appearance.',
      'tut_turn_off': 'Turn tours off',
      'tut_skip_tour': 'Skip tour',
      'tut_next': 'Next',
      'tut_back': 'Back',
      'tut_done': 'Done',
      'tut_later': 'Later',
      'tut_skip_step': 'Skip step',
      'tut_intro_welcome_title': 'Welcome to Strakaláři!',
      'tut_intro_welcome_body': 'A quick tour of what matters.',
      'tut_intro_nav_title': 'Navigation',
      'tut_intro_nav_body': 'Switch screens here.',
      'tut_intro_refresh_title': 'Refresh',
      'tut_intro_refresh_body': 'Fetch fresh data here.',
      'tut_intro_status_title': 'Status',
      'tut_intro_status_body': 'See what the app is doing.',
      'tut_intro_done_title': 'That is all',
      'tut_intro_done_body': 'Tours also live in settings.',
      'tut_excuse_pick_title': 'A pending excuse',
      'tut_excuse_pick_body': 'Pick it here.',
      'tut_excuse_send_title': 'Send',
      'tut_excuse_send_body': 'This sends it.',
      'tut_excuse_send_try': 'Try it: send the excuse.',
      'tut_excuse_done_title': 'Done',
      'tut_excuse_done_body': 'That is how it works.',
      'tut_tt_weeks_title': 'Weeks',
      'tut_tt_weeks_body': 'Flip between weeks.',
      'tut_tt_colors_title': 'Colors',
      'tut_tt_colors_body': 'Colors mark changes and absences.',
      'tut_abs_stats_title': 'Summary',
      'tut_abs_stats_body': 'Absence overview lives here.',
      'tut_abs_subject_title': 'Subjects',
      'tut_abs_subject_body': 'Tap for a subject detail.',
      'tut_plan_strip_title': 'Year overview',
      'tut_plan_strip_body': 'The whole year at a glance.',
      'tut_plan_pick_title': 'Plan a day',
      'tut_plan_pick_body': 'Tap a day to take it off.',
      'tut_plan_pick_try': 'Try it: plan a day.',
      'tut_plan_budget_title': 'Budgets',
      'tut_plan_budget_body': 'Hours left per subject.',
      'tut_lunch_pick_title': 'Pick a lunch',
      'tut_lunch_pick_body': 'Tap a meal.',
      'tut_lunch_pick_try': 'Try it: pick a lunch.',
      'tut_lunch_send_title': 'Send the order',
      'tut_lunch_send_body': 'This sends everything at once.',
      'tut_lunch_send_try': 'Try it: send the orders.',
      'tut_lunch_tools_title': 'AI & filter',
      'tut_lunch_tools_body': 'Tune the meal picking here.',
      'tut_marks_stats_title': 'Averages',
      'tut_marks_stats_body': 'Grade overview lives here.',
      'tut_marks_subject_title': 'Subject',
      'tut_marks_subject_body': 'Tap for the detail.',
      'tut_marks_subject_try': 'Try it: open a subject.',
      'tut_marks_need_title': 'What you need',
      'tut_marks_need_body': 'Which grade you must get.',
      'tut_marks_predict_title': 'Predictor',
      'tut_marks_predict_body': 'Try what-if grades.',
      'tut_marks_predict_try': 'Try it: add a prediction.',
      'tut_marks_scale_title': 'Scale',
      'tut_marks_scale_body': 'Switch the scale here.',
      'tut_settings_intro_title': 'Settings',
      'tut_settings_intro_body': 'Everything important is here.',
      'tut_activity_intro_title': 'Activity',
      'tut_activity_intro_body': 'See what the app is doing.',
    },
  };
}

/// Test-visible snackbar record. Views call [appSnack]; tests read
/// [SnackLog.last] instead of pumping ScaffoldMessenger internals.
class SnackLog {
  static String? last;
  static final List<String> all = [];

  static void record(String text) {
    last = text;
    all.add(text);
  }

  static void clear() {
    last = null;
    all.clear();
  }
}

/// Shows a snackbar and records it for tests. Never throws.
void appSnack(BuildContext context, String text) {
  SnackLog.record(text);
  try {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  } catch (_) {}
}

/// Copies [text] to the clipboard. Returns true when dispatched.
Future<bool> copyAppText(String text) async {
  if (text.isEmpty) return false;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// Error popup with a copy-logs button. Port of overlays.show_error_dialog.
///
/// [userMessage] set → friendly fix-it text on screen, full bundle one
/// copy-tap away. Otherwise the summary + hint + traceback dump show.
class ErrorDialog extends StatefulWidget {
  final String title;
  final String summary;
  final String reportText;
  final String userMessage;
  final VoidCallback? onClose;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.summary,
    required this.reportText,
    this.userMessage = '',
    this.onClose,
  });

  @override
  State<ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<ErrorDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    final ok = await copyAppText(widget.reportText);
    if (!mounted) return;
    setState(() => _copied = ok);
    if (context.mounted) {
      appSnack(context,
          Str.t(ok ? 'error_copied' : 'error_copy_failed'));
    }
  }

  void _dismiss() {
    Navigator.of(context).maybePop();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.reportText.trim().isEmpty
        ? '(no details captured)'
        : widget.reportText.trim();
    final friendly = widget.userMessage.trim();
    final List<Widget> message;
    if (friendly.isNotEmpty) {
      message = [
        SelectableText(friendly),
        SelectableText(Str.t('error_not_yours'),
            style: Theme.of(context).textTheme.bodySmall),
      ];
    } else {
      message = [
        SelectableText(widget.summary),
        SelectableText(Str.t('error_hint'),
            style: Theme.of(context).textTheme.bodySmall),
        Container(
          height: 220,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(body,
                style: const TextStyle(
                    fontFamily: 'Consolas', fontSize: 12)),
          ),
        ),
      ];
    }
    return AlertDialog(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 8),
          Flexible(
              child: Text(widget.title.isEmpty
                  ? Str.t('error_title')
                  : widget.title)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < message.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              message[i],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _dismiss, child: Text(Str.t('error_close'))),
        TextButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.content_copy),
          label: Text(_copied
              ? Str.t('error_copied')
              : Str.t('error_copy_logs')),
        ),
      ],
    );
  }
}

/// Shows the error dialog. Never throws.
Future<void> showErrorDialog(
  BuildContext context, {
  required String title,
  required String summary,
  required String reportText,
  String userMessage = '',
  VoidCallback? onClose,
}) async {
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => ErrorDialog(
        title: title,
        summary: summary,
        reportText: reportText,
        userMessage: userMessage,
        onClose: onClose,
      ),
    );
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Tutorial tours (port of flet_ui/tutorial.py).
// ---------------------------------------------------------------------------

/// Where a step's bubble goes.
enum TourPlace { inline, center, left, topLeft, topRight, headerRight, bottomRight, bottom }

/// One step of a tour.
class TourStep {
  final String key;
  final String anchor;
  final TourPlace place;
  final String until;
  final IconData icon;
  final bool welcome;

  const TourStep(
    this.key, {
    this.anchor = '',
    this.place = TourPlace.inline,
    this.until = '',
    this.icon = Icons.lightbulb_outline,
    this.welcome = false,
  });
}

/// One guided tour.
class Tour {
  final String id;
  final String? route;
  final List<TourStep> steps;

  const Tour(this.id, this.route, this.steps);
}

/// All tours, mirroring TOURS in tutorial.py.
const Map<String, Tour> kTours = {
  'intro': Tour('intro', null, [
    TourStep('intro_welcome',
        place: TourPlace.center,
        icon: Icons.waving_hand_outlined,
        welcome: true),
    TourStep('intro_nav', place: TourPlace.left, icon: Icons.menu_outlined),
    TourStep('intro_refresh',
        anchor: 'refresh',
        place: TourPlace.topRight,
        icon: Icons.refresh),
    TourStep('intro_status',
        anchor: 'status',
        place: TourPlace.topLeft,
        icon: Icons.monitor_heart_outlined),
    TourStep('intro_done',
        place: TourPlace.bottomRight, icon: Icons.school_outlined),
  ]),
  'excuse': Tour('excuse', 'today', [
    TourStep('excuse_pick',
        anchor: 'excuse_card', icon: Icons.event_busy_outlined),
    TourStep('excuse_send',
        anchor: 'excuse_card',
        until: 'excuse_done',
        icon: Icons.send_outlined),
    TourStep('excuse_done',
        place: TourPlace.bottomRight, icon: Icons.task_alt),
  ]),
  'timetable': Tour('timetable', 'timetable', [
    TourStep('tt_weeks',
        anchor: 'tt_nav', icon: Icons.date_range_outlined),
    TourStep('tt_colors',
        anchor: 'tt_legend', icon: Icons.palette_outlined),
  ]),
  'absences': Tour('absences', 'absences', [
    TourStep('abs_stats',
        anchor: 'abs_stats', icon: Icons.pie_chart_outline),
    TourStep('abs_subject',
        anchor: 'abs_first', icon: Icons.percent),
  ]),
  'planner': Tour('planner', 'planner', [
    TourStep('plan_strip',
        anchor: 'plan_strip', icon: Icons.calendar_view_month_outlined),
    TourStep('plan_pick',
        anchor: 'plan_first',
        until: 'day_planned',
        icon: Icons.beach_access_outlined),
    TourStep('plan_budget',
        anchor: 'plan_budget', icon: Icons.stacked_bar_chart),
  ]),
  'lunches': Tour('lunches', 'lunches', [
    TourStep('lunch_pick',
        anchor: 'lunch_day',
        until: 'lunch_picked',
        icon: Icons.restaurant_outlined),
    TourStep('lunch_send',
        anchor: 'lunch_send',
        until: 'orders_sent',
        icon: Icons.send_outlined),
    TourStep('lunch_tools',
        anchor: 'lunch_tools',
        place: TourPlace.headerRight,
        icon: Icons.tune_outlined),
  ]),
  'marks': Tour('marks', 'marks', [
    TourStep('marks_stats',
        anchor: 'marks_stats', icon: Icons.grade_outlined),
    TourStep('marks_subject',
        anchor: 'marks_subject',
        until: 'marks_subject_opened',
        icon: Icons.touch_app_outlined),
    TourStep('marks_need',
        anchor: 'marks_need', icon: Icons.flag_outlined),
    TourStep('marks_predict',
        anchor: 'marks_predict',
        until: 'marks_predicted',
        icon: Icons.science_outlined),
    TourStep('marks_scale',
        anchor: 'marks_scale',
        place: TourPlace.headerRight,
        icon: Icons.percent),
  ]),
  'settings': Tour('settings', 'settings', [
    TourStep('settings_intro',
        place: TourPlace.bottomRight, icon: Icons.settings_outlined),
  ]),
  'activity': Tour('activity', 'activity', [
    TourStep('activity_intro',
        place: TourPlace.bottomRight, icon: Icons.history_outlined),
  ]),
};

const String kFirstTour = 'intro';

/// Progress tracker for the tours. Port of state_tutorial.TutorialMixin.
///
/// Backed by a plain config map (`tutorials_enabled`, `tutorials_done`)
/// plus an optional [persist] hook; UI-agnostic so tests run headless.
class TutorialController {
  final Map<String, dynamic> config;
  final bool Function(Map<String, dynamic> updates)? persist;

  /// Active `(tourId, stepIndex)` in memory, or null.
  List<dynamic>? active;

  TutorialController(this.config, {this.persist});

  bool enabled() {
    try {
      return (config['tutorials_enabled'] as bool?) ?? true;
    } catch (_) {
      return true;
    }
  }

  Set<String> done() {
    final out = <String>{};
    final stored = config['tutorials_done'];
    if (stored is List) {
      for (final t in stored) {
        final s = '$t'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  void _rememberDone(String tourId) {
    final stored = done()..add(tourId);
    final updates = {'tutorials_done': stored.toList()..sort()};
    try {
      if (persist != null) {
        persist!(updates);
      } else {
        config.addAll(updates);
      }
    } catch (_) {}
  }

  bool setEnabled(bool value) {
    if (!value) active = null;
    try {
      final updates = {'tutorials_enabled': value};
      if (persist != null) {
        return persist!(updates) != false;
      }
      config.addAll(updates);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool reset() {
    active = null;
    try {
      final updates = {
        'tutorials_done': <String>[],
        'tutorials_enabled': true
      };
      if (persist != null) {
        return persist!(updates) != false;
      }
      config.addAll(updates);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<dynamic>? current() {
    if (active == null) return null;
    final tour = kTours[active![0]];
    if (tour == null) {
      active = null;
      return null;
    }
    final index = active![1] as int;
    if (index < 0 || index >= tour.steps.length) {
      active = null;
      return null;
    }
    return [tour, index, tour.steps[index]];
  }

  /// Starts [tourId] if nothing runs and it was never done.
  bool offer(String tourId) {
    if (active != null) return active![0] == tourId;
    if (!enabled()) return false;
    if (done().contains(tourId) || !kTours.containsKey(tourId)) return false;
    if (tourId != kFirstTour && !done().contains(kFirstTour)) return false;
    active = [tourId, 0];
    return true;
  }

  void suspend() {
    active = null;
  }

  void _goto(int index) {
    final cur = current();
    if (cur == null) return;
    final Tour tour = cur[0];
    if (index >= tour.steps.length) {
      active = null;
      _rememberDone(tour.id);
      return;
    }
    active = [tour.id, index < 0 ? 0 : index];
  }

  void next() {
    final cur = current();
    if (cur != null) _goto((cur[1] as int) + 1);
  }

  void back() {
    final cur = current();
    if (cur != null && (cur[1] as int) > 0) {
      _goto((cur[1] as int) - 1);
    }
  }

  void skip() {
    final cur = current();
    if (cur == null) return;
    active = null;
    _rememberDone((cur[0] as Tour).id);
  }

  /// The user just did [name]: advance past the first waiting step.
  void event(String name) {
    List<dynamic>? cur;
    try {
      cur = current();
    } catch (_) {
      return;
    }
    if (cur == null) return;
    final Tour tour = cur[0];
    final int index = cur[1];
    for (var later = index; later < tour.steps.length; later++) {
      if (tour.steps[later].until == name) {
        _gotoQuiet(later + 1);
        return;
      }
    }
  }

  void _gotoQuiet(int index) {
    final cur = current();
    if (cur == null) return;
    final Tour tour = cur[0];
    if (index >= tour.steps.length) {
      active = null;
      _rememberDone(tour.id);
      return;
    }
    active = [tour.id, index];
  }
}

/// The callout bubble for one step.
class TutorialBubble extends StatelessWidget {
  final TutorialController controller;
  final Tour tour;
  final int index;
  final TourStep step;

  const TutorialBubble({
    super.key,
    required this.controller,
    required this.tour,
    required this.index,
    required this.step,
  });

  @override
  Widget build(BuildContext context) {
    final total = tour.steps.length;
    final last = index == total - 1;
    final List<Widget> body = [
      Row(
        children: [
          Icon(step.icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(Str.t('tut_${step.key}_title'),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          IconButton(
            tooltip: Str.t('tut_skip_tour'),
            icon: const Icon(Icons.close, size: 16),
            onPressed: controller.skip,
          ),
        ],
      ),
      Text(Str.t('tut_${step.key}_body')),
    ];
    if (step.until.isNotEmpty) {
      body.add(
        Text(Str.t('tut_${step.key}_try'),
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary)),
      );
    }
    if (step.welcome) {
      body.add(Row(
        children: [
          FilledButton(
              onPressed: controller.next,
              child: Text(Str.t('tut_start'))),
          const SizedBox(width: 8),
          TextButton(
              onPressed: controller.skip,
              child: Text(Str.t('tut_not_now'))),
        ],
      ));
      body.add(Row(
        children: [
          Expanded(child: Text(Str.t('tut_off_note'))),
          TextButton(
            onPressed: () => controller.setEnabled(false),
            child: Text(Str.t('tut_turn_off')),
          ),
        ],
      ));
    } else {
      final List<Widget> nav = [
        Row(
          children: [
            for (var i = 0; i < total; i++)
              Container(
                width: i == index ? 14 : 6,
                height: 6,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: i <= index
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
        const Spacer(),
      ];
      if (index > 0 && !tour.steps[index - 1].until.isNotEmpty) {
        nav.add(TextButton(
            onPressed: controller.back,
            child: Text(Str.t('tut_back'))));
      }
      if (step.until.isNotEmpty) {
        nav.add(TextButton(
          onPressed: controller.next,
          child: Text(Str.t(last ? 'tut_later' : 'tut_skip_step')),
        ));
      } else {
        nav.add(FilledButton(
          onPressed: controller.next,
          child: Text(Str.t(last ? 'tut_done' : 'tut_next')),
        ));
      }
      body.add(Row(children: nav));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < body.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              body[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Wraps [child] with an accent ring when the active step points at [key].
/// Returns [child] untouched otherwise. Only the first match highlights.
class TutorialAnchor extends StatelessWidget {
  final TutorialController controller;
  final String anchorKey;
  final Widget child;
  final bool narrow;

  const TutorialAnchor({
    super.key,
    required this.controller,
    required this.anchorKey,
    required this.child,
    this.narrow = false,
  });

  @override
  Widget build(BuildContext context) {
    final cur = controller.current();
    if (cur == null || (cur[2] as TourStep).anchor != anchorKey) {
      return child;
    }
    final ring = Container(
      decoration: BoxDecoration(
        border:
            Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(11),
      ),
      padding: const EdgeInsets.all(3),
      child: child,
    );
    final Tour tour = cur[0];
    final int index = cur[1];
    final TourStep step = cur[2];
    if (narrow || step.place == TourPlace.inline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ring,
          TutorialBubble(
              controller: controller,
              tour: tour,
              index: index,
              step: step),
        ],
      );
    }
    return ring;
  }
}
