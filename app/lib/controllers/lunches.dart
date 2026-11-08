// Lunch ordering: cutoff, staged picks, sending, AI picks and the blacklist.
//
// Port of strakalari/flet_ui/state_lunches.py (`LunchMixin`). Cutoff math
// delegates to core `lunch_cutoff`; staging/pending/blacklist logic is a
// line-by-line port. The Strava submits (`_work` threads, snackbars)
// run in phase 7 — the stubs below validate, stage and report exactly
// like the originals and hand payloads to the documented seams.
part of 'app_state.dart';

/// Lunch ordering logic. Port of `LunchMixin`.
extension LunchLogic on AppState {
  /// Resolved `HH:MM` cutoff (user override, then preset, else 12:00).
  String lunchCutoffTime() {
    try {
      return resolveLunchCutoff(config.data);
    } catch (_) {
      return '12:00';
    }
  }

  /// School free-day set used for business-day math.
  Set<DateTime> lunchFreeDays() {
    try {
      // Unclipped: deadlines after the absence closure (May, June)
      // must still skip the user's days off there.
      return effectiveCalendar(config.data, clip: false).dates;
    } catch (_) {
      return {};
    }
  }

  /// Deadline datetime for a lunch day, or null when unparseable.
  DateTime? lunchOrderDeadline(String day) {
    try {
      final parsed = parseCzDate(day);
      if (parsed == null) return null;
      return core.lunchOrderDeadline(
          parsed, lunchCutoffTime(), lunchFreeDays());
    } catch (_) {
      return null;
    }
  }

  /// True while the previous-business-day cutoff has not passed.
  /// Fail-closed: an unparseable day can never be staged as orderable.
  bool isLunchOrderOpen(String day, [DateTime? now]) {
    try {
      final parsed = parseCzDate(day);
      if (parsed == null) return false;
      return core.isLunchOrderOpen(parsed,
          now: now,
          cutoffTime: lunchCutoffTime(),
          freeDays: lunchFreeDays());
    } catch (_) {
      return false;
    }
  }

  bool Function(DateTime)? autoLunchIsOpen() =>
      orderWindowPredicate(config.data);

  /// Unsubmitted lunch changes (the badge number on Obědy).
  int get pendingLunchCount {
    try {
      return pendingOrders.where((day) => lunchIsChange(day)).length;
    } catch (_) {
      return 0;
    }
  }

  /// `mealId`, or '' for no lunch (nothing ordered, or the day's "no
  /// lunch" `&-1&` id: both mean no meal on the web).
  static String realMeal(Object? mealId) {
    final mid = '${mealId ?? ''}';
    return mid.contains('&-1&') ? '' : mid;
  }

  /// True when the local pick for [day] differs from what Strava
  /// reported at the last fetch. Port of `lunch_is_change()`.
  bool lunchIsChange(String day) {
    if (!orders.containsKey(day)) return false;
    return realMeal(orders[day]) != realMeal(webOrders[day]);
  }

  /// Sets the local pick for [day]; pending (to send) only while it
  /// differs from the web order. True when it is a change.
  /// Port of `_stage_pick()`.
  bool stagePick(String day, String mealId) {
    orders[day] = mealId;
    if (lunchIsChange(day)) {
      pendingOrders.add(day);
      return true;
    }
    pendingOrders.remove(day);
    return false;
  }

  /// Records a lunch choice locally (clears any planned skip). False —
  /// staging nothing — when the previous-business-day cutoff for [day]
  /// already passed. Port of `order_lunch()`.
  bool orderLunch(String day, String mealId) {
    if (!stravaEnabled()) return false;
    try {
      if (!isLunchOrderOpen(day)) {
        try {
          logLine(Strings.get('lunch_order_closed'));
        } catch (_) {
          // Logging never blocks staging.
        }
        return false;
      }
    } catch (_) {
      // Fail-closed: an uncheckable cutoff must not stage a pick
      // Strava would reject.
      return false;
    }
    stagePick(day, mealId);
    cancelledLunches.remove(day);
    tutorialEvent('lunch_picked');
    _emit();
    return true;
  }

