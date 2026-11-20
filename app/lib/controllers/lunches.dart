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
    if (isLunchOrderOpenOverride != null) {
      return isLunchOrderOpenOverride!(day, now);
    }
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
  /// within the order window. Pure part of `submit_orders()`.
  Map<String, String> lunchSubmitPayload() {
    final (_, payload) = _buildSubmitPayload();
    return payload;
  }

  (List<String>, Map<String, String>) _buildSubmitPayload() {
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
    final closed = [
      for (final day in payload.keys)
        if (!isLunchOrderOpen(day)) day,
    ];
    for (final day in closed) {
      payload.remove(day);
    }
    return (closed, payload);
  }

  /// Sends the local lunch choices (and planned-skip deorders) to
  /// Strava. Runs in the background; returns false when nothing is
  /// pending or a submit is already running. Port of `submit_orders()`.
  bool submitOrders() {
    if (!stravaEnabled()) return false;
    if (refreshRunning || !claimFlight('order_running')) return false;
    // Any exit below that does NOT hand the payload to the worker must
    // release the latch — otherwise Odeslat stays dead until restart.
    var spawned = false;
    try {
      final (closed, payload) = _buildSubmitPayload();
      if (closed.isNotEmpty) {
        logLine('${Strings.get('lunch_order_closed')} (${closed.length})');
        lastSnackMessage = Strings.get('lunch_order_closed');
      }
      if (payload.isEmpty) return false;
      if (demoMode && !_hasAnyCredentials()) {
        logLine(Strings.get('need_credentials'));
        lastSnackMessage = Strings.get('need_credentials');
        return false;
      }
      orderRunning = true;
      currentStep = Strings.get('orders_sending');
      logLine('${Strings.get('orders_sending')} (${payload.length})');
      tutorialEvent('orders_sent');
      _emit();

      spawn(
        () => _ordersWork(Map<String, String>.of(payload)),
        'strakalari-orders',
      );
      spawned = true;
      return true;
    } finally {
      if (!spawned) {
        releaseFlight('order_running');
        orderRunning = false;
      }
    }
  }

  Future<void> _ordersWork(Map<String, String> payload) async {
    var ok = false;
    var dry = false;
    var placed = <String, String>{};
    var busy = false;
    var unfunded = <String>[];
    try {
      // The tray (another process) may be mid-refresh: never order in
      // parallel with it.
      await withSessionLockAsync((held) async {
        if (!held) {
          busy = true;
          workerLog(Strings.get('session_busy'));
          return;
        }
        final app = createApp(onLog: coreLog);
        try {
          app.cancelRequested = false;
          dry = app.stravaOrderMode == 'dry_run';
          ok = await app.stravaOrderSelected(Map<String, String>.of(payload));
          if (!dry) {
            // Days that really went through, even when another day failed.
            final done = Set<String>.of(app.lastOrderedDays);
            placed = {
              for (final e in payload.entries)
                if (done.contains(e.key)) e.key: e.value,
            };
            if (app.lastOrderLowBalance) {
              unfunded = List<String>.of(app.lastUnfundedDays);
            }
          }
        } finally {
          try {
            app.close();
          } catch (exc) {
            // ignore: avoid_print
            print('Warning: session close failed: $exc');
          }
        }
      });
      if (placed.isNotEmpty) {
        recordWebOrders(placed);
      }
    } catch (exc) {
      final line =
          '${Strings.get('orders_failed')}: ${exc.runtimeType}: $exc'
              .split('\n')
              .first;
      workerLog(line.length > 200 ? line.substring(0, 200) : line);
      reportError('orders', exc, '', '', {'days': payload.length});
    } finally {
      orderRunning = false;
      releaseFlight('order_running');
    }
    var lowBalanceMsg = '';
    if (unfunded.isNotEmpty) {
      lowBalanceMsg =
          core.t('strava_low_balance_manual', args: {'n': unfunded.length});
      recordLowBalance(unfunded);
      setLowBalanceMemory(unfunded);
    } else if (ok && !dry) {
      recordLowBalance(null);
      setLowBalanceMemory(null);
    }
    if (ok && dry) {
      // Dry run simulates success without ordering — web truth untouched.
      workerLog(Strings.get('orders_dry_run'));
    } else if (ok) {
      workerLog(Strings.get('orders_sent'));
    } else if (lowBalanceMsg.isNotEmpty) {
      // The user's to fix (top up), not a bug: the snackbar says what
      // to do, no failure toast on top of it.
      workerLog(lowBalanceMsg);
    } else if (!busy) {
      // Fail loudly: the reason is in the log lines above.
      workerLog(Strings.get('orders_failed'));
      notifyEvent('automation_failed', Strings.get('orders_failed'));
    }
    if (busy) {
      lastSnackMessage = Strings.get('session_busy');
    } else if (ok) {
      lastSnackMessage =
          dry ? Strings.get('orders_dry_run') : Strings.get('orders_sent');
    } else if (lowBalanceMsg.isNotEmpty) {
      lastSnackMessage = lowBalanceMsg;
    } else {
      lastSnackMessage = Strings.get('orders_failed');
    }
    _emit();
  }

  /// Mirrors the cached low-balance warning into [data] (banner).
  /// Port of `_set_low_balance_memory()`.
  void setLowBalanceMemory(List<String>? days) {
    try {
      final copy = Map<String, Object?>.of(data);
      if (days == null) {
        copy['strava_low_balance'] = null;
      } else {
        final now = clock.now();
        String two(int n) => n.toString().padLeft(2, '0');
        final stamp = '${now.year.toString().padLeft(4, '0')}-'
            '${two(now.month)}-${two(now.day)}T'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
        final unique = {for (final d in days) d}.toList()..sort();
        copy['strava_low_balance'] = {'at': stamp, 'days': unique};
      }
      data = copy;
    } catch (_) {
      // Banner update is best-effort.
    }
  }

  /// Marks successfully placed picks as web truth (memory + cache).
  ///
  /// Merges into the cached `strava_ordered` map — replacing it with
  /// just this batch would drop every other ordered day.
  /// Port of `_record_web_orders()`.
  void recordWebOrders(Map<String, String> placed) {
    final canonPlaced = {
      for (final e in placed.entries) canonicalDayKey(e.key): e.value,
    };
    final manualRealDays = <String>[
      for (final e in canonPlaced.entries)
        if (e.value.isNotEmpty && !e.value.contains('&-1&')) e.key,
    ];
    for (final e in canonPlaced.entries) {
      webOrders[e.key] = e.value;
    }
    cancelledLunches.removeAll(manualRealDays);
    pendingOrders.removeAll(canonPlaced.keys);
    try {
      final currentCache = loadDataCache();
      final cached = currentCache['strava_ordered'];
      final merged = <String, Object?>{};
      if (cached is Map) {
        for (final e in cached.entries) {
          if (!canonPlaced.containsKey(canonicalDayKey(e.key))) {
            merged['${e.key}'] = e.value;
          }
        }
      }
      merged.addAll(canonPlaced);
      final updates = <String, Object?>{'strava_ordered': merged};
      if (manualRealDays.isNotEmpty) {
        final existing = currentCache[cancelHandledKey];
        final prev = existing is List
            ? [for (final d in existing) '$d']
            : const <String>[];
        updates[cancelHandledKey] =
            updateCancelHandledDays(prev, manualRealDays);
      }
      saveDataCache(updates);
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: could not cache placed orders: $exc');
    }
  }

  /// Runs the AI lunch recommendation in the background.
  ///
  /// Returns false when a run is already in flight. Port of
  /// `start_ai_recommend()`.
  bool startAiRecommend() {
    if (aiRunning || !claimFlight('ai_running')) return false;
    aiRunning = true;
    logLine(Strings.get('ai_started'));
    _emit();

    spawn(_aiRecommendWork, 'strakalari-recommend');
    return true;
  }

  Future<void> _aiRecommendWork() async {
    var msg = Strings.get('no_changes');
    try {
      var rawKey = '${get('gemini_api_key', '') ?? ''}';
      if (get('gemini_api_key_encrypted') == true ||
          '${get('gemini_api_key_encrypted')}' == 'true') {
        rawKey = decryptStrict(rawKey) ?? '';
      }
      final menu = food();
      final model =
          '${get('gemini_model', 'gemini-3.8-flash') ?? 'gemini-3.8-flash'}';
      final (_, recOrders) = await recommendLunchesFn(
        menu,
        lunchPrefs,
        rawKey,
        model: model,
        language: getLanguage(),
      );
      var staged = 0;
      var skipped = 0;
      var closed = 0;
      final blockedDays =
          cancelledLunches.union(autoCancelFreeLunchDays(config.data));
      for (final e in recOrders.entries) {
        final day = e.key;
        final mid = e.value;
        // Only a meal from that same day's menu is orderable.
        if (!(menu[day]?.containsKey(mid) ?? false)) continue;
        if (blockedDays.contains(canonicalDayKey(day))) {
          // A planned skip or free day owns this day: recommending onto it
          // would stage (and Send) a lunch on a non-school day.
          skipped++;
          continue;
        }
        bool open;
        try {
          open = isLunchOrderOpen(day);
        } catch (_) {
          open = false;
        }
        if (!open) {
          closed++;
          continue;
        }
        cancelledLunches.remove(day);
        if (stagePick(day, mid)) {
          staged++;
        }
      }
      if (staged > 0) {
        msg = '${Strings.get('to_send')} ($staged)';
        if (skipped > 0) {
          msg += ' · ${Strings.get('skipped_reason')}: $skipped';
        }
        if (closed > 0) {
          msg += ' · ${Strings.get('lunch_closed_count')}: $closed';
        }
      } else if (closed > 0) {
        msg = Strings.get('lunch_order_closed');
      } else if (skipped > 0) {
        msg = Strings.get('no_lunch');
      } else {
        msg = Strings.get('no_changes');
      }
      logLine(msg);
    } catch (exc) {
      msg = '$exc';
      final line = '${Strings.get('ai_failed')}: $msg'.split('\n').first;
      logLine(line.length > 200 ? line.substring(0, 200) : line);
    } finally {
      aiRunning = false;
      releaseFlight('ai_running');
    }
    lastSnackMessage = msg;
    _emit();
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
        cancelledDays:
            cancelledLunches.union(autoCancelFreeLunchDays(config.data)),
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
    if (blacklistPathOverride != null) return blacklistPathOverride!();
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
