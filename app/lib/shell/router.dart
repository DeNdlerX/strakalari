// go_router table: 8 main routes + wizard + more.
//
// Port of the route vocabulary in strakalari/flet_ui/app.py (`ROUTES`,
// `NARROW_TABS`, `MORE_ROUTES`, `_BUILDERS`). Phase-6 screens register
// their builders here by replacing [PlaceholderScreen]; the route names
// and paths never change.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/absences/absences_live.dart';
import '../features/activity/activity_live.dart';
import '../features/common/app_tokens.dart' as ft;
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

/// The eight rail routes, in rail order. Port of `ROUTES`.
const List<String> shellRoutes = [
  'today',
  'timetable',
  'absences',
  'marks',
  'planner',
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
  'planner',
  'activity',
  'settings',
];

/// Location for [route] (`today` → `/today`).
String routeLocation(String route) => '/$route';

/// Route name for a location (`/lunches` → `lunches`, `/` → `today`).
String routeForLocation(String location) {
  final seg = location.split('?').first.split('#').first;
  final name = seg.startsWith('/') ? seg.substring(1) : seg;
  if (name.isEmpty) return 'today';
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
      'marks': Strings.get('nav_marks'),
      'planner': Strings.get('nav_planner'),
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
      builder: (context, state) {
        final size = MediaQuery.sizeOf(context);
        final narrow =
            (size.width > 0 && size.width < 720) || (size.height > 0 && size.height < 520);
        final tokens = ft.AppTokens.of(Theme.of(context).brightness);
        switch (name) {
          case 'today':
            return LiveTodayView(tokens: tokens, narrow: narrow);
          case 'timetable':
            return LiveTimetableView(tokens: tokens, narrow: narrow);
          case 'absences':
            return LiveAbsencesView(tokens: tokens, narrow: narrow);
          case 'marks':
            return LiveMarksView(tokens: tokens, narrow: narrow);
          case 'planner':
            return LivePlannerView(narrow: narrow);
          case 'lunches':
            return LiveLunchesView(narrow: narrow);
          case 'activity':
            return LiveActivityView(narrow: narrow);
          case 'settings':
            return LiveSettingsView(narrow: narrow);
          case 'more':
            return MorePage(onOpen: (r) => context.go('/$r'));
          default:
            return PlaceholderScreen(route: name);
        }
      },
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
          path: '/wizard',
          name: 'wizard',
          builder: (context, state) {
            final size = MediaQuery.sizeOf(context);
            final narrow = (size.width > 0 && size.width < 720) ||
                (size.height > 0 && size.height < 520);
            final tokens = ft.AppTokens.of(Theme.of(context).brightness);
            return Scaffold(
              body: SafeArea(
                child: LiveWizardView(tokens: tokens, narrow: narrow),
              ),
            );
          },
        ),
        ShellRoute(
          builder: (context, state, child) => AppScaffold(
            location: state.uri.path,
            child: child,
          ),
          routes: [
            for (final name in shellRoutes) _route(name),
            _route('more'),
          ],
        ),
      ],
    );