  /// Drops the local lunch choice for a day. Port of
  /// `cancel_lunch_order()`.
  void cancelLunchOrder(String day) {
    orders.remove(day);
    pendingOrders.remove(day);
    _emit();
  }

  /// Builds the transmittable order payload: only user-changed days,
  /// plus planner-cancelled days (deorder derived from the menu), stays
  /// within the order window. Pure part of `submit_orders()` — the
  /// thread + Strava session run in phase 7.
  Map<String, String> lunchSubmitPayload() {
    final pending = Set<String>.of(pendingOrders);
    final payload = {
      for (final e in orders.entries)
        if (e.value.isNotEmpty &&
            pending.contains(e.key) &&
            lunchIsChange(e.key))
          e.key: e.value,
    };
    final menu = food();
    for (final day in cancelledLunches) {
      if (payload.containsKey(day)) continue;
      final web = webOrders[day] ?? '';
      if (web.isEmpty || web.contains('&-1&')) continue;
      final meals = menu[day] ?? {};
      String? deorder;
      for (final mid in meals.keys) {
        if (mid.contains('&-1&')) {
          deorder = mid;
          break;
        }
      }
      if (deorder != null) payload[day] = deorder;
    }
    // Days past the previous-business-day cutoff: Strava would reject
    // them. Picks stay staged; only the payload is filtered.
    payload.removeWhere((day, _) => !isLunchOrderOpen(day));
    return payload;
  }

  /// Sends the local lunch choices (and planned-skip deorders) to
  /// Strava. Returns false when nothing is pending or a submit already
  /// runs. Phase 7 performs the network submit; until then the payload
  /// is validated and the in-flight flag set exactly like the original.
  /// Port of `submit_orders()` (thread/snackbar bits dropped).
  bool submitOrders() {
    if (!stravaEnabled()) return false;
    if (refreshRunning || !claimFlight('order_running')) return false;
    var spawned = false;
    try {
      final payload = lunchSubmitPayload();
      if (payload.isNotEmpty && demoMode && !_hasAnyCredentials()) {
        logLine(Strings.get('need_credentials'));
        return false;
      }
      if (payload.isEmpty) return false;
      orderRunning = true;
      currentStep = Strings.get('orders_sending');
      logLine('${Strings.get('orders_sending')} (${payload.length})');
      tutorialEvent('orders_sent');
      _emit();
      // Flet: spawned `_work` (session lock, one Strava session,
      // placed-days bookkeeping, low-balance banner, snackbar). Phase 7
      // runs it and clears `orderRunning` + the flight flag.
      spawned = true;
      return true;
    } finally {
      if (!spawned) {
        releaseFlight('order_running');
        orderRunning = false;
      }
    }
  }

  /// Validates an AI recommendation run. Phase 7 performs the Gemini
  /// call + staging; until then the in-flight flag is claimed exactly
  /// like the original. Port of `start_ai_recommend()` (head).
  bool startAiRecommend() {
    if (!claimFlight('ai_running')) return false;
    logLine(Strings.get('ai_started'));
    _emit();
    // Flet: spawned `_work` (Gemini call, same-menu/cutoff/skip guards,
    // batched staging, snackbar). Phase 7 runs it and clears
    // `aiRunning` + the flight flag.
    aiRunning = true;
    return true;
  }

