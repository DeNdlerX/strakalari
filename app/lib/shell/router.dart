// go_router table: 8 main routes + wizard + more.
//
// Port of the route vocabulary in strakalari/flet_ui/app.py (`ROUTES`,
// `NARROW_TABS`, `MORE_ROUTES`, `_BUILDERS`). Phase-6 screens register
// their builders here by replacing [PlaceholderScreen]; the route names
// and paths never change.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../controllers/app_state.dart';
import '../features/absences/absences_live.dart';
import '../features/absences/limits_page.dart';
import '../features/activity/activity_live.dart';
import '../features/lunches/lunches_live.dart';
import '../features/marks/marks_live.dart';
import '../features/more.dart';
import '../features/planner/planner_live.dart';
import '../features/settings/settings_live.dart';
import '../features/timetable/timetable_live.dart';
import '../features/today/today_live.dart';
import '../features/wizard/wizard_live.dart';
import '../l10n/strings.dart';
import '../shell/scaffold.dart';
import '../widgets/account_switcher.dart';

/// The seven rail routes, in rail order.
const List<String> shellRoutes = [
  'today',
  'timetable',
  'absences',
  'marks',
  'lunches',
  'activity',
  'settings',
];

/// Narrow (phone portrait) bottom-bar tabs. Port of `NARROW_TABS`.
const List<String> narrowTabs = [
  'today',
  'timetable',
  'marks',
  'lunches',
  'more',
];

/// Narrow-layout screens that live on the More page. Port of
/// `MORE_ROUTES`.
const List<String> moreRoutes = [
  'absences',
  'activity',
  'settings',
];

/// Location for [route] (`today` → `/today`).
String routeLocation(String route) => '/$route';

/// Accepts only known shell routes or `'more'` as a `?from=` back-navigation
/// origin; `null` or any unknown value returns `null` (falling back to
/// `'absences'`).
String? sanitizeBackOrigin(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  if (shellRoutes.contains(raw) || raw == 'more') return raw;
  return null;
}

/// Route name for a location (`/lunches` → `lunches`, `/` → `today`).
String routeForLocation(String location) {
  final seg = location.split('?').first.split('#').first;
  final name = seg.startsWith('/') ? seg.substring(1) : seg;
  if (name.isEmpty) return 'today';
  if (name == 'planner') return 'absences/plan';
  if (name == 'absences/plan' || name == 'absences/limits') return name;
  if (shellRoutes.contains(name)) return name;
  if (name == 'more' || name == 'wizard') return name;
  return 'today';
}

/// Phase-6 placeholder: every screen renders its title card until its
/// real view lands (one commit per screen). Not a stub to keep — each
/// phase-6 commit replaces one branch below with the real view.
class PlaceholderScreen extends StatelessWidget {
  final String route;
  const PlaceholderScreen({super.key, required this.route});

