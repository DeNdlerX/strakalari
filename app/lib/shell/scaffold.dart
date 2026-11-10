// Adaptive app shell: rail ↔ bottom bar + More, topbar, error popup.
//
// Port of the `Shell` in strakalari/flet_ui/app.py. Layout is decided
// by size, never by platform, so a small desktop window gets the phone
// layout too:
// - wide (desktop/tablets): full rail, 8 items side by side panels;
// - bar (phone portrait): bottom bar, 5 tabs;
// - side (phone landscape): the same 5 tabs in a slim side rail, so the
//   content keeps the little height there is.
//
// Breakpoints: narrower than 720 px, or lower than 520 px, is narrow
// (ports of `NARROW_MAX_WIDTH`, `NARROW_MAX_HEIGHT`, `is_narrow()` and
// `layout_for()`). Pure size predicates live here as top-level
// functions so widget tests need no [BuildContext].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../controllers/app_state.dart';
import '../l10n/strings.dart';
import '../widgets/error_boundary.dart';
import '../widgets/error_dialog.dart';
import '../widgets/overlays.dart' show appSnack, tutorialLayer, TutorialAnchor;
import 'router.dart';
import 'theme.dart';

/// Narrower than this, the side rail and side-by-side panels don't fit
/// (phones in portrait). Port of `NARROW_MAX_WIDTH`.
const double narrowMaxWidth = 720;

/// Lower than this, the eight rail items don't fit (phones in
/// landscape). Port of `NARROW_MAX_HEIGHT`.
const double narrowMaxHeight = 520;

/// Adaptive layouts. Port of `layout_for()`.
enum ShellLayout { wide, bar, side }

/// True when the window is phone-sized. Port of `is_narrow()`.
bool isNarrowSize(double width, double height) =>
    (width > 0 && width < narrowMaxWidth) ||
    (height > 0 && height < narrowMaxHeight);

/// `wide` (desktop/tablets), `bar` (phone portrait) or `side` (phone
/// landscape: width exceeds height). Port of `layout_for()`.
ShellLayout layoutForSize(double width, double height) {
  if (!isNarrowSize(width, height)) return ShellLayout.wide;
  return (width > height && height > 0) ? ShellLayout.side : ShellLayout.bar;
}

const Map<String, IconData> _railIcons = {
  'today': Icons.home_outlined,
  'timetable': Icons.calendar_month_outlined,
  'absences': Icons.event_busy_outlined,
  'marks': Icons.grade_outlined,
  'planner': Icons.event_note_outlined,
  'lunches': Icons.restaurant_outlined,
  'activity': Icons.history_outlined,
  'settings': Icons.settings_outlined,
  'more': Icons.menu,
};

String _titleFor(String route) {
  switch (route) {
    case 'today':
      return Strings.get('nav_today');
    case 'timetable':
      return Strings.get('nav_timetable');
    case 'absences':
      return Strings.get('nav_absences');
    case 'marks':
      return Strings.get('nav_marks');
    case 'planner':
      return Strings.get('nav_planner');
    case 'lunches':
      return Strings.get('nav_lunches');
    case 'activity':
      return Strings.get('nav_activity');
    case 'settings':
      return Strings.get('nav_settings');
    case 'more':
      return Strings.get('nav_more');
    default:
      return Strings.get('app_title');
  }
}

/// The persistent scaffold every route renders inside.
class AppScaffold extends ConsumerWidget {
  final String location;
  final Widget child;
  const AppScaffold({super.key, required this.location, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final controller = ref.read(appStateProvider.notifier);

    // The settings screen owns the language; everything else follows.
    final lang = '${appState.get('language', 'cs')}';
    Strings.lang = (lang == 'en') ? 'en' : 'cs';
    final tok = tokensFor('${appState.get('theme', 'dark')}');

    var route = routeForLocation(location);
    final size = MediaQuery.sizeOf(context);
    final layout = layoutForSize(size.width, size.height);
    final narrow = layout != ShellLayout.wide;
    appState.narrow = narrow;
    appState.navSide = layout == ShellLayout.side;

    final pending = appState.pendingRoute;
    if (pending != null &&
        (shellRoutes.contains(pending) ||
            pending == 'more' ||
            pending == 'wizard')) {
      appState.pendingRoute = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go(routeLocation(pending));
      });
    }

