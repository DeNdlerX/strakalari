// Live wiring of the Lunches screen to the shared AppState.
//
// Port of the glue in strakalari/flet_ui/views/lunches.py (`build`):
// reads menu, orders, webOrders, pendingOrders, cancelledLunches,
// blacklist and AI state from `AppState`, and delegates user actions
// (`orderLunch`, `cancelLunchOrder`, `submitOrders`, `startAiRecommend`,
// `applyFoodFilter`, blacklist edits) back to it.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import 'lunches_controller.dart';
import 'lunches_view.dart';

/// Builds a snapshot [LunchController] from the shared [AppState].
LunchController lunchControllerFor(AppState s) {
  final cfg = Map<String, dynamic>.of(s.config.data);
  if (s.data['strava_status'] != null) {
    cfg['strava_status'] = s.data['strava_status'];
  }
  final c = LunchController(
    cfg,
    isOrderOpen: s.isLunchOrderOpen,
    readBlacklist: s.blacklistWords,
    onTutorialEvent: s.tutorialEvent,
    onLog: s.logLine,
  );
  c.orderDeadline = s.lunchOrderDeadline;
  c.food = {
    for (final e in s.food().entries) e.key: Map<String, String>.of(e.value),
  };
  c.soups = s.soups();
  c.avoidedAllergens = core.avoidedAllergens(s.config.data);
  c.webOrders = Map<String, String>.of(s.webOrders);
  c.orders = Map<String, String>.of(s.orders);
  c.pendingOrders = Set<String>.of(s.pendingOrders);
  c.cancelledLunches = Set<String>.of(s.cancelledLunches);
  final cal = core.effectiveCalendar(s.config.data, clip: false);
  c.freeDayLabels = {
    for (final d in cal.dates) fmtDay(d): (cal.labels[d] ?? '').trim(),
  };
  c.lunchHidden = Set<String>.of(s.lunchHidden);
  c.lunchReasons = Map<String, String>.of(s.lunchReasons);
  c.lunchPrefs = s.lunchPrefs;
  c.aiRunning = s.aiRunning;
  c.stravaOn = s.stravaEnabled();
  c.stravaConfigured = core.hasValidCredentials(s.config.data).$2;
  c.demoMode = s.demoMode;
  c.showPastLunches = s.showPastLunches;
  c.lunchToolsOpen = s.lunchToolsOpen;
  c.sidebarOpen = s.lunchesSidebarOpen;
  final warn = s.lowBalanceWarning();
  if (warn != null && warn['days'] is List) {
    c.lowBalance = {
      'days': [for (final d in (warn['days'] as List)) '$d'],
    };
  }
  c.blacklistEditError = s.blacklistEditError;
  c.orderLunchHook = s.orderLunch;
  c.cancelLunchOrderHook = s.cancelLunchOrder;
  c.applyFoodFilterHook = s.applyFoodFilter;
  c.addBlacklistWordHook = (w) {
    final ok = s.addBlacklistWord(w);
    c.blacklistEditError = s.blacklistEditError;
    return ok;
  };
  c.removeBlacklistWordHook = (w) {
    final ok = s.removeBlacklistWord(w);
    c.blacklistEditError = s.blacklistEditError;
    return ok;
  };
  c.setAvoidedAllergensHook = s.setAvoidedAllergens;
  c.setShowPastLunchesHook = s.setShowPastLunches;
  c.setLunchToolsHook = s.setLunchTools;
  c.setSidebarHook = s.setLunchesSidebar;
  c.setLunchPrefsHook = (v) => s.lunchPrefs = v;
  return c;
}

/// The Lunches route: rebuilds whenever the shared state emits.
class LiveLunchesView extends ConsumerWidget {
  final bool narrow;

  const LiveLunchesView({super.key, required this.narrow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    s.tutorialOffer('lunches');
    return LunchesView(
      controller: lunchControllerFor(s),
      narrow: narrow,
      updatedLabel: s.updatedLabelFor('strava'),
      onOpenSettings: () => s.go('settings'),
      onRecommend: () async {
        if (!s.startAiRecommend()) {
          s.lastSnackMessage = Strings.get('ai_already_running');
        }
      },
      onSubmit: (_) async {
        if (s.submitOrders()) return true;
        // Nothing pending is not a failure.
        return s.lunchSubmitPayload().isEmpty ? null : false;
      },
    );
  }
}