  /// Hides banned meals and stages first-allowed picks. Port of
  /// `apply_food_filter()`.
  void applyFoodFilter(String prefs) {
    final blacklist = blacklistWords();
    List<String> prefWords = [];
    try {
      prefWords = prefsBanKeywords(prefs);
    } catch (_) {
      prefWords = [];
    }
    final seen = {for (final w in blacklist) w.toLowerCase()};
    final combined = List<String>.of(blacklist);
    for (final word in prefWords) {
      if (!seen.contains(word.toLowerCase())) {
        seen.add(word.toLowerCase());
        combined.add(word);
      }
    }
    final menu = food();
    final hidden = <String>{};
    final reasons = <String, String>{};
    for (final meals in menu.values) {
      for (final e in meals.entries) {
        if (e.key.contains('&-1&')) continue;
        final (banned, keyword) = isFoodBanned(e.value, combined);
        if (banned) {
          hidden.add(e.key);
          reasons[e.key] = '${Strings.get('skipped_reason')}: $keyword';
        }
      }
    }
    lunchHidden = hidden;
    lunchReasons = reasons;
    lunchPrefs = prefs;
    Map<String, String> picks = {};
    try {
      picks = filterPicks(
        menu.map((k, v) => MapEntry(k, v)),
        blacklist: combined,
        cancelledDays: cancelledLunches,
        isOpen: (day) {
          try {
            return isLunchOrderOpen(fmtDay(day));
          } catch (_) {
            return false;
          }
        },
      );
    } catch (_) {
      picks = {};
    }
    for (final e in picks.entries) {
      final current = orders[e.key];
      if (current == null || hidden.contains(current)) {
        stagePick(e.key, e.value);
      }
    }
    _emit();
  }

  String _blacklistPath() {
    var path = '${get('strava_blacklist', './strava_blacklist.json')}';
    try {
      path = resolvePath(path);
    } catch (_) {
      // Seed value stands.
    }
    return path;
  }

  /// Current blacklist words (display, fail-open to `[]`).
  List<String> blacklistWords() {
    final path = _blacklistPath();
    try {
      final file = File(path);
      if (!file.existsSync()) return [];
      final data = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (data is! List) return [];
      final words = {
        for (final w in data)
          if ('$w'.trim().isNotEmpty &&
              !normalizeWord(w).startsWith('your_blacklist'))
            '$w'.trim(),
      }.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return words;
    } catch (_) {
      return [];
    }
  }

  /// Current words for an add/remove, or null when editing is unsafe
  /// (unreadable/corrupt file: saving over it would silently replace
  /// every keyword). Port of `_blacklist_words_for_edit()`.
  List<String>? blacklistWordsForEdit() {
    final path = _blacklistPath();
    final file = File(path);
    if (!file.existsSync()) return [];
    try {
      final data = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (data is! List) throw const FormatException('not a JSON list');
      final words = {
        for (final w in data)
          if ('$w'.trim().isNotEmpty &&
              !normalizeWord(w).startsWith('your_blacklist'))
            '$w'.trim(),
      }.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return words;
    } catch (_) {
      blacklistEditError =
          Strings.format('blacklist_unreadable', {'path': path});
      logLine('$blacklistEditError (FormatException)');
      return null;
    }
  }

  bool addBlacklistWord(String word) {
    blacklistEditError = '';
    word = word.trim();
    if (word.length < 3) return false;
    final words = blacklistWordsForEdit();
    if (words == null) return false;
    if (words.any((w) => w.toLowerCase() == word.toLowerCase())) {
      return false;
    }
    words.add(word);
    try {
      writeBlacklist(words);
    } catch (_) {
      return false;
    }
    applyFoodFilter(lunchPrefs);
    return true;
  }

  bool removeBlacklistWord(String word) {
    blacklistEditError = '';
    final current = blacklistWordsForEdit();
    if (current == null) return false;
    final words = [
      for (final w in current)
        if (w.toLowerCase() != word.toLowerCase()) w,
    ];
    try {
      writeBlacklist(words);
    } catch (_) {
      return false;
    }
    applyFoodFilter(lunchPrefs);
    return true;
  }

  void writeBlacklist(List<String> words) {
    final unique = words.toSet().toList()..sort();
    atomicWriteJson(_blacklistPath(), unique);
  }
}

/// Riverpod facade for the lunches screen (phase 6).
class LunchesController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final lunchesControllerProvider =
    NotifierProvider<LunchesController, AppState>(LunchesController.new);
