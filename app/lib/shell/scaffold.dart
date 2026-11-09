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
import '../widgets/error_dialog.dart';
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
    if (appState.setupPending && route != 'wizard') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/wizard');
      });
    } else if (route == 'wizard' &&
        appState.wizardShown &&
        appState.wizardDismissed) {
      appState.wizardShown = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/today');
      });
    }

    if (route == 'wizard' && !appState.wizardShown && !appState.wizardDismissed) {
      appState.wizardShown = true;
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

    if (route == 'more' && !narrow) route = 'today';

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

    final working =
        appState.refreshRunning || appState.sendingLabel.isNotEmpty;
    final statusText = working
        ? (appState.sendingLabel.isEmpty
            ? Strings.get('refreshing')
            : appState.sendingLabel)
        : appState.updatedLabel;

    final topBar = AppBar(
      title: Text(_titleFor(route)),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Text(statusText,
                style:
                    TextStyle(color: tok.muted, fontSize: tok.fsSmall)),
          ),
        ),
        working
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(strokeWidth: 2)),
              )
            : IconButton(
                key: const ValueKey('refresh'),
                tooltip: Strings.get('refresh_data'),
                icon: const Icon(Icons.refresh),
                onPressed: working
                    ? null
                    : () => ref
                        .read(activityControllerProvider)
                        .startRefresh(),
              ),
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
          appBar: topBar,
          body: child,
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
          appBar: topBar,
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: sideIndex,
                labelType: NavigationRailLabelType.selected,
                onDestinationSelected: (i) =>
                    context.go(routeLocation(tabs[i])),
                destinations: [
                  for (final tab in tabs)
                    NavigationRailDestination(
                      icon: Icon(_railIcons[tab]!),
                      label: Text(tab == 'lunches'
                          ? Strings.get('nav_lunches')
                          : _titleFor(tab)),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ],
          ),
        );
      case ShellLayout.wide:
        var railIndex = shellRoutes.indexOf(route);
        if (railIndex < 0) railIndex = 0;
        return Scaffold(
          appBar: topBar,
          body: Row(
            children: [
              NavigationRail(
                extended: true,
                minExtendedWidth: tok.railWidth,
                selectedIndex: railIndex,
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
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ],
          ),
        );
    }
  }
}