    // First-run wizard owns the screen until finished or dismissed
    // (gates automation, like `setup_pending` in app.py).
    if (appState.setupPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/wizard');
      });
      return Scaffold(
        backgroundColor: tok.bg,
        body: const SizedBox.shrink(),
      );
    }

    if (appState.lastSnackMessage.isNotEmpty) {
      final msg = appState.lastSnackMessage;
      appState.lastSnackMessage = '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(msg)));
      });
    }

    if (route == 'more' && !narrow) {
      route = 'today';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/today');
      });
    }

    // Tutorials: suspend a tour of another screen, offer the intro.
    appState.tutorialBegin(route);

    final lunchCount = appState.pendingLunchCount;
    final lunchLabel = Strings.get('nav_lunches') +
        (lunchCount > 0 ? ' ($lunchCount)' : '');

    if (appState.errorDialogPending) {
      final err = appState.lastError;
      appState.acknowledgeError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final summary = err == null ? '' : '${err['summary'] ?? ''}';
        final userMessage =
            err == null ? '' : '${err['user_message'] ?? ''}';
        showErrorDialog(
          context,
          tok: tok,
          title: Strings.get('error_title'),
          summary: summary,
          reportText: appState.errorReportText(),
          userMessage: userMessage,
          onClose: () => controller.emit(),
        );
      });
    }

    final topBar = _buildTopBar(
      context: context,
      ref: ref,
      appState: appState,
      tok: tok,
      narrow: narrow,
    );

    final paddedContent = Padding(
      padding: narrow
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : EdgeInsets.all(tok.pad + 8),
      child: ViewErrorBoundary(
        route: route,
        child: child,
      ),
    );

    final bubble = tutorialLayer(appState, context, tok, narrow);

    final contentArea = Stack(
      fit: StackFit.expand,
      children: [
        paddedContent,
        ?bubble,
      ],
    );

    final right = Column(
      children: [
        topBar,
        Expanded(child: contentArea),
      ],
    );

    switch (layout) {
      case ShellLayout.bar:
        final tabs = narrowTabs;
        var index = tabs.indexOf(route);
        if (index < 0) {
          index = tabs.indexOf('more');
          if (moreRoutes.contains(route)) {
            // Bar keeps More selected while a More screen is open.
          } else {
            index = 0;
          }
        }
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: right,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) =>
                context.go(routeLocation(tabs[i])),
            destinations: [
              for (final tab in tabs)
                NavigationDestination(
                  icon: tab == 'lunches' && lunchCount > 0
                      ? Badge(
                          label: Text('$lunchCount'),
                          child: Icon(_railIcons[tab]!),
                        )
                      : Icon(_railIcons[tab]!),
                  label: tab == 'lunches'
                      ? Strings.get('nav_lunches')
                      : _titleFor(tab),
                ),
            ],
          ),
        );
      case ShellLayout.side:
        final tabs = narrowTabs;
        var sideIndex = tabs.indexOf(route);
        if (sideIndex < 0) sideIndex = tabs.indexOf('more');
        return Scaffold(
          body: Row(
            children: [
              Container(
                color: tok.surface,
                child: SafeArea(
                  right: false,
                  bottom: false,
                  child: NavigationRail(
                    backgroundColor: tok.surface,
                    selectedIndex: sideIndex,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: 0.0,
                    onDestinationSelected: (i) =>
                        context.go(routeLocation(tabs[i])),
                    destinations: [
                      for (final tab in tabs)
                        NavigationRailDestination(
                          icon: tab == 'lunches' && lunchCount > 0
                              ? Badge(
                                  label: Text('$lunchCount'),
                                  child: Icon(_railIcons[tab]!),
                                )
                              : Icon(_railIcons[tab]!),
                          label: Text(tab == 'lunches'
                              ? Strings.get('nav_lunches')
                              : _titleFor(tab)),
                        ),
                    ],
                  ),
                ),
              ),
              VerticalDivider(width: 1, thickness: 1, color: tok.border),
              Expanded(
                child: SafeArea(
                  left: false,
                  bottom: false,
                  child: right,
                ),
              ),
            ],
          ),
        );
      case ShellLayout.wide:
        var railIndex = shellRoutes.indexOf(route);
        if (railIndex < 0) railIndex = 0;
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                backgroundColor: tok.surface,
                minWidth: 90,
                selectedIndex: railIndex,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) =>
                    context.go(routeLocation(shellRoutes[i])),
                destinations: [
                  for (final name in shellRoutes)
                    NavigationRailDestination(
                      icon: Icon(_railIcons[name]!),
                      label: Text(
                          name == 'lunches' ? lunchLabel : _titleFor(name)),
                    ),
                ],
              ),
              VerticalDivider(width: 1, thickness: 1, color: tok.border),
              Expanded(child: right),
            ],
          ),
        );
    }
  }

  static String _statusText(AppState state) {
    if (state.refreshRunning) {
      return state.currentStep.isNotEmpty
          ? state.currentStep
          : Strings.get('refreshing');
    }
    final sending = state.sendingLabel;
    if (sending.isNotEmpty) {
      return state.currentStep.isNotEmpty ? state.currentStep : sending;
    }
    if (state.status == 'error' && state.runs.isNotEmpty) {
      return "${Strings.get('status_error')}: ${state.runs.last['detail'] ?? ''}";
    }
    if (state.runs.isNotEmpty && state.runs.last['ok'] == true) {
      return "${Strings.get('status_ok')} · ${Strings.get('last_run')}: ${state.lastRunLabel}";
    }
    return Strings.get('status_idle');
  }

  static Widget _buildTopBar({
    required BuildContext context,
    required WidgetRef ref,
    required AppState appState,
    required Tokens tok,
    required bool narrow,
  }) {
    final statusKind = appState.statusKind();
    final Color dotColor = switch (statusKind) {
      'working' => tok.yellow,
      'ok' => tok.green,
      'error' => tok.red,
      _ => tok.faint,
    };

    final statusText = _statusText(appState);
    final tooltipText =
        '$statusText\n${Strings.get('last_updated')}: ${appState.updatedLabel}   ·   ${Strings.get('next_run')}: ${appState.nextRunLabel}';

    void refreshClicked() {
      if (appState.refreshRunning) {
        appState.cancelRefresh();
        return;
      }
      if (!ref.read(activityControllerProvider).startRefresh('all')) {
        appSnack(context, Strings.get('already_running'));
        return;
      }
      appSnack(context, Strings.get('refresh_started'));
    }

    final statusPill = TutorialAnchor(
      anchorKey: 'status',
      child: Tooltip(
        message: tooltipText,
        child: InkWell(
          key: const ValueKey('topbar_status_pill'),
          onTap: () => context.go(routeLocation('activity')),
          borderRadius: BorderRadius.circular(tok.radiusSm),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Container(
                  key: const ValueKey('topbar_status_dot'),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: tok.muted,
                      fontSize: tok.fsSmall,
                    ),
                    maxLines: narrow ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Widget? updateControl;
    final banner = appState.updateBanner;
    if (banner != null) {
      final latest = '${banner['version'] ?? '?'}';
      final updateText = Strings.format('update_available', {'v': latest});
      if (narrow) {
        updateControl = IconButton(
          key: const ValueKey('topbar_update_btn'),
          icon: Icon(Icons.new_releases_outlined, color: tok.accent),
          tooltip: updateText,
          onPressed: () => context.go(routeLocation('activity')),
        );
      } else {
        updateControl = TextButton.icon(
          key: const ValueKey('topbar_update_btn'),
          icon: Icon(Icons.new_releases_outlined, color: tok.accent),
          label: Text(updateText, style: TextStyle(color: tok.accent)),
          onPressed: () => context.go(routeLocation('activity')),
        );
      }
    }

    Widget actionControl;
    if (appState.refreshRunning) {
      if (narrow) {
        actionControl = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tok.accent,
              ),
            ),
            IconButton(
              key: const ValueKey('cancel_refresh'),
              icon: const Icon(Icons.close),
              tooltip: Strings.get('cancel_refresh'),
              onPressed: refreshClicked,
            ),
          ],
        );
      } else {
        actionControl = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tok.accent,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              Strings.get('refreshing'),
              style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
            ),
            IconButton(
              key: const ValueKey('cancel_refresh'),
              icon: const Icon(Icons.close, size: 18),
              tooltip: Strings.get('cancel_refresh'),
              onPressed: refreshClicked,
            ),
          ],
        );
      }
    } else if (appState.sendingLabel.isNotEmpty) {
      if (narrow) {
        actionControl = SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: tok.accent,
          ),
        );
      } else {
        actionControl = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tok.accent,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              appState.sendingLabel,
              style: TextStyle(color: tok.muted, fontSize: tok.fsSmall),
            ),
          ],
        );
      }
    } else {
      if (narrow) {
        actionControl = TutorialAnchor(
          anchorKey: 'refresh',
          child: IconButton(
            key: const ValueKey('refresh'),
            icon: Icon(Icons.refresh, color: tok.accent),
            tooltip: Strings.get('refresh_data'),
            onPressed: refreshClicked,
          ),
        );
      } else {
        actionControl = TutorialAnchor(
          anchorKey: 'refresh',
          child: FilledButton.icon(
            key: const ValueKey('refresh'),
            icon: const Icon(Icons.refresh),
            label: Text(Strings.get('refresh_data')),
            onPressed: refreshClicked,
          ),
        );
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(child: statusPill),
          if (updateControl != null) ...[
            const SizedBox(width: 8),
            updateControl,
          ],
          const SizedBox(width: 8),
          actionControl,
        ],
      ),
    );
  }
}