  @override
  Widget build(BuildContext context) {
    final titles = {
      'today': Strings.get('nav_today'),
      'timetable': Strings.get('nav_timetable'),
      'absences': Strings.get('nav_absences'),
      'absences/plan': Strings.get('planner_title'),
      'absences/limits': Strings.get('sec_limits'),
      'marks': Strings.get('nav_marks'),
      'lunches': Strings.get('nav_lunches'),
      'activity': Strings.get('nav_activity'),
      'settings': Strings.get('nav_settings'),
      'more': Strings.get('nav_more'),
      'wizard': Strings.get('app_title'),
    };
    return Center(
      child: Text(
        titles[route] ?? route,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }
}

GoRoute _route(String name) => GoRoute(
      path: '/$name',
      name: name,
      builder: (context, state) => ShellBackScope(
        route: name,
        child: Consumer(
        builder: (context, ref, _) {
          final appState = ref.watch(appStateProvider);
          final size = MediaQuery.sizeOf(context);
          final narrow =
              (size.width > 0 && size.width < 720) || (size.height > 0 && size.height < 520);
          final tokens = appState.appTokens;
          switch (name) {
            case 'today':
              return LiveTodayView(tokens: tokens, narrow: narrow);
            case 'timetable':
              return LiveTimetableView(tokens: tokens, narrow: narrow);
            case 'absences':
              return LiveAbsencesView(tokens: tokens, narrow: narrow);
            case 'marks':
              return LiveMarksView(tokens: tokens, narrow: narrow);
            case 'lunches':
              return LiveLunchesView(narrow: narrow);
            case 'activity':
              return LiveActivityView(narrow: narrow);
            case 'settings':
              return LiveSettingsView(narrow: narrow);
            case 'more':
              final multi = appState.isMultiAccount;
              final activeId = appState.activeAccountId;
              final summary = (multi && activeId != null)
                  ? appState.accountSummary(activeId)
                  : ('', '');
              return MorePage(
                tokens: tokens,
                isAndroid: mobilePlatform() == 'android',
                activeAccountLabel:
                    multi ? appState.activeAccountDisplayLabel : null,
                activeAccountSubtitle: multi
                    ? formatAccountSubtitle(summary.$1, summary.$2)
                    : null,
                onSwitchAccount: multi
                    ? () => showAccountSwitcher(
                          context,
                          appState: appState,
                          tok: appState.tok,
                          narrow: narrow,
                          onManageAccounts: () =>
                              context.go(routeLocation('settings')),
                        )
                    : null,
                onOpen: (r) => openMoreRoute(
                  appState,
                  r,
                  (target) => context.go(routeLocation(target)),
                ),
              );
            default:
              return PlaceholderScreen(route: name);
          }
        },
        ),
      ),
    );

/// The app router. The Shell wraps every route (persistent scaffold);
/// `/` redirects to `/today`.
GoRouter buildRouter({String initialLocation = '/today'}) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/',
          redirect: (context, state) => '/today',
        ),
        GoRoute(
          path: '/planner',
          redirect: (_, _) => '/absences/plan',
        ),
        GoRoute(
          path: '/wizard',
          name: 'wizard',
          builder: (context, state) => Consumer(
            builder: (context, ref, _) {
              final appState = ref.watch(appStateProvider);
              final size = MediaQuery.sizeOf(context);
              final narrow = (size.width > 0 && size.width < 720) ||
                  (size.height > 0 && size.height < 520);
              final tokens = appState.appTokens;
              // The wizard also pops the queued error dialog and snack
              // (app.py calls `_maybe_show_error` in its wizard branch).
              popPendingMessages(context, appState, tokens,
                  ref.read(appStateProvider.notifier));
              return Scaffold(
                body: SafeArea(
                  child: LiveWizardView(tokens: tokens, narrow: narrow),
                ),
              );
            },
          ),
        ),
        ShellRoute(
          builder: (context, state, child) => AppScaffold(
            location: state.uri.path,
            child: child,
          ),
          routes: [
            for (final name in shellRoutes) _route(name),
            GoRoute(
              path: '/absences/plan',
              name: 'absences/plan',
              builder: (context, state) {
                final from =
                    sanitizeBackOrigin(state.uri.queryParameters['from']);
                return ShellBackScope(
                  route: 'absences/plan',
                  from: from,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final appState = ref.watch(appStateProvider);
                      final size = MediaQuery.sizeOf(context);
                      final narrow = (size.width > 0 && size.width < 720) ||
                          (size.height > 0 && size.height < 520);
                      return LivePlannerPage(
                        tokens: appState.appTokens,
                        narrow: narrow,
                        onBack: () =>
                            context.go(routeLocation(from ?? 'absences')),
                      );
                    },
                  ),
                );
              },
            ),
            GoRoute(
              path: '/absences/limits',
              name: 'absences/limits',
              builder: (context, state) {
                final from =
                    sanitizeBackOrigin(state.uri.queryParameters['from']);
                return ShellBackScope(
                  route: 'absences/limits',
                  from: from,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final appState = ref.watch(appStateProvider);
                      final size = MediaQuery.sizeOf(context);
                      final narrow = (size.width > 0 && size.width < 720) ||
                          (size.height > 0 && size.height < 520);
                      return LiveLimitsPage(
                        tokens: appState.appTokens,
                        narrow: narrow,
                        onBack: () =>
                            context.go(routeLocation(from ?? 'absences')),
                      );
                    },
                  ),
                );
              },
            ),
            _route('more'),
          ],
        ),
      ],
    );
